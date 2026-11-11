import Foundation

enum ArithmeticOperation: String, Codable, CaseIterable {
    case add, subtract, multiply, divide

    var symbol: String {
        switch self {
        case .add: "+"
        case .subtract: "−"
        case .multiply: "×"
        case .divide: "÷"
        }
    }
}

struct ParsedAmount {
    let operation: ArithmeticOperation
    let value: Decimal
    let isPercent: Bool
    let spoken: String
}

enum ParsedInput {
    case undo
    case amounts([ParsedAmount])
}

enum CalculationParseError: LocalizedError {
    case empty
    case incomplete
    case unclear(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .empty: "Chưa nghe được số nào."
        case .incomplete: "Đang chờ số tiếp theo."
        case .unclear(let phrase): "Chưa hiểu rõ: \(phrase). Hãy sửa hoặc đọc lại."
        case .tooLarge: "Số tiền vượt giới hạn cho phép."
        }
    }
}

struct VietnameseNumberParser {
    private static let digits: [String: Int] = [
        "khong": 0, "mot": 1, "hai": 2, "ba": 3, "bon": 4, "tu": 4,
        "nam": 5, "lam": 5, "sau": 6, "bay": 7, "tam": 8, "chin": 9
    ]
    private static let scales: [String: Int] = [
        "ngan": 1_000, "nghin": 1_000, "trieu": 1_000_000, "ty": 1_000_000_000
    ]
    private static let ignored: Set<String> = [
        "dong", "vnd", "huf", "ft", "forint", "forints", "la", "so", "khoang"
    ]

