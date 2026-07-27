import AppKit
import Foundation
import Observation

enum PomodoroPhase: String, CaseIterable, Identifiable {
    case focus
    case shortBreak
    case longBreak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }

    var compactTitle: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short"
        case .longBreak: "Long"
        }
    }

    var systemImage: String {
        switch self {
        case .focus: "brain.head.profile"
        case .shortBreak: "cup.and.saucer"
        case .longBreak: "figure.walk"
        }
    }
}

/// App-wide Pomodoro state. The timer belongs to the store rather than the
/// panel so an active session keeps running when the panel is hidden.
@Observable
@MainActor
final class PomodoroStore {
    static let shared = PomodoroStore()

    private enum Key {
        static let focusMinutes = "pomodoro.focusMinutes"
        static let shortBreakMinutes = "pomodoro.shortBreakMinutes"
        static let longBreakMinutes = "pomodoro.longBreakMinutes"
        static let autoStart = "pomodoro.autoStartNextSession"
        static let playSound = "pomodoro.playCompletionSound"
        static let completedSessions = "pomodoro.completedFocusSessions"
        static let sessionsInCycle = "pomodoro.focusSessionsInCycle"
    }

    private(set) var phase: PomodoroPhase = .focus
    private(set) var remainingSeconds: TimeInterval
    private(set) var isRunning = false
    private(set) var completedFocusSessions: Int
    private(set) var focusSessionsInCycle: Int

    var focusMinutes: Int {
        didSet {
            defaults.set(focusMinutes, forKey: Key.focusMinutes)
            resetRemainingIfIdle(for: .focus)
        }
    }

    var shortBreakMinutes: Int {
        didSet {
            defaults.set(shortBreakMinutes, forKey: Key.shortBreakMinutes)
            resetRemainingIfIdle(for: .shortBreak)
        }
    }

    var longBreakMinutes: Int {
        didSet {
            defaults.set(longBreakMinutes, forKey: Key.longBreakMinutes)
            resetRemainingIfIdle(for: .longBreak)
        }
    }

    var autoStartNextSession: Bool {
        didSet { defaults.set(autoStartNextSession, forKey: Key.autoStart) }
    }

    var playCompletionSound: Bool {
        didSet { defaults.set(playCompletionSound, forKey: Key.playSound) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let schedulesTimer: Bool
    @ObservationIgnored private let completionSound: @MainActor () -> Void
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var timer: Timer?

    init(
        defaults: UserDefaults = .standard,
        schedulesTimer: Bool = true,
        completionSound: @escaping @MainActor () -> Void = {
            if let sound = NSSound(named: NSSound.Name("Glass")) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    ) {
        self.defaults = defaults
        self.schedulesTimer = schedulesTimer
        self.completionSound = completionSound

        let focusMinutes = Self.integer(defaults, key: Key.focusMinutes, fallback: 25)
        let shortBreakMinutes = Self.integer(defaults, key: Key.shortBreakMinutes, fallback: 5)
        let longBreakMinutes = Self.integer(defaults, key: Key.longBreakMinutes, fallback: 15)
        let completedSessions = max(defaults.integer(forKey: Key.completedSessions), 0)
        let sessionsInCycle = min(max(defaults.integer(forKey: Key.sessionsInCycle), 0), 4)

        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.autoStartNextSession = Self.bool(defaults, key: Key.autoStart, fallback: false)
        self.playCompletionSound = Self.bool(defaults, key: Key.playSound, fallback: true)
        completedFocusSessions = completedSessions
        focusSessionsInCycle = sessionsInCycle
        remainingSeconds = TimeInterval(focusMinutes * 60)
    }

    var totalSeconds: TimeInterval {
        duration(for: phase)
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(max(1 - remainingSeconds / totalSeconds, 0), 1)
    }

    var remainingText: String {
        let seconds = max(Int(ceil(remainingSeconds)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var sessionDetail: String {
        switch phase {
        case .focus:
            "Focus session \(min(focusSessionsInCycle + 1, 4)) of 4"
        case .shortBreak:
            "Recharge before the next focus session"
        case .longBreak:
            "Four focus sessions complete"
        }
    }

    func selectPhase(_ newPhase: PomodoroPhase) {
        stopTimer()
        isRunning = false
        endDate = nil
        if newPhase == .focus, focusSessionsInCycle >= 4 {
            focusSessionsInCycle = 0
            persistCycleCount()
        }
        phase = newPhase
        remainingSeconds = duration(for: newPhase)
    }

    func start(at date: Date = .now) {
        guard !isRunning else { return }
        if remainingSeconds <= 0 {
            remainingSeconds = duration(for: phase)
        }
        endDate = date.addingTimeInterval(remainingSeconds)
        isRunning = true
        startTimer()
    }

    func pause(at date: Date = .now) {
        guard isRunning, let endDate else { return }
        let timeLeft = endDate.timeIntervalSince(date)
        if timeLeft <= 0 {
            completeCurrentPhase(at: date)
            return
        }
        remainingSeconds = ceil(timeLeft)
        isRunning = false
        self.endDate = nil
        stopTimer()
    }

    func reset() {
        stopTimer()
        isRunning = false
        endDate = nil
        remainingSeconds = duration(for: phase)
    }

    func skip() {
        stopTimer()
        isRunning = false
        endDate = nil

        switch phase {
        case .focus:
            phase = .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            focusSessionsInCycle = 0
            persistCycleCount()
            phase = .focus
        }
        remainingSeconds = duration(for: phase)
    }

    func tick(at date: Date = .now) {
        guard isRunning, let endDate else { return }
        let timeLeft = endDate.timeIntervalSince(date)
        guard timeLeft > 0 else {
            completeCurrentPhase(at: date)
            return
        }
        remainingSeconds = ceil(timeLeft)
    }

    private func completeCurrentPhase(at date: Date) {
        let completedPhase = phase
        stopTimer()
        isRunning = false
        endDate = nil

        switch completedPhase {
        case .focus:
            completedFocusSessions += 1
            focusSessionsInCycle = min(focusSessionsInCycle + 1, 4)
            defaults.set(completedFocusSessions, forKey: Key.completedSessions)
            persistCycleCount()
            phase = focusSessionsInCycle >= 4 ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            focusSessionsInCycle = 0
            persistCycleCount()
            phase = .focus
        }

        remainingSeconds = duration(for: phase)
        if playCompletionSound {
            completionSound()
        }
        if autoStartNextSession {
            start(at: date)
        }
    }

    private func duration(for phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: TimeInterval(focusMinutes * 60)
        case .shortBreak: TimeInterval(shortBreakMinutes * 60)
        case .longBreak: TimeInterval(longBreakMinutes * 60)
        }
    }

    private func resetRemainingIfIdle(for changedPhase: PomodoroPhase) {
        guard !isRunning, phase == changedPhase else { return }
        remainingSeconds = duration(for: phase)
    }

    private func startTimer() {
        guard schedulesTimer else { return }
        stopTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func persistCycleCount() {
        defaults.set(focusSessionsInCycle, forKey: Key.sessionsInCycle)
    }

    private static func integer(_ defaults: UserDefaults, key: String, fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }

    private static func bool(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
