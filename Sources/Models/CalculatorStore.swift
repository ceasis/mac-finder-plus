import AppKit
import Foundation
import Observation

enum CalculatorMode: String, CaseIterable, Identifiable, Sendable {
    case standard
    case scientific
    case graphing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .scientific: "Scientific"
        case .graphing: "Graphing"
        }
    }
}

struct CalculatorHistoryItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let expression: String
    let result: String
    let value: Double
    let createdAt: Date
    let exactValue: String?
}

struct CalculatorGraphEquation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var expression: String
    var isEnabled: Bool
    var colorIndex: Int
}

struct CalculatorGraphPoint: Identifiable, Sendable {
    let id: Int
    let x: Double
    let y: Double
    let segment: Int
}

struct CalculatorGraphSeries: Identifiable, Sendable {
    let id: UUID
    let expression: String
    let colorIndex: Int
    let points: [CalculatorGraphPoint]
}

private struct CalculatorResolvedValue {
    let text: String
    let doubleValue: Double?
    let exact: CalculatorExactNumber?
}

@Observable
@MainActor
final class CalculatorStore {
    static let shared = CalculatorStore()
    static let maximumExpressionLength = 100

    var mode: CalculatorMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    var angleUnit: CalculatorAngleUnit {
        didSet {
            defaults.set(angleUnit.rawValue, forKey: Key.angleUnit)
            updatePreview(showError: false)
        }
    }
    var expression = "" {
        didSet {
            guard expression != oldValue else { return }
            if expression.count > Self.maximumExpressionLength {
                expression = String(expression.prefix(Self.maximumExpressionLength))
                errorMessage = "Expressions are limited to 100 characters."
                justEvaluated = false
                return
            }
            justEvaluated = false
            updatePreview(showError: false)
        }
    }
    private(set) var resultText = "0"
    private(set) var errorMessage: String?
    private(set) var lastAnswer: Double
    private(set) var lastAnswerText: String
    private(set) var memoryText: String?
    var memoryValue: Double? {
        guard let memoryText,
              let exact = try? CalculatorExactNumber(memoryText) else { return nil }
        return exact.doubleValue
    }
    private(set) var history: [CalculatorHistoryItem]
    var graphEquations: [CalculatorGraphEquation] {
        didSet { persistGraphEquations() }
    }
    var graphXMinimum: Double {
        didSet { persistGraphSettings() }
    }
    var graphXMaximum: Double {
        didSet { persistGraphSettings() }
    }
    var graphUsesAutomaticY: Bool {
        didSet { persistGraphSettings() }
    }
    var graphYMinimum: Double {
        didSet { persistGraphSettings() }
    }
    var graphYMaximum: Double {
        didSet { persistGraphSettings() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var justEvaluated = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = CalculatorMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .standard
        angleUnit = CalculatorAngleUnit(
            rawValue: defaults.string(forKey: Key.angleUnit) ?? ""
        ) ?? .degrees
        let legacyAnswer = defaults.object(forKey: Key.lastAnswer) as? Double ?? 0
        let restoredAnswerText = defaults.string(forKey: Key.lastAnswerExact)
            ?? CalculatorExpressionEngine.formatted(legacyAnswer, grouping: false)
        lastAnswerText = restoredAnswerText
        lastAnswer = (try? CalculatorExactNumber(restoredAnswerText))?.doubleValue ?? legacyAnswer
        if let exactMemory = defaults.string(forKey: Key.memoryExact) {
            memoryText = exactMemory
        } else if let legacyMemory = defaults.object(forKey: Key.memory) as? Double {
            memoryText = CalculatorExpressionEngine.formatted(legacyMemory, grouping: false)
        } else {
            memoryText = nil
        }
        history = Self.decode([CalculatorHistoryItem].self, from: defaults.data(forKey: Key.history)) ?? []
        graphEquations = Self.decode(
            [CalculatorGraphEquation].self,
            from: defaults.data(forKey: Key.graphEquations)
        ) ?? Self.defaultGraphEquations
        graphXMinimum = defaults.object(forKey: Key.graphXMinimum) as? Double ?? -10
        graphXMaximum = defaults.object(forKey: Key.graphXMaximum) as? Double ?? 10
        graphUsesAutomaticY = defaults.object(forKey: Key.graphAutomaticY) as? Bool ?? true
        graphYMinimum = defaults.object(forKey: Key.graphYMinimum) as? Double ?? -10
        graphYMaximum = defaults.object(forKey: Key.graphYMaximum) as? Double ?? 10
    }

    func insert(_ value: String) {
        let operators = ["+", "−", "-", "×", "*", "÷", "/", "^", "%", "!"]
        if justEvaluated {
            expression = operators.contains(value) ? "ans" : ""
        }
        appendToExpression(value)
    }

    func insertDecimal() {
        if justEvaluated { expression = "" }
        let trailingNumber = expression.split(whereSeparator: {
            "+−-×*÷/^%!,()".contains($0)
        }).last.map(String.init) ?? ""
        guard !trailingNumber.contains(".") else { return }
        if expression.last?.isNumber == true {
            appendToExpression(".")
        } else {
            appendToExpression("0.")
        }
    }

    func insertParenthesis() {
        if justEvaluated { expression = "" }
        let opens = expression.filter { $0 == "(" }.count
        let closes = expression.filter { $0 == ")" }.count
        let last = expression.last
        if expression.isEmpty || last == "(" || last.map({ "+−-×*÷/^,".contains($0) }) == true {
            appendToExpression("(")
        } else if opens > closes {
            appendToExpression(")")
        } else {
            appendToExpression("(")
        }
    }

    func applyFunction(_ name: String) {
        let target = expressionTarget
        replaceExpression(target.isEmpty ? "\(name)(" : "\(name)(\(target))")
    }

    func applyBinaryFunction(_ name: String) {
        let target = expressionTarget
        replaceExpression(target.isEmpty ? "\(name)(" : "\(name)(\(target),")
    }

    func applySquare() {
        let target = expressionTarget
        replaceExpression(target.isEmpty ? "(" : "(\(target))^2")
    }

    func applyReciprocal() {
        let target = expressionTarget
        replaceExpression(target.isEmpty ? "1/(" : "1/(\(target))")
    }

    func applyPower(base: String) {
        let target = expressionTarget
        replaceExpression(target.isEmpty ? "\(base)^(" : "\(base)^(\(target))")
    }

    func toggleSign() {
        let target = expressionTarget
        guard !target.isEmpty else {
            replaceExpression("−")
            return
        }
        if target.hasPrefix("−("), target.hasSuffix(")") {
            replaceExpression(String(target.dropFirst(2).dropLast()))
        } else {
            replaceExpression("−(\(target))")
        }
    }

    func deleteBackward() {
        guard !expression.isEmpty else { return }
        expression.removeLast()
    }

    func clear() {
        expression = ""
        resultText = "0"
        errorMessage = nil
        justEvaluated = false
    }

    func evaluate() {
        do {
            let resolved = try currentResolvedValue()
            let calculationText = resolved.exact?.description ?? resolved.text
            resultText = resolved.text
            errorMessage = nil
            lastAnswerText = calculationText
            lastAnswer = resolved.doubleValue ?? 0
            defaults.set(calculationText, forKey: Key.lastAnswerExact)
            if let doubleValue = resolved.doubleValue, doubleValue.isFinite {
                defaults.set(doubleValue, forKey: Key.lastAnswer)
            } else {
                defaults.removeObject(forKey: Key.lastAnswer)
            }
            recordHistory(
                value: resolved.doubleValue ?? 0,
                formatted: resolved.text,
                exactValue: calculationText
            )
            justEvaluated = true
        } catch {
            resultText = "Error"
            errorMessage = error.localizedDescription
            justEvaluated = false
        }
    }

    func recallMemory() {
        guard let memoryText else { return }
        let availableCharacters = Self.maximumExpressionLength - expression.count
        insert(memoryText.count <= availableCharacters ? memoryText : "mem")
    }

    func addToMemory() {
        updateMemory(by: 1)
    }

    func subtractFromMemory() {
        updateMemory(by: -1)
    }

    func clearMemory() {
        memoryText = nil
        defaults.removeObject(forKey: Key.memory)
        defaults.removeObject(forKey: Key.memoryExact)
    }

    func copyResult() {
        guard resultText != "Error", resultText != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
    }

    func useHistoryItem(_ item: CalculatorHistoryItem) {
        expression = item.expression
        resultText = item.result
        lastAnswerText = item.exactValue
            ?? CalculatorExpressionEngine.formatted(item.value, grouping: false)
        lastAnswer = item.value
        errorMessage = nil
        justEvaluated = true
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Key.history)
    }

