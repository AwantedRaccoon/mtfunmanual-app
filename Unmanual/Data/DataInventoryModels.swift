import Foundation

enum DataInventoryCategoryKind: String, Sendable {
    case database
    case fileTree
    case generation
    case notification
    case control
}

enum DataInventoryCategoryStatus: String, Sendable {
    case complete
    case failed
}

enum DataInventoryCompleteness: String, Sendable {
    case complete
    case incomplete
}

enum DataInventoryBoundaryState: String, Sendable {
    case notEnumerableByApp
}

struct DataInventoryCategory: Equatable, Sendable {
    let key: String
    let kind: DataInventoryCategoryKind
    let status: DataInventoryCategoryStatus
    let itemCount: Int64?
    let byteCount: Int64?
    let retainedSensitiveCount: Int64?
    let identityDigest: String?
}

struct DataInventoryBoundary: Equatable, Sendable {
    let key: String
    let state: DataInventoryBoundaryState
}

struct DataInventoryManifest: Equatable, Sendable {
    let generationID: UUID
    let datasetID: UUID
    let nextLocalRevision: Int64
    let capturedAt: Date
    let completeness: DataInventoryCompleteness
    let categories: [DataInventoryCategory]
    let unmanagedBoundaries: [DataInventoryBoundary]
    let stateDigest: String
    let manifestDigest: String

    var destructiveActionsEnabled: Bool {
        completeness == .complete
            && categories.allSatisfy { $0.status == .complete }
    }
}

struct DataInventoryCategorySpecification: Equatable, Sendable {
    let key: String
    let kind: DataInventoryCategoryKind
}

enum DataInventoryTaxonomy {
    static let maximumRowsPerModel = 1_000_000

    static let databaseModelsByCategory: [String: [String]] = [
        "db.attachments": [
            "AttachmentRecord"
        ],
        "db.audit": [
            "RecordRevision",
            "OperationReceiptRecord",
            "OperationReceiptLedgerRecord",
            "HistoricalTimeRecord",
            "ParentRecordLifecycleHeadRecord",
            "ParentRecordMutationEventRecord",
            "ParentRecordDeletionTombstoneRecord",
            "DataControlDeletionTombstoneRecord"
        ],
        "db.countdown": [
            "CountdownRecord",
            "CountdownStateRecord",
            "CountdownLifecycleEventRecord",
            "CountdownReminderRuleRecord",
            "CountdownCommandAuditRecord",
            "CountdownV6AuditCheckpointRecord"
        ],
        "db.execution": [
            "AdministrationEventRecord",
            "ReminderOverrideRecord",
            "ReminderPreferenceRecord"
        ],
        "db.hrt": [
            "HRTProfile",
            "HrtJourneyProfileRecord",
            "HrtPeriodRecord",
            "HrtJourneyLifecycleEventRecord"
        ],
        "db.journey": [
            "JourneyEntry"
        ],
        "db.labs": [
            "LabRecord",
            "LabItemDefinitionRecord",
            "LabSampleRecord",
            "LabResultRecord",
            "LabSampleCorrectionSnapshotRecord",
            "LabResultCorrectionSnapshotRecord"
        ],
        "db.preferences": [
            "UserPreferencesRecord",
            "OnboardingProgressRecord",
            "PrivacyControlRecord"
        ],
        "db.regimen": [
            "RegimenVersion",
            "RegimenPlanVersionRecord",
            "RegimenItemRecord",
            "ScheduleRuleRecord"
        ],
        "db.status": [
            "StatusMetricDefinitionRecord",
            "StatusObservationRecord",
            "StatusObservationCorrectionSnapshotRecord"
        ],
        "db.system": [
            "DatasetMetadata",
            "MigrationBackfillState",
            "MigrationIssue",
            "CoreTimeRegimenBackfillState",
            "TodayExecutionBackfillState",
            "PersonalTimelineBackfillState",
            "CountdownLifecycleBackfillState",
            "CountdownIntegrityBackfillState",
            "OnboardingBackfillState",
            "HrtJourneyLifecycleBackfillState",
            "ParentRecordLifecycleBackfillState",
            "PrivacyControlBackfillState",
            "DataControlBackfillState",
            "NotificationCoverageRecord",
            "CountdownNotificationCoverageRecord"
        ]
    ]

    static let categorySpecifications: [DataInventoryCategorySpecification] = [
        .init(key: "db.attachments", kind: .database),
        .init(key: "db.audit", kind: .database),
        .init(key: "db.countdown", kind: .database),
        .init(key: "db.execution", kind: .database),
        .init(key: "db.hrt", kind: .database),
        .init(key: "db.journey", kind: .database),
        .init(key: "db.labs", kind: .database),
        .init(key: "db.preferences", kind: .database),
        .init(key: "db.regimen", kind: .database),
        .init(key: "db.status", kind: .database),
        .init(key: "db.system", kind: .database),
        .init(key: "files.attachments.active", kind: .fileTree),
        .init(key: "files.attachments.journal", kind: .fileTree),
        .init(key: "files.attachments.staging", kind: .fileTree),
        .init(key: "files.attachments.trash", kind: .fileTree),
        .init(key: "notification.countdown.delivered", kind: .notification),
        .init(key: "notification.countdown.pending", kind: .notification),
        .init(key: "notification.execution.delivered", kind: .notification),
        .init(key: "notification.execution.pending", kind: .notification),
        .init(key: "storage.control", kind: .control),
        .init(key: "storage.generation.active", kind: .generation),
        .init(key: "storage.generation.inactive-proven", kind: .generation),
        .init(key: "storage.generation.invalid", kind: .generation),
        .init(key: "storage.generation.unproven", kind: .generation),
        .init(key: "storage.legacy", kind: .control)
    ]

