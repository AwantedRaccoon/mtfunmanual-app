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
        among regimens: [RegimenVersionSnapshot],
        calendar: Calendar = .autoupdatingCurrent
    ) -> RegimenVersionSnapshot? {
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

}