    func addGraphEquation() {
        guard graphEquations.count < 5 else { return }
        graphEquations.append(CalculatorGraphEquation(
            id: UUID(),
            expression: "",
            isEnabled: true,
            colorIndex: graphEquations.count % 5
        ))
    }

    func removeGraphEquation(_ id: CalculatorGraphEquation.ID) {
        graphEquations.removeAll { $0.id == id }
    }

    func graphError(for equation: CalculatorGraphEquation) -> String? {
        guard !equation.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        do {
            _ = try CalculatorExpressionEngine.compile(equation.expression)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func graphSeries(sampleCount: Int = 600) -> [CalculatorGraphSeries] {
        let domain = normalizedXDomain
        let count = max(80, min(sampleCount, 1_200))
        let step = (domain.upperBound - domain.lowerBound) / Double(count - 1)

        return graphEquations.compactMap { equation in
            guard equation.isEnabled,
                  !equation.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let compiled = try? CalculatorExpressionEngine.compile(equation.expression) else {
                return nil
            }

            var points: [CalculatorGraphPoint] = []
            var segment = 0
            var previousY: Double?
            for index in 0..<count {
                let x = domain.lowerBound + Double(index) * step
                let context = CalculatorEvaluationContext(
                    x: x,
                    answer: lastAnswer,
                    memory: memoryValue,
                    angleUnit: angleUnit
                )
                guard let y = try? compiled.evaluate(in: context), y.isFinite, abs(y) <= 1_000_000 else {
                    segment += 1
                    previousY = nil
                    continue
                }

                if let previousY {
                    let jump = abs(y - previousY)
                    let scale = max(25, max(abs(y), abs(previousY)) * 1.5)
                    if jump > scale { segment += 1 }
                }
                points.append(CalculatorGraphPoint(id: index, x: x, y: y, segment: segment))
                previousY = y
            }
            guard !points.isEmpty else { return nil }
            return CalculatorGraphSeries(
                id: equation.id,
                expression: equation.expression,
                colorIndex: equation.colorIndex,
                points: points
            )
        }
    }

    func yDomain(for series: [CalculatorGraphSeries]) -> ClosedRange<Double> {
        guard graphUsesAutomaticY else { return normalizedManualYDomain }
        let sorted = series.flatMap(\.points).map(\.y).sorted()
        guard let first = sorted.first, let last = sorted.last else { return -10...10 }

        let lower: Double
        let upper: Double
        if sorted.count >= 50 {
            lower = sorted[Int(Double(sorted.count - 1) * 0.02)]
            upper = sorted[Int(Double(sorted.count - 1) * 0.98)]
        } else {
            lower = first
            upper = last
        }
        if abs(upper - lower) < 1e-10 {
            let padding = max(1, abs(lower) * 0.1)
            return (lower - padding)...(upper + padding)
        }
        let padding = (upper - lower) * 0.08
        return (lower - padding)...(upper + padding)
    }

    var normalizedXDomain: ClosedRange<Double> {
        normalizedDomain(minimum: graphXMinimum, maximum: graphXMaximum)
    }

    func zoomGraph(by factor: Double) {
        let domain = normalizedXDomain
        let center = (domain.lowerBound + domain.upperBound) / 2
        let halfWidth = max(0.0001, (domain.upperBound - domain.lowerBound) * factor / 2)
        graphXMinimum = center - halfWidth
        graphXMaximum = center + halfWidth
    }

    func panGraph(by fraction: Double) {
        let domain = normalizedXDomain
        let offset = (domain.upperBound - domain.lowerBound) * fraction
        graphXMinimum += offset
        graphXMaximum += offset
    }

    func resetGraph() {
        graphXMinimum = -10
        graphXMaximum = 10
        graphUsesAutomaticY = true
        graphYMinimum = -10
        graphYMaximum = 10
    }

    private func appendToExpression(_ value: String) {
        replaceExpression(expression + value)
    }

    private func replaceExpression(_ candidate: String) {
        guard candidate.count <= Self.maximumExpressionLength else {
            errorMessage = "Expressions are limited to 100 characters."
            return
        }
        expression = candidate
    }

    private var expressionTarget: String {
        if justEvaluated {
            return "ans"
        }
        return expression
    }

    private var normalizedManualYDomain: ClosedRange<Double> {
        normalizedDomain(minimum: graphYMinimum, maximum: graphYMaximum)
    }

    private func normalizedDomain(minimum: Double, maximum: Double) -> ClosedRange<Double> {
        guard minimum.isFinite, maximum.isFinite, maximum > minimum else { return -10...10 }
        return minimum...maximum
    }

    private func currentResolvedValue() throws -> CalculatorResolvedValue {
        let exactAnswer = (try? CalculatorExactNumber(lastAnswerText)) ?? .zero
        let exactMemory = memoryText.flatMap { try? CalculatorExactNumber($0) }
        do {
            let exact = try CalculatorExactExpressionEngine.evaluate(
                expression,
                context: CalculatorExactContext(answer: exactAnswer, memory: exactMemory)
            )
            return CalculatorResolvedValue(
                text: exact.displayDescription,
                doubleValue: exact.doubleValue,
                exact: exact
            )
        } catch CalculatorExactError.floatingPointRequired {
            let value = try CalculatorExpressionEngine.evaluate(
                expression,
                context: .standard(
                    answer: exactAnswer.doubleValue ?? .nan,
                    memory: exactMemory.map { $0.doubleValue ?? .nan },
                    angleUnit: angleUnit
                )
            )
            let text = CalculatorExpressionEngine.formatted(value, grouping: false)
            return CalculatorResolvedValue(
                text: text,
                doubleValue: value,
                exact: try? CalculatorExactNumber(text)
            )
        }
    }

    private func updatePreview(showError: Bool) {
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resultText = "0"
            errorMessage = nil
            return
        }
        do {
            let resolved = try currentResolvedValue()
            resultText = resolved.text
            errorMessage = nil
        } catch {
            resultText = "—"
            errorMessage = showError ? error.localizedDescription : nil
        }
    }

    private func updateMemory(by multiplier: Int) {
        do {
            let resolved = try currentResolvedValue()
            guard let value = resolved.exact else {
                throw CalculatorExactError.invalidNumber(resolved.text)
            }
            let existing = memoryText.flatMap { try? CalculatorExactNumber($0) } ?? .zero
            let updated = try existing.adding(multiplier < 0 ? value.negated() : value)
            memoryText = updated.description
            defaults.set(updated.description, forKey: Key.memoryExact)
            if let doubleValue = updated.doubleValue {
                defaults.set(doubleValue, forKey: Key.memory)
            } else {
                defaults.removeObject(forKey: Key.memory)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recordHistory(value: Double, formatted: String, exactValue: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.expression == trimmed && $0.result == formatted }
        history.insert(CalculatorHistoryItem(
            id: UUID(),
            expression: trimmed,
            result: formatted,
            value: value,
            createdAt: Date(),
            exactValue: exactValue
        ), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        defaults.set(try? JSONEncoder().encode(history), forKey: Key.history)
    }

    private func persistGraphEquations() {
        defaults.set(try? JSONEncoder().encode(graphEquations), forKey: Key.graphEquations)
    }

    private func persistGraphSettings() {
        defaults.set(graphXMinimum, forKey: Key.graphXMinimum)
        defaults.set(graphXMaximum, forKey: Key.graphXMaximum)
        defaults.set(graphUsesAutomaticY, forKey: Key.graphAutomaticY)
        defaults.set(graphYMinimum, forKey: Key.graphYMinimum)
        defaults.set(graphYMaximum, forKey: Key.graphYMaximum)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static let defaultGraphEquations = [
        CalculatorGraphEquation(id: UUID(), expression: "sin(x)", isEnabled: true, colorIndex: 0),
        CalculatorGraphEquation(id: UUID(), expression: "cos(x)", isEnabled: true, colorIndex: 1),
        CalculatorGraphEquation(id: UUID(), expression: "x^2 / 10", isEnabled: false, colorIndex: 2),
    ]

    private enum Key {
        static let mode = "calculator.mode"
        static let angleUnit = "calculator.angleUnit"
        static let lastAnswer = "calculator.lastAnswer"
        static let lastAnswerExact = "calculator.lastAnswerExact"
        static let memory = "calculator.memory"
        static let memoryExact = "calculator.memoryExact"
        static let history = "calculator.history"
        static let graphEquations = "calculator.graphEquations"
        static let graphXMinimum = "calculator.graphXMinimum"
        static let graphXMaximum = "calculator.graphXMaximum"
        static let graphAutomaticY = "calculator.graphAutomaticY"
        static let graphYMinimum = "calculator.graphYMinimum"
        static let graphYMaximum = "calculator.graphYMaximum"
    }
}
