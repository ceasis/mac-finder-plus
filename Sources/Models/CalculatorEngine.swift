import Darwin
import Foundation

enum CalculatorAngleUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case degrees
    case radians

    var id: String { rawValue }
    var title: String { self == .degrees ? "DEG" : "RAD" }
}

enum CalculatorExpressionError: LocalizedError, Equatable {
    case emptyExpression
    case invalidNumber(String)
    case unexpectedToken
    case missingClosingParenthesis
    case unknownIdentifier(String)
    case unknownFunction(String)
    case wrongArgumentCount(String)
    case divisionByZero
    case domain(String)
    case nonFiniteResult

    var errorDescription: String? {
        switch self {
        case .emptyExpression:
            "Enter an expression."
        case .invalidNumber(let value):
            "“\(value)” is not a valid number."
        case .unexpectedToken:
            "The expression is incomplete or contains an unexpected symbol."
        case .missingClosingParenthesis:
            "A closing parenthesis is missing."
        case .unknownIdentifier(let name):
            "Unknown value “\(name)”."
        case .unknownFunction(let name):
            "Unknown function “\(name)”."
        case .wrongArgumentCount(let name):
            "Function “\(name)” has the wrong number of arguments."
        case .divisionByZero:
            "Division by zero is undefined."
        case .domain(let detail):
            detail
        case .nonFiniteResult:
            "The result is outside the supported numeric range."
        }
    }
}

struct CalculatorEvaluationContext: Sendable {
    var x: Double?
    var answer: Double
    var memory: Double?
    var angleUnit: CalculatorAngleUnit

    static func standard(
        answer: Double = 0,
        memory: Double? = nil,
        angleUnit: CalculatorAngleUnit = .degrees
    ) -> CalculatorEvaluationContext {
        CalculatorEvaluationContext(x: nil, answer: answer, memory: memory, angleUnit: angleUnit)
    }
}

struct CalculatorCompiledExpression: Sendable {
    fileprivate let root: CalculatorExpressionNode

    func evaluate(in context: CalculatorEvaluationContext) throws -> Double {
        try CalculatorExpressionEngine.evaluate(root, context: context)
    }
}

