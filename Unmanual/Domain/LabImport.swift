import Foundation
import SwiftData

struct LabImportEntry: Equatable, Sendable {
    let itemName: String
    let itemCode: String
    var rawValue: String
    var unit: String

    var numericValue: Double? {
        let normalized = cleanRawValue
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "．", with: ".")
        return Double(normalized)
    }

    var isComplete: Bool {
        numericValue != nil && !cleanUnit.isEmpty
    }

    var isBlank: Bool {
        cleanRawValue.isEmpty && cleanUnit.isEmpty
    }

    var cleanRawValue: String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cleanUnit: String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
enum LabImportService {
    static func regimen(
        for sampledAt: Date,
        among regimens: [RegimenVersion],
        calendar: Calendar = .autoupdatingCurrent
    ) -> RegimenVersion? {
        let sampleDay = calendar.startOfDay(for: sampledAt)
        return regimens
            .sorted { $0.startedAt > $1.startedAt }
            .first { regimen in
                let startDay = calendar.startOfDay(for: regimen.startedAt)
                let endDay = regimen.endedAt.map { calendar.startOfDay(for: $0) }
                guard startDay <= sampleDay else { return false }
                guard let endDay else { return true }
                return sampleDay < endDay
            }
    }

    @discardableResult
    static func save(
        entries: [LabImportEntry],
        sampledAt: Date,
        regimenVersionID: UUID?,
        in modelContext: ModelContext,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> Int {
        let completedEntries = entries.filter(\.isComplete)
        let existingRecords = try modelContext.fetch(FetchDescriptor<LabRecord>())

        for entry in completedEntries {
            guard let numericValue = entry.numericValue else { continue }
            if let existingRecord = existingRecords.first(where: {
                $0.itemCode.caseInsensitiveCompare(entry.itemCode) == .orderedSame
                    && calendar.isDate($0.sampledAt, inSameDayAs: sampledAt)
            }) {
                existingRecord.itemName = entry.itemName
                existingRecord.itemCode = entry.itemCode
                existingRecord.rawValue = entry.cleanRawValue
                existingRecord.numericValue = numericValue
                existingRecord.unit = entry.cleanUnit
                existingRecord.sampledAt = sampledAt
                existingRecord.regimenVersionID = regimenVersionID
            } else {
                modelContext.insert(
                    LabRecord(
                        itemName: entry.itemName,
                        itemCode: entry.itemCode,
                        rawValue: entry.cleanRawValue,
                        numericValue: numericValue,
                        unit: entry.cleanUnit,
                        sampledAt: sampledAt,
                        regimenVersionID: regimenVersionID
                    )
                )
            }
        }

        try modelContext.save()
        return completedEntries.count
    }
}
