import Foundation
import Observation

enum TerminalTextSanitizer {
    private static let ansiPattern = "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\))"
    private static let ansiExpression = try! NSRegularExpression(pattern: ansiPattern)

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutANSI = ansiExpression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )

        var result = ""
        for character in withoutANSI.replacingOccurrences(of: "\r\n", with: "\n") {
            switch character {
            case "\u{8}", "\u{7F}":
                if result.last != "\n" { result.removeLastIfPresent() }
            case "\r":
                result.append("\n")
            case "\n", "\t":
                result.append(character)
            default:
                if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) {
                    result.append(character)
                }
            }
        }
        return result
    }
}

enum PrivilegedShellCommand {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

    static func arguments(for command: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "do shell script (\"/bin/zsh -lc \" & quoted form of (item 1 of argv)) with administrator privileges",
            "-e", "end run",
            "--", commandWithoutSimpleSudoPrefix(command),
        ]
    }

    static func commandWithoutSimpleSudoPrefix(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["sudo ", "/usr/bin/sudo "] where trimmed.hasPrefix(prefix) {
            let remainder = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            if !remainder.hasPrefix("-") { return remainder }
        }
        return trimmed
    }

    static func wasCancelled(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("user canceled")
            || message.contains("(-128)")
    }
}

enum TerminalShellArgument {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum TerminalCommandHistoryPolicy {
    /// Mirrors the common shell `HIST_IGNORE_SPACE` convention.
    static func shouldRecord(_ command: String) -> Bool {
        guard let first = command.first else { return false }
        return !first.isWhitespace
    }
}

@Observable
@MainActor
final class TerminalStore {
    static let shared = TerminalStore()