enum CalculatorExpressionEngine {
    static func compile(_ expression: String) throws -> CalculatorCompiledExpression {
        let normalized = normalize(expression)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalculatorExpressionError.emptyExpression
        }
        var lexer = CalculatorLexer(normalized)
        let tokens = try lexer.tokenize()
        var parser = CalculatorParser(tokens: tokens)
        return CalculatorCompiledExpression(root: try parser.parse())
    }

    static func evaluate(
        _ expression: String,
        context: CalculatorEvaluationContext = .standard()
    ) throws -> Double {
        try compile(expression).evaluate(in: context)
    }

    static func formatted(_ value: Double, grouping: Bool = true) -> String {
        guard value.isFinite else { return "Error" }
        let cleaned = value == 0 ? 0 : value

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.maximumFractionDigits = 340
        formatter.minimumFractionDigits = 0
        formatter.maximumSignificantDigits = 15
        formatter.usesSignificantDigits = true
        let rendered = formatter.string(from: NSNumber(value: cleaned)) ?? String(cleaned)
        return rendered.replacingOccurrences(of: "-", with: "−")
    }

    fileprivate static func evaluate(
        _ node: CalculatorExpressionNode,
        context: CalculatorEvaluationContext
    ) throws -> Double {
        let result: Double
        switch node {
        case .number(let value):
            result = value
        case .variable(let name):
            switch name {
            case "x":
                guard let x = context.x else {
                    throw CalculatorExpressionError.unknownIdentifier("x")
                }
                result = x
            case "ans":
                result = context.answer
            case "mem":
                guard let memory = context.memory else {
                    throw CalculatorExpressionError.unknownIdentifier("mem")
                }
                result = memory
            default:
                throw CalculatorExpressionError.unknownIdentifier(name)
            }
        case .unary(let operation, let child):
            let value = try evaluate(child, context: context)
            result = operation == .minus ? -value : value
        case .binary(let operation, let left, let right):
            let lhs = try evaluate(left, context: context)
            let rhs = try evaluate(right, context: context)
            switch operation {
            case .add:
                result = lhs + rhs
            case .subtract:
                result = lhs - rhs
            case .multiply:
                result = lhs * rhs
            case .divide:
                guard abs(rhs) > Double.leastNonzeroMagnitude else {
                    throw CalculatorExpressionError.divisionByZero
                }
                result = lhs / rhs
            case .power:
                result = pow(lhs, rhs)
            }
        case .percent(let child):
            result = try evaluate(child, context: context) / 100
        case .factorial(let child):
            let value = try evaluate(child, context: context)
            let rounded = value.rounded()
            guard value >= 0, abs(value - rounded) < 1e-10, rounded <= 170 else {
                throw CalculatorExpressionError.domain(
                    "Factorial requires a whole number from 0 through 170."
                )
            }
            result = rounded == 0 ? 1 : (1...Int(rounded)).reduce(1.0) { $0 * Double($1) }
        case .function(let name, let arguments):
            let values = try arguments.map { try evaluate($0, context: context) }
            result = try evaluateFunction(name, values: values, angleUnit: context.angleUnit)
        }

        guard result.isFinite else { throw CalculatorExpressionError.nonFiniteResult }
        return result
    }

    private static func evaluateFunction(
        _ name: String,
        values: [Double],
        angleUnit: CalculatorAngleUnit
    ) throws -> Double {
        func unary() throws -> Double {
            guard values.count == 1 else {
                throw CalculatorExpressionError.wrongArgumentCount(name)
            }
            return values[0]
        }

        func binary() throws -> (Double, Double) {
            guard values.count == 2 else {
                throw CalculatorExpressionError.wrongArgumentCount(name)
            }
            return (values[0], values[1])
        }

        func angleInput(_ value: Double) -> Double {
            angleUnit == .degrees ? value * .pi / 180 : value
        }

        func angleOutput(_ value: Double) -> Double {
            angleUnit == .degrees ? value * 180 / .pi : value
        }

        switch name {
        case "sin": return sin(angleInput(try unary()))
        case "cos": return cos(angleInput(try unary()))
        case "tan": return tan(angleInput(try unary()))
        case "asin":
            let value = try unary()
            guard (-1...1).contains(value) else {
                throw CalculatorExpressionError.domain("asin requires a value from −1 through 1.")
            }
            return angleOutput(asin(value))
        case "acos":
            let value = try unary()
            guard (-1...1).contains(value) else {
                throw CalculatorExpressionError.domain("acos requires a value from −1 through 1.")
            }
            return angleOutput(acos(value))
        case "atan": return angleOutput(atan(try unary()))
        case "sinh": return sinh(try unary())
        case "cosh": return cosh(try unary())
        case "tanh": return tanh(try unary())
        case "sqrt":
            let value = try unary()
            guard value >= 0 else {
                throw CalculatorExpressionError.domain("Square root requires a nonnegative value.")
            }
            return sqrt(value)
        case "cbrt": return cbrt(try unary())
        case "ln":
            let value = try unary()
            guard value > 0 else {
                throw CalculatorExpressionError.domain("Natural logarithm requires a positive value.")
            }
            return log(value)
        case "log":
            let value = try unary()
            guard value > 0 else {
                throw CalculatorExpressionError.domain("Logarithm requires a positive value.")
            }
            return log10(value)
        case "exp": return exp(try unary())
        case "abs": return abs(try unary())
        case "floor": return floor(try unary())
        case "ceil": return ceil(try unary())
        case "round": return (try unary()).rounded()
        case "min":
            let pair = try binary()
            return min(pair.0, pair.1)
        case "max":
            let pair = try binary()
            return max(pair.0, pair.1)
        case "pow":
            let pair = try binary()
            return pow(pair.0, pair.1)
        case "mod":
            let pair = try binary()
            guard abs(pair.1) > Double.leastNonzeroMagnitude else {
                throw CalculatorExpressionError.divisionByZero
            }
            return pair.0.truncatingRemainder(dividingBy: pair.1)
        default:
            throw CalculatorExpressionError.unknownFunction(name)
        }
    }

    private static func normalize(_ expression: String) -> String {
        expression
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "√", with: "sqrt")
    }
}

private indirect enum CalculatorExpressionNode: Sendable {
    case number(Double)
    case variable(String)
    case unary(CalculatorUnaryOperation, CalculatorExpressionNode)
    case binary(CalculatorBinaryOperation, CalculatorExpressionNode, CalculatorExpressionNode)
    case percent(CalculatorExpressionNode)
    case factorial(CalculatorExpressionNode)
    case function(String, [CalculatorExpressionNode])
}

private enum CalculatorUnaryOperation: Sendable {
    case plus
    case minus
}

private enum CalculatorBinaryOperation: Sendable {
    case add
    case subtract
    case multiply
    case divide
    case power
}

private enum CalculatorToken: Equatable {
    case number(Double)
    case identifier(String)
    case plus
    case minus
    case multiply
    case divide
    case power
    case percent
    case factorial
    case leftParenthesis
    case rightParenthesis
    case comma
    case end

    var beginsImplicitFactor: Bool {
        switch self {
        case .number, .identifier, .leftParenthesis:
            true
        default:
            false
        }
    }
}

private struct CalculatorLexer {
    let characters: [Character]
    var index = 0

    init(_ expression: String) {
        characters = Array(expression)
    }