    static func fold(_ input: String) -> String {
        input.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            .replacingOccurrences(of: "’", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ source: String, pattern: String, with replacement: String) -> String {
        source.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func matches(_ input: String, _ pattern: String) -> Bool {
        input.range(of: pattern, options: .regularExpression) != nil
    }

    static func parse(_ raw: String) throws -> ParsedInput {
        var text = fold(raw)
        if text.isEmpty { throw CalculationParseError.empty }
        if matches(text, #"^(hoan tac|quay lai|xoa so vua roi|undo)$"#) { return .undo }

        text = text.replacingOccurrences(of: "＋", with: "+")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
        text = replace(text, pattern: #"\b(cong them|cong vao|them vao)\b"#, with: "cong")
        text = replace(text, pattern: #"\b(tru di|bot di|bot ra)\b"#, with: "tru")
        text = replace(text, pattern: #"\b(nhan voi)\b"#, with: "nhan")
        text = replace(text, pattern: #"\b(chia cho)\b"#, with: "chia")
        text = replace(text, pattern: #"\b(bang bao nhieu|bang may|bang|tiep theo|tiep tuc|ket qua)\b"#, with: " ")
        text = replace(text, pattern: #"\b(tinh|so tien|tong la|duoc)\b"#, with: " ")
        text = replace(text, pattern: #"\b(oi|nhe|nha|di|giup|toi|nao)\b"#, with: " ")

        // Separate spoken clauses without breaking 15.000 or 1,500.
        text = replace(text, pattern: #"(?<=\p{L})[,.!?;](?=\s|$)"#, with: " |+| ")
        text = replace(text, pattern: #"(?<=\d)[.!?;](?=\s|$)"#, with: " |+| ")
        text = replace(text, pattern: #"\s*,\s+"#, with: " |+| ")
        text = replace(text, pattern: #"([+*/-])"#, with: " |$1| ")
        for (word, op) in [("cong", "+"), ("tru", "-"), ("bot", "-"), ("nhan", "*"), ("chia", "/")] {
            text = replace(text, pattern: "\\b\(word)\\b", with: " |\(op)| ")
        }
        text = replace(text, pattern: #"\s+"#, with: " ")

        let chunks = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        var operation = ArithmeticOperation.add
        var amounts: [ParsedAmount] = []
        for (index, chunk) in chunks.enumerated() {
            if chunk.isEmpty { continue }
            if let op = ["+": ArithmeticOperation.add, "-": .subtract,
                         "*": .multiply, "/": .divide][chunk] {
                if index == chunks.count - 1 || chunks[(index + 1)...].allSatisfy({ $0.isEmpty }) {
                    throw CalculationParseError.incomplete
                }
                operation = op
                continue
            }
            for group in splitConsecutiveAmounts(chunk) {
                var valueText = group
                let percent = matches(valueText, #"(phan tram|%)\s*$"#)
                if percent {
                    valueText = replace(valueText, pattern: #"(phan tram|%)\s*$"#, with: "")
                    if operation != .add && operation != .subtract {
                        throw CalculationParseError.unclear(group)
                    }
                }
                let number = try parseAmount(valueText)
                amounts.append(ParsedAmount(operation: operation, value: number,
                                            isPercent: percent, spoken: group))
                operation = .add
            }
        }
        if amounts.isEmpty { throw CalculationParseError.empty }
        if amounts.count > 150 { throw CalculationParseError.tooLarge }
        return .amounts(amounts)
    }

    private static func splitConsecutiveAmounts(_ phrase: String) -> [String] {
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1 && words.allSatisfy({ matches($0, #"^\d+(?:[.,]\d+)*$"#) }) {
            return words
        }
        var groups: [String] = []
        var current: [String] = []
        var previousScale: Int?
        var previousScalePosition = -1
        for word in words {
            if let scale = scales[word], let earlier = previousScale,
               scale >= earlier, previousScalePosition >= 0,
               previousScalePosition < current.count - 1 {
                groups.append(current[...previousScalePosition].joined(separator: " "))
                current = Array(current[(previousScalePosition + 1)...])
                current.append(word)
                previousScale = scale
                previousScalePosition = current.count - 1
            } else {
                current.append(word)
                if let scale = scales[word] {
                    previousScale = scale
                    previousScalePosition = current.count - 1
                }
            }
        }
        if !current.isEmpty { groups.append(current.joined(separator: " ")) }
        return groups
    }

    static func parseAmount(_ phrase: String) throws -> Decimal {
        let cleaned = replace(fold(phrase), pattern: #"\b(vnd|dong|forint|forints|huf|ft)\b"#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { throw CalculationParseError.empty }
        if matches(cleaned, #"^\d{1,3}(?:[.,]\d{3})+$"#) {
            let number = cleaned.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: "")
            guard let decimal = Decimal(string: number) else { throw CalculationParseError.unclear(phrase) }
            return decimal
        }
        if matches(cleaned, #"^\d+(?:[.,]\d+)?$"#) {
            guard let decimal = Decimal(string: cleaned.replacingOccurrences(of: ",", with: ".")) else {
                throw CalculationParseError.unclear(phrase)
            }
            return decimal
        }
        let tokens = replace(cleaned, pattern: #"(?<=\d)[.,](?=\d{3}(?:\b|[.,]))"#, with: "")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init).filter { !ignored.contains($0) }
        if tokens.isEmpty { throw CalculationParseError.empty }
        var total: Double = 0
        var part: [String] = []
        var lastScale: Int?
        var halfAfterScale = false
        for word in tokens {
            if let multiplier = scales[word] {
                if let previous = lastScale, multiplier >= previous {
                    throw CalculationParseError.unclear(phrase)
                }
                let small = try parseSmall(part)
                total += (small.empty ? 1.0 : small.value) * Double(multiplier)
                part.removeAll()
                lastScale = multiplier
                halfAfterScale = false
            } else if word == "ruoi" && part.isEmpty, let multiplier = lastScale {
                total += Double(multiplier) / 2
                halfAfterScale = true
            } else {
                if halfAfterScale { throw CalculationParseError.unclear(phrase) }
                part.append(word)
            }
        }
        if !part.isEmpty {
            let small = try parseSmall(part)
            if let lastScale {
                if small.oneDigit {
                    total += small.value * Double(lastScale) / 10
                } else if lastScale > 1_000 {
                    total += small.value * Double(lastScale) / 1_000
                } else {
                    total += small.value
                }
            } else {
                total += small.value
            }
        }
        guard total.isFinite, abs(total) <= 1.0e14 else { throw CalculationParseError.tooLarge }
        return Decimal(total)
    }

    private struct SmallNumber {
        var value: Double
        var empty: Bool
        var oneDigit: Bool
    }

    private static func parseSmall(_ words: [String]) throws -> SmallNumber {
        if words.isEmpty { return SmallNumber(value: 0, empty: true, oneDigit: false) }
        var total = 0.0
        var pending: Double?
        var hasUnit = false
        var hasHalf = false
        var hasZero = false
        for (i, word) in words.enumerated() {
            if let num = Double(word), matches(word, #"^\d+$"#) {
                if pending != nil { throw CalculationParseError.unclear(words.joined(separator: " ")) }
                pending = num
                continue
            }
            if let digit = digits[word] {
                if pending != nil { throw CalculationParseError.unclear(words.joined(separator: " ")) }
                pending = Double(digit)
                if digit == 0 { hasZero = true }
                continue
            }
            switch word {
            case "tram":
                guard let pendingDigit = pending else {
                    throw CalculationParseError.unclear(words.joined(separator: " "))
                }
                total += pendingDigit * 100
                pending = nil
                hasUnit = true
            case "muoi", "chuc":
                total += (pending ?? 1) * 10
                pending = nil
                hasUnit = true
            case "linh", "le":
                if pending != nil { throw CalculationParseError.unclear(words.joined(separator: " ")) }
            case "ruoi":
                if i != words.count - 1 { throw CalculationParseError.unclear(words.joined(separator: " ")) }
                total += pending ?? 0
                pending = nil
                total += 0.5
                hasHalf = true
            default:
                throw CalculationParseError.unclear(word)
            }
        }
        if let pending { total += pending }
        return SmallNumber(value: total, empty: false,
                           oneDigit: !hasUnit && !hasHalf && !hasZero && total > 0 && total < 10)
    }
}