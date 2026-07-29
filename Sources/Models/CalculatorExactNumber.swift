import Foundation

enum CalculatorExactError: LocalizedError, Equatable {
    case floatingPointRequired
    case digitLimitExceeded
    case divisionByZero
    case integerRequired(String)
    case domain(String)
    case invalidNumber(String)

    var errorDescription: String? {
        switch self {
        case .floatingPointRequired:
            "This operation requires floating-point math."
        case .digitLimitExceeded:
            "Results are limited to 1,000 digits."
        case .divisionByZero:
            "Division by zero is undefined."
        case .integerRequired(let operation):
            "\(operation) requires a whole number."
        case .domain(let message):
            message
        case .invalidNumber(let value):
            "“\(value)” is not a valid number."
        }
    }
}

/// A base-10 arbitrary-precision decimal used by the calculator's exact path.
/// Its decimal representation is intentionally capped at 1,000 digits so UI,
/// persistence, and arithmetic costs remain predictable.
struct CalculatorExactNumber: Equatable, Comparable, Sendable, CustomStringConvertible {
    static let maximumDigits = 1_000
    static let zero = try! CalculatorExactNumber("0")
    static let one = try! CalculatorExactNumber("1")

    private(set) var sign: Int
    private(set) var coefficient: CalculatorBigUInt
    private(set) var scale: Int

    init(_ literal: String) throws {
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CalculatorExactError.invalidNumber(literal) }

        var body = trimmed
        var parsedSign = 1
        if body.first == "+" {
            body.removeFirst()
        } else if body.first == "-" || body.first == "−" {
            parsedSign = -1
            body.removeFirst()
        }

