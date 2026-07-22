import Foundation
import SwiftData

@Model
final class HRTProfile {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var activePeriodStartDate: Date
    var createdAt: Date

    init(
        id: UUID = UUID(),
        startDate: Date,
        activePeriodStartDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startDate = startDate
        self.activePeriodStartDate = activePeriodStartDate ?? startDate
        self.createdAt = createdAt
    }
}

@Model
final class CountdownRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var gentleTitle: String?
    var targetDate: Date
    var createdAt: Date
    var archivedAt: Date?
    var continuesCountingUp: Bool

    init(
        id: UUID = UUID(),
        title: String,
        gentleTitle: String? = nil,
        targetDate: Date,
        createdAt: Date = Date(),
        archivedAt: Date? = nil,
        continuesCountingUp: Bool = false
    ) {
        self.id = id
        self.title = title
        self.gentleTitle = gentleTitle
        self.targetDate = targetDate
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.continuesCountingUp = continuesCountingUp
    }
}

enum JourneyEntryKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case change
    case feeling
    case question
    case moment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .change: "变化"
        case .feeling: "感受"
        case .question: "要问"
        case .moment: "记住"
        }
    }
}

@Model
final class RegimenVersion {
    @Attribute(.unique) var id: UUID
    var code: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var note: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        code: String,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
        self.createdAt = createdAt
    }
}

@Model
final class JourneyEntry {
    @Attribute(.unique) var id: UUID
    var text: String
    var kindRawValue: String
    var occurredAt: Date
    var createdAt: Date
    var regimenVersionID: UUID?

    var kind: JourneyEntryKind {
        get { JourneyEntryKind(rawValue: kindRawValue) ?? .moment }
        set { kindRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        text: String,
        kind: JourneyEntryKind,
        occurredAt: Date = Date(),
        createdAt: Date = Date(),
        regimenVersionID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.kindRawValue = kind.rawValue
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.regimenVersionID = regimenVersionID
    }
}

@Model
final class LabRecord {
    @Attribute(.unique) var id: UUID
    var itemName: String
    var itemCode: String
    var rawValue: String
    var numericValue: Double
    var unit: String
    var sampledAt: Date
    var referenceRangeOriginal: String?
    var contextNote: String
    var regimenVersionID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        itemName: String,
        itemCode: String,
        rawValue: String,
        numericValue: Double,
        unit: String,
        sampledAt: Date,
        referenceRangeOriginal: String? = nil,
        contextNote: String = "",
        regimenVersionID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.itemName = itemName
        self.itemCode = itemCode
        self.rawValue = rawValue
        self.numericValue = numericValue
        self.unit = unit
        self.sampledAt = sampledAt
        self.referenceRangeOriginal = referenceRangeOriginal
        self.contextNote = contextNote
        self.regimenVersionID = regimenVersionID
        self.createdAt = createdAt
    }
}