    private(set) var output = ""
    var commandText = "" {
        didSet {
            guard !isApplyingHistory else { return }
            historyIndex = nil
            historyDraft = commandText
        }
    }
    private(set) var isRunning = false
    private(set) var isExecuting = false
    private(set) var isAwaitingSecureInput = false
    private(set) var isRunningPrivilegedCommand = false
    private(set) var currentDirectory = FileManager.default.homeDirectoryForCurrentUser
    private(set) var lastExitCode: Int32?
    private(set) var shellPath: String
    private(set) var errorMessage: String?
    private(set) var recentCommands: [String]
    private(set) var presetCommands: [String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var privilegedCommandProcess: Process?
    @ObservationIgnored private var inputPipe: Pipe?
    @ObservationIgnored private var outputPipe: Pipe?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var receiveBuffer = ""
    @ObservationIgnored private var securePromptProbe = ""
    @ObservationIgnored private var sensitiveInputs: [String] = []
    @ObservationIgnored private var sensitiveOutputTail = ""
    @ObservationIgnored private var suppressOutputUntilFirstPrompt = false
    @ObservationIgnored private var pendingCommandCount = 0
    @ObservationIgnored private var commandHistory: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var historyDraft = ""
    @ObservationIgnored private var isApplyingHistory = false

    private static let markerPrefix = "\u{1E}__WORKBENCH_TERMINAL_STATUS__"
    private static let markerFieldSeparator = "\u{1F}"
    private static let markerEnd = "\u{1E}"
    private static let maximumOutputCharacters = 500_000
    private static let retainedOutputCharacters = 400_000
    private static let maximumRecentCommands = 50
    private static let maximumPresetCommands = 50

    var canBeginSecureInput: Bool {
        isRunning && isExecuting && !isAwaitingSecureInput
    }

    init(shellPath: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuredShell = shellPath
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        let supportedShells = ["zsh", "bash"]
        let configuredShellName = URL(fileURLWithPath: configuredShell).lastPathComponent
        self.shellPath = FileManager.default.isExecutableFile(atPath: configuredShell)
            && supportedShells.contains(configuredShellName)
            ? configuredShell
            : "/bin/zsh"
        recentCommands = defaults.stringArray(forKey: Key.recentCommands) ?? []
        presetCommands = defaults.stringArray(forKey: Key.presetCommands) ?? []
        commandHistory = Array(recentCommands.reversed())
    }

    func startIfNeeded(at directory: URL) {
        guard !isRunning else { return }
        start(at: directory)
    }

    func restart(at directory: URL) {
        stop(appendMessage: false)
        appendOutput("\n— New session —\n")
        start(at: directory)
    }

    func start(at directory: URL) {
        guard !isRunning else { return }
        let startingDirectory = resolvedDirectory(directory)
        let newSessionID = UUID()
        let newProcess = Process()
        let newInputPipe = Pipe()
        let newOutputPipe = Pipe()

        sessionID = newSessionID
        receiveBuffer = ""
        securePromptProbe = ""
        sensitiveInputs = []
        sensitiveOutputTail = ""
        suppressOutputUntilFirstPrompt = true
        pendingCommandCount = 0
        isExecuting = false
        isAwaitingSecureInput = false
        lastExitCode = nil
        errorMessage = nil
        currentDirectory = startingDirectory

        newProcess.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        newProcess.arguments = ["-q", "/dev/null", shellPath, "-l", "-i"]
        newProcess.currentDirectoryURL = startingDirectory
        newProcess.standardInput = newInputPipe
        newProcess.standardOutput = newOutputPipe
        newProcess.standardError = newOutputPipe

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        newProcess.environment = environment

        newOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard self?.sessionID == newSessionID else { return }
                self?.consume(data)
            }
        }
        newProcess.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(status: status, sessionID: newSessionID)
            }
        }

        do {
            try newProcess.run()
            process = newProcess
            inputPipe = newInputPipe
            outputPipe = newOutputPipe
            isRunning = true
            appendOutput("Workbench Terminal · \(shellPath)\n")
            appendOutput("Started in \(startingDirectory.path(percentEncoded: false))\n\n")
            try newInputPipe.fileHandleForWriting.write(contentsOf: Data(shellSetupCommand.utf8))
        } catch {
            newOutputPipe.fileHandleForReading.readabilityHandler = nil
            if newProcess.isRunning { newProcess.terminate() }
            process = nil
            inputPipe = nil
            outputPipe = nil
            isRunning = false
            errorMessage = error.localizedDescription
            appendOutput("Unable to start the shell: \(error.localizedDescription)\n")
        }
    }

    func executeCommand(recordInHistory: Bool = true) {
        let command = commandText.trimmingCharacters(in: .newlines)
        guard isRunning, let inputPipe else {
            errorMessage = "The shell session is not running."
            return
        }

        let isInteractiveResponse = pendingCommandCount > 0
        guard isInteractiveResponse
                || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wasSecureInput = isAwaitingSecureInput
        let payload = command + "\n"

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            if wasSecureInput, !command.isEmpty {
                sensitiveInputs.append(command)
            }
            commandText = ""
            historyIndex = nil
            if isInteractiveResponse {
                if !isAwaitingSecureInput { appendOutput("\(command)\n") }
                isAwaitingSecureInput = false
                errorMessage = nil
                return
            }

            appendOutput("\(promptPath) % \(command)\n")
            if recordInHistory && TerminalCommandHistoryPolicy.shouldRecord(command) {
                recordRecentCommand(command)
                if commandHistory.last != command {
                    commandHistory.append(command)
                    if commandHistory.count > 200 { commandHistory.removeFirst() }
                }
            }
            pendingCommandCount += 1
            isExecuting = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            appendOutput("Could not send the command: \(error.localizedDescription)\n")
        }
    }

    /// Manually switches the current interactive response to password mode.
    /// This covers prompts whose wording is not recognized automatically.
    func beginSecureInput() {
        guard canBeginSecureInput else { return }
        isAwaitingSecureInput = true
        errorMessage = nil
    }

    func previousCommand() {
        guard !commandHistory.isEmpty else { return }
        if historyIndex == nil { historyDraft = commandText }
        let index = max(0, (historyIndex ?? commandHistory.count) - 1)
        historyIndex = index
        applyHistoryText(commandHistory[index])
    }

    func nextCommand() {
        guard let historyIndex else { return }
        let next = historyIndex + 1
        if next < commandHistory.count {
            self.historyIndex = next
            applyHistoryText(commandHistory[next])
        } else {
            self.historyIndex = nil
            applyHistoryText(historyDraft)
        }
    }

    func changeDirectory(to directory: URL) {
        let destination = resolvedDirectory(directory)
        if !isRunning {
            start(at: destination)
            return
        }
        guard !isExecuting else {
            errorMessage = "Wait for the current command to finish before changing folders."
            return
        }
        guard destination != currentDirectory.standardizedFileURL else { return }
        runCommand(
            "cd -- \(TerminalShellArgument.quote(destination.path(percentEncoded: false)))",
            recordInHistory: false
        )
    }

    func clearOutput() {
        output = ""
    }

    func runWithAdministratorPrivileges(_ command: String) {
        guard !isRunningPrivilegedCommand else { return }
        let recordsCommand = TerminalCommandHistoryPolicy.shouldRecord(
            command.trimmingCharacters(in: .newlines)
        )
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else { return }

        let privilegedProcess = Process()
        let resultPipe = Pipe()
        privilegedProcess.executableURL = PrivilegedShellCommand.executableURL
        privilegedProcess.arguments = PrivilegedShellCommand.arguments(for: normalizedCommand)
        privilegedProcess.standardOutput = resultPipe
        privilegedProcess.standardError = resultPipe
        privilegedProcess.terminationHandler = { [weak self] finishedProcess in
            let data = resultPipe.fileHandleForReading.readDataToEndOfFile()
            let message = TerminalTextSanitizer.clean(String(decoding: data, as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = finishedProcess.terminationStatus
            Task { @MainActor [weak self] in
                self?.finishPrivilegedCommand(status: status, message: message)
            }
        }

        isRunningPrivilegedCommand = true
        errorMessage = nil
        lastExitCode = nil
        if commandText.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCommand {
            commandText = ""
        }
        historyIndex = nil
        if recordsCommand {
            recordRecentCommand(normalizedCommand)
            if commandHistory.last != normalizedCommand {
                commandHistory.append(normalizedCommand)
                if commandHistory.count > 200 { commandHistory.removeFirst() }
            }
        }
        appendOutput("\n[Administrator] % \(normalizedCommand)\n")
        appendOutput("Waiting for macOS administrator approval…\n")

        do {
            try privilegedProcess.run()
            privilegedCommandProcess = privilegedProcess
        } catch {
            isRunningPrivilegedCommand = false
            privilegedCommandProcess = nil
            errorMessage = "Administrator command could not start: \(error.localizedDescription)"
            appendOutput("[Administrator] Could not start.\n")
        }
    }

    func interruptCommand() {
        guard isRunning, pendingCommandCount > 0, let inputPipe else { return }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data([0x03]))
            commandText = ""
            isAwaitingSecureInput = false
            appendOutput("^C\n")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadCommand(_ command: String) {
        commandText = command
        historyIndex = nil
    }

    func runCommand(_ command: String, recordInHistory: Bool = true) {
        loadCommand(command)
        executeCommand(recordInHistory: recordInHistory)
    }

    func isPreset(_ command: String) -> Bool {
        guard let normalized = normalizedCommand(command) else { return false }
        return presetCommands.contains(normalized)
    }

    func addPreset(_ command: String) {
        guard let normalized = normalizedCommand(command) else { return }
        presetCommands.removeAll { $0 == normalized }
        presetCommands.insert(normalized, at: 0)
        if presetCommands.count > Self.maximumPresetCommands {
            presetCommands.removeLast(presetCommands.count - Self.maximumPresetCommands)
        }
        defaults.set(presetCommands, forKey: Key.presetCommands)
    }

    func removePreset(_ command: String) {
        guard let normalized = normalizedCommand(command) else { return }
        presetCommands.removeAll { $0 == normalized }
        defaults.set(presetCommands, forKey: Key.presetCommands)
    }

    func togglePreset(_ command: String) {
        if isPreset(command) {
            removePreset(command)
        } else {
            addPreset(command)
        }
    }

    func clearRecentCommands() {
        recentCommands = []
        commandHistory = []
        historyIndex = nil
        historyDraft = commandText
        defaults.removeObject(forKey: Key.recentCommands)
    }

    func stop(appendMessage: Bool = true) {
        let oldProcess = process
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        sessionID = UUID()
        receiveBuffer = ""
        securePromptProbe = ""
        sensitiveInputs = []
        sensitiveOutputTail = ""
        suppressOutputUntilFirstPrompt = false
        pendingCommandCount = 0
        isExecuting = false
        isAwaitingSecureInput = false
        isRunning = false
        if oldProcess?.isRunning == true { oldProcess?.terminate() }
        if appendMessage { appendOutput("\n[Session stopped]\n") }
    }

    func shutdown() {
        stop(appendMessage: false)
        let privilegedProcess = privilegedCommandProcess
        privilegedCommandProcess = nil
        isRunningPrivilegedCommand = false
        if privilegedProcess?.isRunning == true { privilegedProcess?.terminate() }
    }

    private var promptPath: String {
        currentDirectory.path == FileManager.default.homeDirectoryForCurrentUser.path
            ? "~"
            : currentDirectory.lastPathComponent
    }

    private var shellSetupCommand: String {
        if URL(fileURLWithPath: shellPath).lastPathComponent == "bash" {
            return "stty -echo; set +o emacs; set +o vi; PS1=''; PROMPT_COMMAND='__wb_status=$?; printf \\\"\\\\036__WORKBENCH_TERMINAL_STATUS__%s\\\\037%s\\\\036\\\" \\\"$__wb_status\\\" \\\"$PWD\\\"'\n"
        }
        return "stty -echo; unsetopt zle; unset RPROMPT; PROMPT=$'\\036__WORKBENCH_TERMINAL_STATUS__%?\\037%/\\036'\n"
    }

    private func normalizedCommand(_ command: String) -> String? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func applyHistoryText(_ text: String) {
        isApplyingHistory = true
        commandText = text
        isApplyingHistory = false
    }

    private func recordRecentCommand(_ command: String) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        if recentCommands.count > Self.maximumRecentCommands {
            recentCommands.removeLast(recentCommands.count - Self.maximumRecentCommands)
        }
        defaults.set(recentCommands, forKey: Key.recentCommands)
    }

    private func resolvedDirectory(_ directory: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return directory.standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func finishPrivilegedCommand(status: Int32, message: String) {
        privilegedCommandProcess = nil
        isRunningPrivilegedCommand = false
        lastExitCode = status

        if status == 0 {
            errorMessage = nil
            if !message.isEmpty { appendOutput(message + "\n") }
            appendOutput("[Administrator] Completed successfully.\n")
        } else if PrivilegedShellCommand.wasCancelled(message) {
            errorMessage = nil
            appendOutput("[Administrator] Canceled.\n")
        } else {
            let detail = message.isEmpty ? "macOS returned status \(status)." : message
            errorMessage = "Administrator command failed: \(detail)"
            appendOutput("[Administrator] Failed: \(detail)\n")
        }
    }

    private func consume(_ data: Data) {
        let text = redactingSensitiveInputs(in: String(decoding: data, as: UTF8.self))
        receiveBuffer += text
        parseReceiveBuffer()
    }

    private func redactingSensitiveInputs(in text: String) -> String {
        guard !sensitiveInputs.isEmpty else { return text }

        var redacted = sensitiveOutputTail + text
        sensitiveOutputTail = ""
        for sensitiveInput in sensitiveInputs where !sensitiveInput.isEmpty {
            redacted = redacted.replacingOccurrences(of: sensitiveInput, with: "")
        }

        let maximumTailLength = min(
            redacted.count,
            sensitiveInputs.map(\.count).max().map { max(0, $0 - 1) } ?? 0
        )
        guard maximumTailLength > 0 else { return redacted }

        for length in stride(from: maximumTailLength, through: 1, by: -1) {
            let suffix = redacted.suffix(length)
            if sensitiveInputs.contains(where: { $0.hasPrefix(suffix) }) {
                sensitiveOutputTail = String(suffix)
                return String(redacted.dropLast(length))
            }
        }
        return redacted
    }

    private func parseReceiveBuffer() {
        while let markerRange = receiveBuffer.range(of: Self.markerPrefix) {
            let visibleText = String(receiveBuffer[..<markerRange.lowerBound])
            let wasSuppressingOutput = suppressOutputUntilFirstPrompt
            if !wasSuppressingOutput { appendVisibleOutput(visibleText) }

            let payloadStart = markerRange.upperBound
            guard let endRange = receiveBuffer.range(
                of: Self.markerEnd,
                range: payloadStart..<receiveBuffer.endIndex
            ) else {
                receiveBuffer = String(receiveBuffer[markerRange.lowerBound...])
                return
            }

            let payload = String(receiveBuffer[payloadStart..<endRange.lowerBound])
            handleStatusPayload(payload, completesCommand: !wasSuppressingOutput)
            suppressOutputUntilFirstPrompt = false
            receiveBuffer = String(receiveBuffer[endRange.upperBound...])
        }

        let retainedPrefixLength = partialMarkerSuffixLength(in: receiveBuffer)
        if retainedPrefixLength == 0 {
            if !suppressOutputUntilFirstPrompt { appendVisibleOutput(receiveBuffer) }
            receiveBuffer = ""
        } else {
            let split = receiveBuffer.index(receiveBuffer.endIndex, offsetBy: -retainedPrefixLength)
            if !suppressOutputUntilFirstPrompt {
                appendVisibleOutput(String(receiveBuffer[..<split]))
            }
            receiveBuffer = String(receiveBuffer[split...])
        }
    }

    private func partialMarkerSuffixLength(in text: String) -> Int {
        let maximum = min(text.count, Self.markerPrefix.count - 1)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            if text.suffix(length) == Self.markerPrefix.prefix(length) { return length }
        }
        return 0
    }

    private func handleStatusPayload(_ payload: String, completesCommand: Bool) {
        let fields = payload.components(separatedBy: Self.markerFieldSeparator)
        if fields.count >= 2, !fields[1].isEmpty {
            currentDirectory = URL(fileURLWithPath: fields[1], isDirectory: true).standardizedFileURL
        }
        if completesCommand {
            if let statusText = fields.first, let status = Int32(statusText) {
                lastExitCode = status
            }
            pendingCommandCount = max(0, pendingCommandCount - 1)
            sensitiveInputs = []
            sensitiveOutputTail = ""
        }
        isExecuting = pendingCommandCount > 0
        isAwaitingSecureInput = false
        securePromptProbe = ""
    }

    private func appendVisibleOutput(_ text: String) {
        inspectForSecurePrompt(in: text)
        appendOutput(text)
    }

    private func inspectForSecurePrompt(in text: String) {
        guard pendingCommandCount > 0 else { return }
        securePromptProbe += TerminalTextSanitizer.clean(text)
        if securePromptProbe.count > 500 {
            securePromptProbe = String(securePromptProbe.suffix(500))
        }
        let lastLine = securePromptProbe.components(separatedBy: .newlines).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let securePromptTerms = ["password:", "password for", "passphrase:", "passphrase for"]
        if securePromptTerms.contains(where: { lastLine.contains($0) }) {
            isAwaitingSecureInput = true
        }
    }

    private func handleTermination(status: Int32, sessionID terminatedSessionID: UUID) {
        guard sessionID == terminatedSessionID else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        pendingCommandCount = 0
        isExecuting = false
        isAwaitingSecureInput = false
        sensitiveInputs = []
        sensitiveOutputTail = ""
        isRunning = false
        lastExitCode = status
        appendOutput("\n[Session ended with status \(status)]\n")
    }

    private func appendOutput(_ text: String) {
        let cleaned = TerminalTextSanitizer.clean(text)
        guard !cleaned.isEmpty else { return }
        output += cleaned
        if output.count > Self.maximumOutputCharacters {
            output = "[Earlier output trimmed]\n" + output.suffix(Self.retainedOutputCharacters)
        }
    }

    private enum Key {
        static let recentCommands = "terminal.recentCommands"
        static let presetCommands = "terminal.presetCommands"
    }
}

private extension String {
    mutating func removeLastIfPresent() {
        guard !isEmpty else { return }
        removeLast()
    }
}
