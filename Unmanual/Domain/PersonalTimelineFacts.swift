import Foundation

enum PersonalTimelineCapacity {
    static let maximumLabResultsPerSample = 256
    // V5 conservatively creates one definition per legacy lab; the frozen
    // five-year migration fixture contains 1,200 legacy records.
    static let maximumLabItemDefinitions = 2_048
    static let maximumStatusMetricDefinitions = 256
    static let maximumAdministrationRecordsPerPageResolution = 4_096
    static let administrationScanChunkSize = 256
    static let maximumSameInstantCursorTieCount = 256
}

enum StatusScaleCopy {
    static let accessibilityHint =
        "1 到 4 从低到高；这是个人记录刻度，不是医学等级。"
    static let editorGuidance =
        accessibilityHint + "只用于你自己的前后比较。"
    static let detailGuidance = accessibilityHint
}

enum LabValueComparator: String, Codable, Equatable, Sendable {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

enum LabDecimalValueError: Error, Equatable, Sendable {
    case invalid
}

struct LabDecimalValue: Equatable, Sendable {
    let original: String
    let comparator: LabValueComparator?
    let canonicalDecimal: String

    static func parse(_ input: String) throws -> LabDecimalValue {
        let parseable = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parseable.isEmpty else { throw LabDecimalValueError.invalid }

        let parsedComparator = comparatorAndRemainder(from: parseable)
        let normalizedNumber = parsedComparator.remainder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "．", with: ".")

        guard normalizedNumber.range(
            of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
            options: .regularExpression
        ) != nil,
        let decimal = Decimal(
            string: normalizedNumber,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw LabDecimalValueError.invalid
        }

        let canonical = NSDecimalNumber(decimal: decimal).stringValue
        guard canonical != "NaN" else { throw LabDecimalValueError.invalid }

        return LabDecimalValue(
            original: input,
            comparator: parsedComparator.comparator,
            canonicalDecimal: canonical
        )
    }

    private static func comparatorAndRemainder(
        from value: String
    ) -> (comparator: LabValueComparator?, remainder: String) {
        let candidates: [(String, LabValueComparator)] = [
            ("<=", .lessThanOrEqual),
            ("≤", .lessThanOrEqual),
            (">=", .greaterThanOrEqual),
            ("≥", .greaterThanOrEqual),
            ("<", .lessThan),
            ("＜", .lessThan),
            (">", .greaterThan),
            ("＞", .greaterThan)
        ]
        for (prefix, comparator) in candidates where value.hasPrefix(prefix) {
            return (comparator, String(value.dropFirst(prefix.count)))
        }
        return (nil, value)
    }
}
