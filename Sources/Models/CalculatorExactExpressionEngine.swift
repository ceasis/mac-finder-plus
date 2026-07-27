import Foundation

struct CalculatorExactContext: Sendable {
    var answer: CalculatorExactNumber
    var memory: CalculatorExactNumber?
}

enum CalculatorExactExpressionEngine {
    static func evaluate(
        _ expression: String,
        context: CalculatorExactContext
    ) throws -> CalculatorExactNumber {
        let normalized = expression
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "√", with: "sqrt")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalculatorExpressionError.emptyExpression
        }

        var lexer = CalculatorExactLexer(normalized)
        let tokens = try lexer.tokenize()
        var parser = CalculatorExactParser(tokens: tokens)
        let root = try parser.parse()
        return try evaluate(root, context: context)
    }

    private static func evaluate(
        _ node: CalculatorExactNode,
        context: CalculatorExactContext
    ) throws -> CalculatorExactNumber {
        switch node {
        case .number(let literal):
            return try CalculatorExactNumber(literal)
        case .variable(let name):
            switch name {
            case "ans": return context.answer
            case "mem":
                guard let memory = context.memory else {
                    throw CalculatorExpressionError.unknownIdentifier("mem")
                }
                return memory
            case "x": throw CalculatorExactError.floatingPointRequired
            default: throw CalculatorExpressionError.unknownIdentifier(name)
            }
        case .unary(let isNegative, let child):
            let value = try evaluate(child, context: context)
            return isNegative ? value.negated() : value
        case .binary(let operation, let left, let right):
            let lhs = try evaluate(left, context: context)
            let rhs = try evaluate(right, context: context)
            switch operation {
            case .add: return try lhs.adding(rhs)
            case .subtract: return try lhs.subtracting(rhs)
            case .multiply: return try lhs.multiplied(by: rhs)
            case .divide: return try lhs.divided(by: rhs)
            case .power: return try lhs.raised(to: rhs)
            }
        case .percent(let child):
            return try evaluate(child, context: context).percentage()
        case .factorial(let child):
            return try evaluate(child, context: context).factorial()
        case .function(let name, let arguments):
            let values = try arguments.map { try evaluate($0, context: context) }
            return try evaluateFunction(name, values: values)
        }
    }

    private static func evaluateFunction(
        _ name: String,
        values: [CalculatorExactNumber]
    ) throws -> CalculatorExactNumber {
        func unary() throws -> CalculatorExactNumber {
            guard values.count == 1 else {
                throw CalculatorExpressionError.wrongArgumentCount(name)
            }
            return values[0]
        }

        func binary() throws -> (CalculatorExactNumber, CalculatorExactNumber) {
            guard values.count == 2 else {
                throw CalculatorExpressionError.wrongArgumentCount(name)
            }
            return (values[0], values[1])
        }

        switch name {
        case "abs": return try unary().absoluteValue()
        case "floor": return try unary().floorValue()
        case "ceil": return try unary().ceilValue()
        case "round": return try unary().roundedValue()
        case "sqrt": return try unary().exactSquareRoot()
        case "min":
            let pair = try binary()
            return min(pair.0, pair.1)
        case "max":
            let pair = try binary()
            return max(pair.0, pair.1)
        case "pow":
            let pair = try binary()
            return try pair.0.raised(to: pair.1)
        case "mod":
            let pair = try binary()
            return try pair.0.remainder(dividingBy: pair.1)
        case "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
                "cbrt", "ln", "log", "exp":
            throw CalculatorExactError.floatingPointRequired
        default:
            throw CalculatorExactError.floatingPointRequired
        }
    }
}

private indirect enum CalculatorExactNode {
    case number(String)
    case variable(String)
    case unary(isNegative: Bool, CalculatorExactNode)
    case binary(CalculatorExactBinaryOperation, CalculatorExactNode, CalculatorExactNode)
    case percent(CalculatorExactNode)
    case factorial(CalculatorExactNode)
    case function(String, [CalculatorExactNode])
}

private enum CalculatorExactBinaryOperation {
    case add
    case subtract
    case multiply
    case divide
    case power
}

private enum CalculatorExactToken: Equatable {
    case number(String)
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
        case .number, .identifier, .leftParenthesis: true
        default: false
        }
    }
}

private struct CalculatorExactLexer {
    let characters: [Character]
    var index = 0

    init(_ expression: String) {
        characters = Array(expression)
    }

    mutating func tokenize() throws -> [CalculatorExactToken] {
        var tokens: [CalculatorExactToken] = []
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

    private mutating func readNumber() throws -> String {
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
            if exponentEnd > exponentStart { index = exponentEnd }
        }

        let literal = String(characters[start..<index])
        guard literal != "." else { throw CalculatorExpressionError.invalidNumber(literal) }
        return literal
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

private struct CalculatorExactParser {
    let tokens: [CalculatorExactToken]
    var index = 0

    mutating func parse() throws -> CalculatorExactNode {
        let expression = try parseAdditive()
        guard current == .end else { throw CalculatorExpressionError.unexpectedToken }
        return expression
    }

    private var current: CalculatorExactToken { tokens[index] }

    private mutating func advance() {
        if index < tokens.count - 1 { index += 1 }
    }

    private mutating func parseAdditive() throws -> CalculatorExactNode {
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

    private mutating func parseMultiplicative() throws -> CalculatorExactNode {
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

    private mutating func parseUnary() throws -> CalculatorExactNode {
        if current == .plus {
            advance()
            return .unary(isNegative: false, try parseUnary())
        }
        if current == .minus {
            advance()
            return .unary(isNegative: true, try parseUnary())
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> CalculatorExactNode {
        var node = try parsePostfix()
        if current == .power {
            advance()
            node = .binary(.power, node, try parseUnary())
        }
        return node
    }

    private mutating func parsePostfix() throws -> CalculatorExactNode {
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

    private mutating func parsePrimary() throws -> CalculatorExactNode {
        switch current {
        case .number(let literal):
            advance()
            return .number(literal)
        case .identifier(let name):
            advance()
            if current == .leftParenthesis { return try parseFunction(name) }
            switch name {
            case "ans", "mem", "x": return .variable(name)
            case "pi", "π", "e": throw CalculatorExactError.floatingPointRequired
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

    private mutating func parseFunction(_ name: String) throws -> CalculatorExactNode {
        advance()
        var arguments: [CalculatorExactNode] = []
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
