import Foundation
import SwiftData

@Model
final class DatasetMetadata {
    static let fixedKey = "primary-dataset"

    @Attribute(.unique) var singletonKey: String
    var datasetID: UUID
    var nextLocalRevision: Int64
    var digestVersion: Int
    var createdAt: Date
    var lastCommittedAt: Date?

    init(
        singletonKey: String = DatasetMetadata.fixedKey,
        datasetID: UUID = UUID(),
        nextLocalRevision: Int64 = 1,
        digestVersion: Int = RecordDigestV1.version,
        createdAt: Date = Date(),
        lastCommittedAt: Date? = nil
    ) {
        self.singletonKey = singletonKey
        self.datasetID = datasetID
        self.nextLocalRevision = nextLocalRevision
        self.digestVersion = digestVersion
        self.createdAt = createdAt
        self.lastCommittedAt = lastCommittedAt
    }
}

enum MigrationBackfillPhase: String, Codable, Sendable {
    case hrtProfiles
    case countdowns
    case regimens
    case journeyEntries
    case labRecords
    case issues
    case complete
}

@Model
final class MigrationBackfillState {
    static let fixedKey = "legacy-v1-to-v2-bridge"

    @Attribute(.unique) var taskKey: String
    var phaseRawValue: String
    var processedCountInPhase: Int
    var updatedAt: Date
    var completedAt: Date?

    var phase: MigrationBackfillPhase {
        get { MigrationBackfillPhase(rawValue: phaseRawValue) ?? .hrtProfiles }
        set { phaseRawValue = newValue.rawValue }
    }

    init(
        taskKey: String = MigrationBackfillState.fixedKey,
        phase: MigrationBackfillPhase = .hrtProfiles,
        processedCountInPhase: Int = 0,
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.taskKey = taskKey
        self.phaseRawValue = phase.rawValue
        self.processedCountInPhase = processedCountInPhase
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

@Model
final class RecordRevision {
    @Attribute(.unique) var recordKey: String
    var recordType: String
    var recordID: UUID
    var datasetID: UUID
    var localRevision: Int64
    var digestVersion: Int
    var digestHex: String
    var committedAt: Date

    init(
        recordKey: String,
        recordType: String,
        recordID: UUID,
        datasetID: UUID,
        localRevision: Int64,
        digestVersion: Int,
        digestHex: String,
        committedAt: Date
    ) {
        self.recordKey = recordKey
        self.recordType = recordType
        self.recordID = recordID
        self.datasetID = datasetID
        self.localRevision = localRevision
        self.digestVersion = digestVersion
        self.digestHex = digestHex
        self.committedAt = committedAt
    }
}

enum MigrationIssueKind: String, Codable, CaseIterable, Sendable {
    case duplicateProfile
    case overlappingRegimen
    case orphanedRegimenReference
    case implausibleTimestamp
    case overlappingCanonicalRegimen
    case missingCanonicalRegimenAssociation
    case ambiguousCanonicalRegimenAssociation
}

@Model
final class MigrationIssue {
    @Attribute(.unique) var issueKey: String
    var kindRawValue: String
    var recordType: String
    var recordID: UUID?
    var detectedAt: Date

    var kind: MigrationIssueKind {
        get { MigrationIssueKind(rawValue: kindRawValue) ?? .implausibleTimestamp }
        set { kindRawValue = newValue.rawValue }
    }

    init(
        issueKey: String,
        kind: MigrationIssueKind,
        recordType: String,
        recordID: UUID?,
        detectedAt: Date = Date()
    ) {
        self.issueKey = issueKey
        self.kindRawValue = kind.rawValue
        self.recordType = recordType
        self.recordID = recordID
        self.detectedAt = detectedAt
    }
}