        let exponentParts = body.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "e" || $0 == "E" }
        )
        guard exponentParts.count <= 2, let mantissaPart = exponentParts.first else {
            throw CalculatorExactError.invalidNumber(literal)
        }

        let exponent: Int
        if exponentParts.count == 2 {
            guard let parsed = Int(exponentParts[1]), abs(parsed) <= Self.maximumDigits else {
                throw CalculatorExactError.digitLimitExceeded
            }
            exponent = parsed
        } else {
            exponent = 0
        }

        let mantissa = String(mantissaPart)
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { throw CalculatorExactError.invalidNumber(literal) }
        let whole = String(pieces[0])
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard (!whole.isEmpty || !fraction.isEmpty),
              whole.allSatisfy({ $0.isNumber }),
              fraction.allSatisfy({ $0.isNumber }) else {
            throw CalculatorExactError.invalidNumber(literal)
        }

        let digits = (whole + fraction).drop(while: { $0 == "0" })
        let parsedCoefficient = CalculatorBigUInt(decimal: String(digits)) ?? .zero
        var parsedScale = fraction.count - exponent
        var adjustedCoefficient = parsedCoefficient
        if parsedScale < 0 {
            adjustedCoefficient = adjustedCoefficient.shiftedDecimal(by: -parsedScale)
            parsedScale = 0
        }

        sign = adjustedCoefficient.isZero ? 0 : parsedSign
        coefficient = adjustedCoefficient
        scale = parsedScale
        normalize()
        try validateDigitLimit()
    }

    private init(sign: Int, coefficient: CalculatorBigUInt, scale: Int) throws {
        self.sign = coefficient.isZero ? 0 : (sign < 0 ? -1 : 1)
        self.coefficient = coefficient
        self.scale = max(0, scale)
        normalize()
        try validateDigitLimit()
    }

    var description: String {
        guard sign != 0 else { return "0" }
        let digits = coefficient.description
        let unsigned: String
        if scale == 0 {
            unsigned = digits
        } else if digits.count <= scale {
            unsigned = "0." + String(repeating: "0", count: scale - digits.count) + digits
        } else {
            let split = digits.index(digits.endIndex, offsetBy: -scale)
            unsigned = String(digits[..<split]) + "." + String(digits[split...])
        }
        return sign < 0 ? "−" + unsigned : unsigned
    }

    /// A compact UI representation for decimal expansions that reached the
    /// calculator's precision limit and end in a stable repeating cycle.
    ///
    /// Parentheses are used as recurrence notation, so `0.1(6)` means
    /// `0.1666…`. Finite decimals and long integers are returned unchanged.
    var displayDescription: String {
        guard scale > 0,
              max(coefficient.decimalDigitCount, scale) == Self.maximumDigits else {
            return description
        }

        let fullText = description
        guard let decimalIndex = fullText.firstIndex(of: ".") else {
            return fullText
        }
        let fractionStart = fullText.index(after: decimalIndex)
        let fractionalDigits = Array(fullText[fractionStart...])
        guard let repetition = Self.repeatingSuffix(in: fractionalDigits) else {
            return fullText
        }

        let nonRepeating = String(fractionalDigits[..<repetition.start])
        let repeating = String(
            fractionalDigits[
                repetition.start..<(repetition.start + repetition.length)
            ]
        )
        return "\(fullText[..<decimalIndex]).\(nonRepeating)(\(repeating))"
    }

    var doubleValue: Double? {
        let normalized = description.replacingOccurrences(of: "−", with: "-")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    var isZero: Bool { sign == 0 }
    var isInteger: Bool { scale == 0 }
    var isNegative: Bool { sign < 0 }

    static func < (lhs: CalculatorExactNumber, rhs: CalculatorExactNumber) -> Bool {
        if lhs.sign != rhs.sign { return lhs.sign < rhs.sign }
        guard lhs.sign != 0 else { return false }
        let comparison = lhs.compareMagnitude(to: rhs)
        return lhs.sign > 0 ? comparison < 0 : comparison > 0
    }

    func negated() -> CalculatorExactNumber {
        guard sign != 0 else { return self }
        var copy = self
        copy.sign *= -1
        return copy
    }

    func absoluteValue() -> CalculatorExactNumber {
        guard sign < 0 else { return self }
        var copy = self
        copy.sign = 1
        return copy
    }

    func adding(_ other: CalculatorExactNumber) throws -> CalculatorExactNumber {
        guard sign != 0 else { return other }
        guard other.sign != 0 else { return self }
        let aligned = alignedCoefficients(with: other)
        if sign == other.sign {
            return try CalculatorExactNumber(
                sign: sign,
                coefficient: aligned.left.adding(aligned.right),
                scale: aligned.scale
            )
        }

        if aligned.left == aligned.right { return .zero }
        if aligned.left > aligned.right {
            return try CalculatorExactNumber(
                sign: sign,
                coefficient: aligned.left.subtracting(aligned.right),
                scale: aligned.scale
            )
        }
        return try CalculatorExactNumber(
            sign: other.sign,
            coefficient: aligned.right.subtracting(aligned.left),
            scale: aligned.scale
        )
    }

    func subtracting(_ other: CalculatorExactNumber) throws -> CalculatorExactNumber {
        try adding(other.negated())
    }

    func multiplied(by other: CalculatorExactNumber) throws -> CalculatorExactNumber {
        guard !isZero, !other.isZero else { return .zero }
        return try CalculatorExactNumber(
            sign: sign * other.sign,
            coefficient: coefficient.multiplied(by: other.coefficient),
            scale: scale + other.scale
        )
    }

    func divided(by other: CalculatorExactNumber) throws -> CalculatorExactNumber {
        guard !other.isZero else { throw CalculatorExactError.divisionByZero }
        guard !isZero else { return .zero }

        let numerator = coefficient.shiftedDecimal(by: other.scale)
        let denominator = other.coefficient.shiftedDecimal(by: scale)
        var division = numerator.quotientAndRemainder(dividingBy: denominator)
        var resultCoefficient = division.quotient
        var resultScale = 0

        guard resultCoefficient.decimalDigitCount <= Self.maximumDigits else {
            throw CalculatorExactError.digitLimitExceeded
        }

        while !division.remainder.isZero,
              max(resultCoefficient.decimalDigitCount, resultScale) < Self.maximumDigits {
            let expandedRemainder = division.remainder.multipliedByTen(adding: 0)
            division = expandedRemainder.quotientAndRemainder(dividingBy: denominator)
            let nextDigit = division.quotient.singleDigit ?? 0
            resultCoefficient = resultCoefficient.multipliedByTen(adding: nextDigit)
            resultScale += 1
        }

        return try CalculatorExactNumber(
            sign: sign * other.sign,
            coefficient: resultCoefficient,
            scale: resultScale
        )
    }

    func remainder(dividingBy other: CalculatorExactNumber) throws -> CalculatorExactNumber {
        guard !other.isZero else { throw CalculatorExactError.divisionByZero }
        let aligned = alignedCoefficients(with: other)
        let remainder = aligned.left.quotientAndRemainder(dividingBy: aligned.right).remainder
        return try CalculatorExactNumber(sign: sign, coefficient: remainder, scale: aligned.scale)
    }

    func percentage() throws -> CalculatorExactNumber {
        try CalculatorExactNumber(sign: sign, coefficient: coefficient, scale: scale + 2)
    }

    func raised(to exponent: CalculatorExactNumber) throws -> CalculatorExactNumber {
        guard exponent.isInteger else { throw CalculatorExactError.floatingPointRequired }
        if exponent.isZero { return .one }

        let magnitude = exponent.coefficient
        guard let power = magnitude.intValue(maximum: 1_000_000) else {
            if isZero { return .zero }
            if self == .one { return .one }
            let negativeOne = try CalculatorExactNumber("−1")
            if self == negativeOne {
                return magnitude.isOdd ? self : .one
            }
            throw CalculatorExactError.digitLimitExceeded
        }

        var result = CalculatorExactNumber.one
        var base = self
        var remaining = power
        while remaining > 0 {
            if remaining.isMultiple(of: 2) == false {
                result = try result.multiplied(by: base)
            }
            remaining /= 2
            if remaining > 0 {
                base = try base.multiplied(by: base)
            }
        }
        if exponent.isNegative {
            return try CalculatorExactNumber.one.divided(by: result)
        }
        return result
    }

    func factorial() throws -> CalculatorExactNumber {
        guard isInteger, !isNegative else {
            throw CalculatorExactError.domain(
                "Factorial requires a nonnegative whole number whose result fits within 1,000 digits."
            )
        }
        guard let value = coefficient.intValue(maximum: 100_000) else {
            throw CalculatorExactError.digitLimitExceeded
        }
        if value < 2 { return .one }

        var result = CalculatorExactNumber.one
        for factor in 2...value {
            result = try result.multiplied(by: CalculatorExactNumber(String(factor)))
        }
        return result
    }

    func floorValue() throws -> CalculatorExactNumber {
        guard scale > 0 else { return self }
        let divisor = CalculatorBigUInt.one.shiftedDecimal(by: scale)
        let division = coefficient.quotientAndRemainder(dividingBy: divisor)
        var integer = try CalculatorExactNumber(sign: sign, coefficient: division.quotient, scale: 0)
        if sign < 0, !division.remainder.isZero {
            integer = try integer.subtracting(.one)
        }
        return integer
    }

    func ceilValue() throws -> CalculatorExactNumber {
        guard scale > 0 else { return self }
        let divisor = CalculatorBigUInt.one.shiftedDecimal(by: scale)
        let division = coefficient.quotientAndRemainder(dividingBy: divisor)
        var integer = try CalculatorExactNumber(sign: sign, coefficient: division.quotient, scale: 0)
        if sign > 0, !division.remainder.isZero {
            integer = try integer.adding(.one)
        }
        return integer
    }

    func roundedValue() throws -> CalculatorExactNumber {
        guard scale > 0 else { return self }
        let divisor = CalculatorBigUInt.one.shiftedDecimal(by: scale)
        let division = coefficient.quotientAndRemainder(dividingBy: divisor)
        var integer = try CalculatorExactNumber(sign: sign, coefficient: division.quotient, scale: 0)
        if division.remainder.multiplied(by: CalculatorBigUInt(2)) >= divisor {
            integer = sign < 0 ? try integer.subtracting(.one) : try integer.adding(.one)
        }
        return integer
    }

    func exactSquareRoot() throws -> CalculatorExactNumber {
        guard !isNegative else {
            throw CalculatorExactError.domain("Square root requires a nonnegative value.")
        }
        guard !isZero else { return .zero }

        var adjustedCoefficient = coefficient
        var adjustedScale = scale
        if adjustedScale.isMultiple(of: 2) == false {
            adjustedCoefficient = adjustedCoefficient.shiftedDecimal(by: 1)
            adjustedScale += 1
        }
        let root = adjustedCoefficient.integerSquareRoot()
        guard root.multiplied(by: root) == adjustedCoefficient else {
            throw CalculatorExactError.floatingPointRequired
        }
        return try CalculatorExactNumber(
            sign: 1,
            coefficient: root,
            scale: adjustedScale / 2
        )
    }

    private mutating func normalize() {
        if coefficient.isZero {
            sign = 0
            scale = 0
            return
        }
        let removed = coefficient.removeTrailingDecimalZeros(maximum: scale)
        scale -= removed
    }

    private func validateDigitLimit() throws {
        let renderedDigits = max(coefficient.decimalDigitCount, scale)
        guard renderedDigits <= Self.maximumDigits else {
            throw CalculatorExactError.digitLimitExceeded
        }
    }

    private func alignedCoefficients(
        with other: CalculatorExactNumber
    ) -> (left: CalculatorBigUInt, right: CalculatorBigUInt, scale: Int) {
        let targetScale = max(scale, other.scale)
        return (
            coefficient.shiftedDecimal(by: targetScale - scale),
            other.coefficient.shiftedDecimal(by: targetScale - other.scale),
            targetScale
        )
    }

    private func compareMagnitude(to other: CalculatorExactNumber) -> Int {
        let aligned = alignedCoefficients(with: other)
        if aligned.left < aligned.right { return -1 }
        if aligned.left > aligned.right { return 1 }
        return 0
    }

    private static func repeatingSuffix(
        in digits: [Character]
    ) -> (start: Int, length: Int)? {
        let minimumRepeats = 6
        let maximumCycleLength = 100
        let largestCandidate = min(maximumCycleLength, digits.count / minimumRepeats)
        guard largestCandidate > 0 else { return nil }

        for cycleLength in 1...largestCandidate {
            let comparisonStart = digits.count - (cycleLength * minimumRepeats)
            let isPeriodic = (comparisonStart..<(digits.count - cycleLength)).allSatisfy {
                digits[$0] == digits[$0 + cycleLength]
            }
            guard isPeriodic else { continue }

            var cycleStart = comparisonStart
            while cycleStart > 0,
                  digits[cycleStart - 1] == digits[cycleStart - 1 + cycleLength] {
                cycleStart -= 1
            }
            return (cycleStart, cycleLength)
        }

        return nil
    }
}