    mutating func tokenize() throws -> [CalculatorToken] {
        var tokens: [CalculatorToken] = []
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character.isNumber || character == "." {
                tokens.append(.number(try readNumber()))
                continue
            }
            if character.isLetter || character == "π" || character == "_" {
                tokens.append(.identifier(readIdentifier()))
                continue
            }
            index += 1
            switch character {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*": tokens.append(.multiply)
            case "/": tokens.append(.divide)
            case "^": tokens.append(.power)
            case "%": tokens.append(.percent)
            case "!": tokens.append(.factorial)
            case "(": tokens.append(.leftParenthesis)
            case ")": tokens.append(.rightParenthesis)
            case ",": tokens.append(.comma)
            default: throw CalculatorExpressionError.unexpectedToken
            }
        }
        tokens.append(.end)
        return tokens
    }

    private mutating func readNumber() throws -> Double {
        let start = index
        var sawDecimal = false
        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                index += 1
            } else if character == ".", !sawDecimal {
                sawDecimal = true
                index += 1
            } else {
                break
            }
        }

        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            var exponentEnd = index + 1
            if exponentEnd < characters.count,
               characters[exponentEnd] == "+" || characters[exponentEnd] == "-" {
                exponentEnd += 1
            }
            let exponentStart = exponentEnd
            while exponentEnd < characters.count, characters[exponentEnd].isNumber {
                exponentEnd += 1
            }
            if exponentEnd > exponentStart {
                index = exponentEnd
            }
        }

        let text = String(characters[start..<index])
        guard text != ".", let value = Double(text) else {
            throw CalculatorExpressionError.invalidNumber(text)
        }
        return value
    }

    private mutating func readIdentifier() -> String {
        let start = index
        index += 1
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            index += 1
        }
        return String(characters[start..<index]).lowercased()
    }
}

private struct CalculatorParser {
    let tokens: [CalculatorToken]
    var index = 0

    mutating func parse() throws -> CalculatorExpressionNode {
        let expression = try parseAdditive()
        guard current == .end else { throw CalculatorExpressionError.unexpectedToken }
        return expression
    }

    private var current: CalculatorToken { tokens[index] }

    private mutating func advance() {
        if index < tokens.count - 1 { index += 1 }
    }

    private mutating func parseAdditive() throws -> CalculatorExpressionNode {
        var node = try parseMultiplicative()
        while true {
            if current == .plus {
                advance()
                node = .binary(.add, node, try parseMultiplicative())
            } else if current == .minus {
                advance()
                node = .binary(.subtract, node, try parseMultiplicative())
            } else {
                return node
            }
        }
    }

    private mutating func parseMultiplicative() throws -> CalculatorExpressionNode {
        var node = try parseUnary()
        while true {
            if current == .multiply {
                advance()
                node = .binary(.multiply, node, try parseUnary())
            } else if current == .divide {
                advance()
                node = .binary(.divide, node, try parseUnary())
            } else if current.beginsImplicitFactor {
                node = .binary(.multiply, node, try parseUnary())
            } else {
                return node
            }
        }
    }

    private mutating func parseUnary() throws -> CalculatorExpressionNode {
        if current == .plus {
            advance()
            return .unary(.plus, try parseUnary())
        }
        if current == .minus {
            advance()
            return .unary(.minus, try parseUnary())
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> CalculatorExpressionNode {
        var node = try parsePostfix()
        if current == .power {
            advance()
            node = .binary(.power, node, try parseUnary())
        }
        return node
    }

    private mutating func parsePostfix() throws -> CalculatorExpressionNode {
        var node = try parsePrimary()
        while true {
            if current == .percent {
                advance()
                node = .percent(node)
            } else if current == .factorial {
                advance()
                node = .factorial(node)
            } else {
                return node
            }
        }
    }

    private mutating func parsePrimary() throws -> CalculatorExpressionNode {
        switch current {
        case .number(let value):
            advance()
            return .number(value)
        case .identifier(let name):
            advance()
            if current == .leftParenthesis {
                return try parseFunction(name)
            }
            switch name {
            case "pi", "π": return .number(.pi)
            case "e": return .number(M_E)
            case "x", "ans", "mem": return .variable(name)
            default: throw CalculatorExpressionError.unknownIdentifier(name)
            }
        case .leftParenthesis:
            advance()
            let node = try parseAdditive()
            guard current == .rightParenthesis else {
                throw CalculatorExpressionError.missingClosingParenthesis
            }
            advance()
            return node
        default:
            throw CalculatorExpressionError.unexpectedToken
        }
    }

    private mutating func parseFunction(_ name: String) throws -> CalculatorExpressionNode {
        advance()
        var arguments: [CalculatorExpressionNode] = []
        if current != .rightParenthesis {
            while true {
                arguments.append(try parseAdditive())
                if current == .comma {
                    advance()
                    continue
                }
                break
            }
        }
        guard current == .rightParenthesis else {
            throw CalculatorExpressionError.missingClosingParenthesis
        }
        advance()
        return .function(name, arguments)
    }
}
