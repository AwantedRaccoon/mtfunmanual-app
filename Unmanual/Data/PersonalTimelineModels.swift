import Foundation
import SwiftData

enum LabItemDefinitionKind: String, Codable, Sendable {
    case custom
    case bundled
}

@Model
final class LabItemDefinitionRecord {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var bundledStableID: String?
    var displayName: String
    var code: String
    var isArchived: Bool
    var createdAt: Date

    var kind: LabItemDefinitionKind {
        get { LabItemDefinitionKind(rawValue: kindRawValue) ?? .custom }
        set { kindRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        kind: LabItemDefinitionKind = .custom,
        bundledStableID: String? = nil,
        displayName: String,
        code: String,
        isArchived: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.bundledStableID = bundledStableID
        self.displayName = displayName
        self.code = code
        self.isArchived = isArchived
        self.createdAt = createdAt
    }
}

@Model
final class LabSampleRecord {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var specimenOriginal: String
    var contextNote: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        operationID: UUID,
        specimenOriginal: String = "",
        contextNote: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.operationID = operationID
        self.specimenOriginal = specimenOriginal
        self.contextNote = contextNote
        self.createdAt = createdAt
    }
}

@Model
final class LabResultRecord {
    @Attribute(.unique) var id: UUID
    var sampleID: UUID
    var sortOrder: Int
    var itemDefinitionID: UUID
    var itemNameSnapshot: String
    var itemCodeSnapshot: String
    var rawValueOriginal: String
    var comparatorRawValue: String?
    var canonicalDecimalString: String
    var unitOriginal: String
    var referenceRangeOriginal: String?
    var assayOrVariantOriginal: String?
    var operationID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sampleID: UUID,
        sortOrder: Int,
        itemDefinitionID: UUID,
        itemNameSnapshot: String,
        itemCodeSnapshot: String,
        rawValueOriginal: String,
        comparator: LabValueComparator?,
        canonicalDecimalString: String,
        unitOriginal: String,
        referenceRangeOriginal: String? = nil,
        assayOrVariantOriginal: String? = nil,
        operationID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sampleID = sampleID
        self.sortOrder = sortOrder
        self.itemDefinitionID = itemDefinitionID
        self.itemNameSnapshot = itemNameSnapshot
        self.itemCodeSnapshot = itemCodeSnapshot
        self.rawValueOriginal = rawValueOriginal
        self.comparatorRawValue = comparator?.rawValue
        self.canonicalDecimalString = canonicalDecimalString
        self.unitOriginal = unitOriginal
        self.referenceRangeOriginal = referenceRangeOriginal
        self.assayOrVariantOriginal = assayOrVariantOriginal
        self.operationID = operationID
        self.createdAt = createdAt
    }

    var comparator: LabValueComparator? {
        comparatorRawValue.flatMap(LabValueComparator.init(rawValue:))
    }
}

@Model
final class StatusMetricDefinitionRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var isArchived: Bool
    var operationID: UUID
    var archiveOperationID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        isArchived: Bool = false,
        operationID: UUID,
        archiveOperationID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.isArchived = isArchived
        self.operationID = operationID
        self.archiveOperationID = archiveOperationID
        self.createdAt = createdAt
    }
}

@Model
final class StatusObservationRecord {
    @Attribute(.unique) var id: UUID
    var metricDefinitionID: UUID
    var metricNameSnapshot: String
    var ordinalLevel: Int
    var note: String
    var operationID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        metricDefinitionID: UUID,
        metricNameSnapshot: String,
        ordinalLevel: Int,
        note: String = "",
        operationID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.metricDefinitionID = metricDefinitionID
        self.metricNameSnapshot = metricNameSnapshot
        self.ordinalLevel = ordinalLevel
        self.note = note
        self.operationID = operationID
        self.createdAt = createdAt
    }
}

enum AttachmentOwnerType: String, Codable, CaseIterable, Sendable {
    case labSample = "LabSampleRecord"
    case statusObservation = "StatusObservationRecord"
    case journeyEntry = "JourneyEntry"
}

@Model
final class AttachmentRecord {
    @Attribute(.unique) var id: UUID
    var ownerTypeRawValue: String
    var ownerID: UUID
    var relativePath: String
    var originalFilename: String
    var typeIdentifier: String
    var byteCount: Int64
    var sha256Hex: String
    var operationID: UUID
    var deleteOperationID: UUID?
    var createdAt: Date
    var deletedAt: Date?

    var ownerType: AttachmentOwnerType? {
        AttachmentOwnerType(rawValue: ownerTypeRawValue)
    }

    init(
        id: UUID = UUID(),
        ownerType: AttachmentOwnerType,
        ownerID: UUID,
        relativePath: String,
        originalFilename: String,
        typeIdentifier: String,
        byteCount: Int64,
        sha256Hex: String,
        operationID: UUID,
        deleteOperationID: UUID? = nil,
        createdAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerTypeRawValue = ownerType.rawValue
        self.ownerID = ownerID
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
        self.operationID = operationID
        self.deleteOperationID = deleteOperationID
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

@Model
final class PersonalTimelineBackfillState {
    static let fixedKey = "v4-to-v5-personal-timeline"

    @Attribute(.unique) var taskKey: String
    var completedAt: Date?
    var updatedAt: Date

    init(
        taskKey: String = PersonalTimelineBackfillState.fixedKey,
        completedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.taskKey = taskKey
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}