struct CalculatorBigUInt: Equatable, Comparable, Sendable, CustomStringConvertible {
    static let zero = CalculatorBigUInt(0)
    static let one = CalculatorBigUInt(1)

    fileprivate var digits: [UInt8]

    init(_ value: Int) {
        precondition(value >= 0)
        if value == 0 {
            digits = [0]
        } else {
            var remaining = value
            var result: [UInt8] = []
            while remaining > 0 {
                result.append(UInt8(remaining % 10))
                remaining /= 10
            }
            digits = result
        }
    }

    init?(decimal: String) {
        guard !decimal.isEmpty, decimal.allSatisfy(\.isNumber) else { return nil }
        digits = decimal.reversed().compactMap { UInt8(String($0)) }
        normalize()
    }

    private init(bigEndianDigits: [UInt8]) {
        digits = Array(bigEndianDigits.reversed())
        normalize()
    }

    var description: String {
        digits.reversed().map(String.init).joined()
    }

    var isZero: Bool { digits.count == 1 && digits[0] == 0 }
    var isOdd: Bool { digits[0].isMultiple(of: 2) == false }
    var decimalDigitCount: Int { digits.count }
    var singleDigit: UInt8? { digits.count == 1 ? digits[0] : nil }

    static func < (lhs: CalculatorBigUInt, rhs: CalculatorBigUInt) -> Bool {
        if lhs.digits.count != rhs.digits.count { return lhs.digits.count < rhs.digits.count }
        for (left, right) in zip(lhs.digits.reversed(), rhs.digits.reversed()) where left != right {
            return left < right
        }
        return false
    }

