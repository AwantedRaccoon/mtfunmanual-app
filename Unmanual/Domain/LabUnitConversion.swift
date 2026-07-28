import Foundation

enum LabUnitDimension: String, Equatable, Sendable {
    case massConcentration
    case amountConcentration
}

struct LabUnitRule: Identifiable, Equatable, Sendable {
    let id: String
    let symbol: String
    let dimension: LabUnitDimension
    fileprivate let factorToBase: Decimal
    fileprivate let aliases: Set<String>
}

enum LabUnitConversionFailure: Error, Equatable, Sendable {
    case invalidDecimal
    case unsupportedUnit
    case incompatibleDimensions
    case arithmeticFailure
}

struct LabUnitConversionResult: Equatable, Sendable {
    let canonicalDecimalString: String
    let comparator: LabValueComparator?
    let sourceUnitID: String
    let targetUnitID: String
    let targetSymbol: String
    let ruleID: String
    let ruleVersion: String
}

enum LabUnitConversionRulesV1 {
    static let version = "lab-unit-conversion/1"

    private static func decimal(_ value: String) -> Decimal {
        guard let result = Decimal(
            string: value,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            preconditionFailure("Invalid frozen Decimal factor")
        }
        return result
    }

    static let units: [LabUnitRule] = [
        LabUnitRule(
            id: "mass.g-per-l",
            symbol: "g/L",
            dimension: .massConcentration,
            factorToBase: decimal("1"),
            aliases: ["g/L"]
        ),
        LabUnitRule(
            id: "mass.mg-per-dl",
            symbol: "mg/dL",
            dimension: .massConcentration,
            factorToBase: decimal("0.01"),
            aliases: ["mg/dL"]
        ),
        LabUnitRule(
            id: "mass.mg-per-l",
            symbol: "mg/L",
            dimension: .massConcentration,
            factorToBase: decimal("0.001"),
            aliases: ["mg/L"]
        ),
        LabUnitRule(
            id: "mass.microgram-per-l",
            symbol: "µg/L",
            dimension: .massConcentration,
            factorToBase: decimal("0.000001"),
            aliases: ["µg/L", "μg/L", "ug/L"]
        ),
        LabUnitRule(
            id: "mass.ng-per-ml",
            symbol: "ng/mL",
            dimension: .massConcentration,
            factorToBase: decimal("0.000001"),
            aliases: ["ng/mL"]
        ),
        LabUnitRule(
            id: "mass.ng-per-dl",
            symbol: "ng/dL",
            dimension: .massConcentration,
            factorToBase: decimal("0.00000001"),
            aliases: ["ng/dL"]
        ),
        LabUnitRule(
            id: "mass.pg-per-ml",
            symbol: "pg/mL",
            dimension: .massConcentration,
            factorToBase: decimal("0.000000001"),
            aliases: ["pg/mL"]
        ),
        LabUnitRule(
            id: "amount.mol-per-l",
            symbol: "mol/L",
            dimension: .amountConcentration,
            factorToBase: decimal("1"),
            aliases: ["mol/L"]
        ),
        LabUnitRule(
            id: "amount.mmol-per-l",
            symbol: "mmol/L",
            dimension: .amountConcentration,
            factorToBase: decimal("0.001"),
            aliases: ["mmol/L"]
        ),
        LabUnitRule(
            id: "amount.micromol-per-l",
            symbol: "µmol/L",
            dimension: .amountConcentration,
            factorToBase: decimal("0.000001"),
            aliases: ["µmol/L", "μmol/L", "umol/L"]
        ),
        LabUnitRule(
            id: "amount.nmol-per-l",
            symbol: "nmol/L",
            dimension: .amountConcentration,
            factorToBase: decimal("0.000000001"),
            aliases: ["nmol/L"]
        ),
        LabUnitRule(
            id: "amount.pmol-per-l",
            symbol: "pmol/L",
            dimension: .amountConcentration,
            factorToBase: decimal("0.000000000001"),
            aliases: ["pmol/L"]
        )
    ]

    private static let unitByID = Dictionary(
        uniqueKeysWithValues: units.map { ($0.id, $0) }
    )

    static func unit(for original: String) -> LabUnitRule? {
        let trimmed = original.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return units.first { $0.aliases.contains(trimmed) }
    }

    static func compatibleTargets(
        for sourceUnitOriginal: String
    ) -> [LabUnitRule] {
        guard let source = unit(for: sourceUnitOriginal) else { return [] }
        return units.filter { $0.dimension == source.dimension }
    }

    static func convert(
        canonicalDecimalString: String,
        comparator: LabValueComparator?,
        sourceUnitOriginal: String,
        targetUnitID: String
    ) throws -> LabUnitConversionResult {
        guard canonicalDecimalString.range(
            of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
            options: .regularExpression
        ) != nil,
        let value = Decimal(
            string: canonicalDecimalString,
            locale: Locale(identifier: "en_US_POSIX")
        ),
        NSDecimalNumber(decimal: value) != .notANumber else {
            throw LabUnitConversionFailure.invalidDecimal
        }
        guard let source = unit(for: sourceUnitOriginal),
              let target = unitByID[targetUnitID] else {
            throw LabUnitConversionFailure.unsupportedUnit
        }
        guard source.dimension == target.dimension else {
            throw LabUnitConversionFailure.incompatibleDimensions
        }

        var sourceValue = value
        var sourceFactor = source.factorToBase
        var baseValue = Decimal()
        guard NSDecimalMultiply(
            &baseValue,
            &sourceValue,
            &sourceFactor,
            .plain
        ) == .noError else {
            throw LabUnitConversionFailure.arithmeticFailure
        }
        var recoveredSource = Decimal()
        guard NSDecimalDivide(
            &recoveredSource,
            &baseValue,
            &sourceFactor,
            .plain
        ) == .noError,
        decimalEquals(recoveredSource, sourceValue) else {
            throw LabUnitConversionFailure.arithmeticFailure
        }
        var targetFactor = target.factorToBase
        var converted = Decimal()
        guard NSDecimalDivide(
            &converted,
            &baseValue,
            &targetFactor,
            .plain
        ) == .noError else {
            throw LabUnitConversionFailure.arithmeticFailure
        }
        var recoveredBase = Decimal()
        guard NSDecimalMultiply(
            &recoveredBase,
            &converted,
            &targetFactor,
            .plain
        ) == .noError,
        decimalEquals(recoveredBase, baseValue) else {
            throw LabUnitConversionFailure.arithmeticFailure
        }
        let canonical = NSDecimalNumber(decimal: converted).stringValue
        guard canonical != "NaN",
              let reparsed = Decimal(
                  string: canonical,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              decimalEquals(reparsed, converted) else {
            throw LabUnitConversionFailure.arithmeticFailure
        }
        return LabUnitConversionResult(
            canonicalDecimalString: canonical,
            comparator: comparator,
            sourceUnitID: source.id,
            targetUnitID: target.id,
            targetSymbol: target.symbol,
            ruleID: source.id + "->" + target.id,
            ruleVersion: version
        )
    }

    private static func decimalEquals(
        _ lhs: Decimal,
        _ rhs: Decimal
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return NSDecimalCompare(&lhs, &rhs) == .orderedSame
    }
}