    static let unmanagedBoundaries: [DataInventoryBoundary] = [
        .init(key: "exports", state: .notEnumerableByApp),
        .init(key: "filesSource", state: .notEnumerableByApp),
        .init(key: "photosSource", state: .notEnumerableByApp),
        .init(key: "screenshots", state: .notEnumerableByApp),
        .init(key: "shares", state: .notEnumerableByApp),
        .init(key: "systemBackup", state: .notEnumerableByApp)
    ]

    static let allowedUnrevisionedControlModels: Set<String> = [
        "DatasetMetadata",
        "MigrationBackfillState",
        "MigrationIssue",
        "CoreTimeRegimenBackfillState",
        "TodayExecutionBackfillState",
        "NotificationCoverageRecord",
        "PersonalTimelineBackfillState",
        "CountdownNotificationCoverageRecord",
        "CountdownLifecycleBackfillState"
    ]

    static let allDatabaseModelNames: [String] =
        databaseModelsByCategory.values.flatMap { $0 }

    static var hasExactModelPartition: Bool {
        allDatabaseModelNames.count == 54
            && Set(allDatabaseModelNames).count == 54
            && Set(databaseModelsByCategory.keys)
                == Set(
                    categorySpecifications
                        .filter { $0.kind == .database }
                        .map(\.key)
                )
    }
}

enum DataInventoryDatabaseEntry: Equatable, Sendable {
    case fact(
        modelType: String,
        recordType: String,
        recordID: UUID,
        datasetID: UUID,
        recordKey: String,
        localRevision: Int64,
        digestVersion: Int64,
        digestHex: String
    )
    case revision(
        recordKey: String,
        recordType: String,
        recordID: UUID,
        datasetID: UUID,
        localRevision: Int64,
        digestVersion: Int64,
        committedAt: Date,
        digestHex: String
    )
    case control(
        modelType: String,
        stableIdentity: String
    )
}

struct DataInventoryDatabaseSnapshot: Equatable, Sendable {
    let modelRowCounts: [String: Int64]
    let entries: [DataInventoryDatabaseEntry]
}

struct DataInventoryRegularFileSnapshot: Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let sha256Hex: String
}

enum DataInventoryGenerationClassification: String, Sendable {
    case active
    case inactiveProven
    case inactiveUnproven
    case invalid

    var categoryKey: String {
        switch self {
        case .active:
            "storage.generation.active"
        case .inactiveProven:
            "storage.generation.inactive-proven"
        case .inactiveUnproven:
            "storage.generation.unproven"
        case .invalid:
            "storage.generation.invalid"
        }
    }
}

enum DataInventoryGenerationJournalRole: String, CaseIterable, Sendable {
    case journalSource
    case journalTarget
    case knownRollbackSource
}

enum DataInventoryGenerationTreeScope: String, Sendable {
    case activeLogicalOverlay = "active-logical-overlay"
    case closedFullTree = "closed-full-tree"

    static let activeExcludedPaths = [
        "Files/**",
        "Store/user.sqlite",
        "Store/user.sqlite-shm",
        "Store/user.sqlite-wal"
    ]

    var excludedPaths: [String] {
        switch self {
        case .activeLogicalOverlay:
            Self.activeExcludedPaths
        case .closedFullTree:
            []
        }
    }
}

struct DataInventoryGenerationSnapshot: Equatable, Sendable {
    let entryName: String
    let generationID: UUID?
    let primaryClassification: DataInventoryGenerationClassification
    let journalRoles: [DataInventoryGenerationJournalRole]
    let relativePath: String
    let scope: DataInventoryGenerationTreeScope
    let files: [DataInventoryRegularFileSnapshot]
}

enum DataInventoryNotificationNamespace: String, Sendable {
    case execution
    case countdown

    var identifierPrefix: String {
        switch self {
        case .execution:
            "unmanual.exec.v1."
        case .countdown:
            "unmanual.countdown.v1."
        }
    }
}

enum DataInventoryNotificationDeliveryState: String, Sendable {
    case pending
    case delivered
}

struct DataInventoryNotificationSnapshot: Equatable, Sendable {
    let namespace: DataInventoryNotificationNamespace
    let deliveryState: DataInventoryNotificationDeliveryState
    let identifier: String

    var categoryKey: String {
        "notification.\(namespace.rawValue).\(deliveryState.rawValue)"
    }
}

enum DataInventoryCategoryPayload: Equatable, Sendable {
    case database(DataInventoryDatabaseSnapshot)
    case regularFiles([DataInventoryRegularFileSnapshot])
    case generations([DataInventoryGenerationSnapshot])
    case notifications([DataInventoryNotificationSnapshot])
    case failed
}

struct DataInventoryCategorySnapshot: Equatable, Sendable {
    let key: String
    let kind: DataInventoryCategoryKind
    let payload: DataInventoryCategoryPayload

    static func failed(
        key: String,
        kind: DataInventoryCategoryKind
    ) -> DataInventoryCategorySnapshot {
        DataInventoryCategorySnapshot(
            key: key,
            kind: kind,
            payload: .failed
        )
    }
}

protocol DataInventorySnapshotProvider: Sendable {
    func categorySnapshots() async throws -> [DataInventoryCategorySnapshot]
}

struct InjectedDataInventorySnapshotProvider: DataInventorySnapshotProvider {
    let load: @Sendable () async throws -> [DataInventoryCategorySnapshot]

    func categorySnapshots() async throws -> [DataInventoryCategorySnapshot] {
        try await load()
    }
}