    func adding(_ other: CalculatorBigUInt) -> CalculatorBigUInt {
        let count = max(digits.count, other.digits.count)
        var result: [UInt8] = []
        result.reserveCapacity(count + 1)
        var carry = 0
        for index in 0..<count {
            let left = index < digits.count ? Int(digits[index]) : 0
            let right = index < other.digits.count ? Int(other.digits[index]) : 0
            let total = left + right + carry
            result.append(UInt8(total % 10))
            carry = total / 10
        }
        if carry > 0 { result.append(UInt8(carry)) }
        var value = CalculatorBigUInt.zero
        value.digits = result
        value.normalize()
        return value
    }

    /// Subtracts a value known to be no larger than this value.
    func subtracting(_ other: CalculatorBigUInt) -> CalculatorBigUInt {
        precondition(self >= other)
        var result = digits
        var borrow = 0
        for index in result.indices {
            let right = index < other.digits.count ? Int(other.digits[index]) : 0
            var value = Int(result[index]) - right - borrow
            if value < 0 {
                value += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        var value = CalculatorBigUInt.zero
        value.digits = result
        value.normalize()
        return value
    }

    func multiplied(by other: CalculatorBigUInt) -> CalculatorBigUInt {
        guard !isZero, !other.isZero else { return .zero }
        var accumulator = Array(repeating: 0, count: digits.count + other.digits.count + 1)
        for leftIndex in digits.indices {
            for rightIndex in other.digits.indices {
                accumulator[leftIndex + rightIndex] += Int(digits[leftIndex]) * Int(other.digits[rightIndex])
            }
        }
        for index in 0..<(accumulator.count - 1) {
            accumulator[index + 1] += accumulator[index] / 10
            accumulator[index] %= 10
        }
        var value = CalculatorBigUInt.zero
        value.digits = accumulator.map(UInt8.init)
        value.normalize()
        return value
    }

    func shiftedDecimal(by places: Int) -> CalculatorBigUInt {
        guard places > 0, !isZero else { return self }
        var value = self
        value.digits.insert(contentsOf: repeatElement(0, count: places), at: 0)
        return value
    }

    func multipliedByTen(adding digit: UInt8) -> CalculatorBigUInt {
        precondition(digit < 10)
        if isZero { return CalculatorBigUInt(Int(digit)) }
        var value = self
        value.digits.insert(digit, at: 0)
        return value
    }

    func quotientAndRemainder(
        dividingBy divisor: CalculatorBigUInt
    ) -> (quotient: CalculatorBigUInt, remainder: CalculatorBigUInt) {
        precondition(!divisor.isZero)
        guard self >= divisor else { return (.zero, self) }

        var quotientDigits: [UInt8] = []
        quotientDigits.reserveCapacity(digits.count)
        var remainder = CalculatorBigUInt.zero
        for digit in digits.reversed() {
            remainder = remainder.multipliedByTen(adding: digit)
            var quotientDigit: UInt8 = 0
            if remainder >= divisor {
                for candidate in stride(from: 9, through: 1, by: -1) {
                    let product = divisor.multiplied(by: CalculatorBigUInt(candidate))
                    if product <= remainder {
                        quotientDigit = UInt8(candidate)
                        remainder = remainder.subtracting(product)
                        break
                    }
                }
            }
            quotientDigits.append(quotientDigit)
        }
        return (CalculatorBigUInt(bigEndianDigits: quotientDigits), remainder)
    }

    func dividedByTwo() -> CalculatorBigUInt {
        var result: [UInt8] = []
        result.reserveCapacity(digits.count)
        var carry = 0
        for digit in digits.reversed() {
            let value = carry * 10 + Int(digit)
            result.append(UInt8(value / 2))
            carry = value % 2
        }
        return CalculatorBigUInt(bigEndianDigits: result)
    }

    func integerSquareRoot() -> CalculatorBigUInt {
        guard !isZero else { return .zero }
        var estimate = CalculatorBigUInt.one.shiftedDecimal(by: (decimalDigitCount + 1) / 2)
        while true {
            let quotient = quotientAndRemainder(dividingBy: estimate).quotient
            let next = estimate.adding(quotient).dividedByTwo()
            if next >= estimate { return estimate }
            estimate = next
        }
    }

    func intValue(maximum: Int) -> Int? {
        var result = 0
        for digit in digits.reversed() {
            guard result <= (maximum - Int(digit)) / 10 else { return nil }
            result = result * 10 + Int(digit)
        }
        return result <= maximum ? result : nil
    }

    @discardableResult
    fileprivate mutating func removeTrailingDecimalZeros(maximum: Int) -> Int {
        var removed = 0
        while removed < maximum, digits.count > 1, digits.first == 0 {
            digits.removeFirst()
            removed += 1
        }
        normalize()
        return removed
    }

    private mutating func normalize() {
        while digits.count > 1, digits.last == 0 { digits.removeLast() }
        if digits.isEmpty { digits = [0] }
    }
}
