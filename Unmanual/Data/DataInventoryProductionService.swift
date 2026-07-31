import Foundation
import SwiftData
import SwiftUI
import UserNotifications

struct DataInventoryDatabaseCapture: Sendable {
    let datasetID: UUID
    let nextLocalRevision: Int64
    let factCount: Int
    let revisionCount: Int
    let categorySnapshots: [DataInventoryCategorySnapshot]
    let attachments: [DataInventoryAttachmentObservation]
    let portableFacts: [DataInventoryPortableFact]
    let portableControls: [DataInventoryPortableControl]
}

struct DataInventoryPortableFact: Equatable, Sendable {
    let modelType: String
    let recordType: String
    let recordID: UUID
    let digestHex: String
    let fields: [RecordDigestV1.Field]
}

struct DataInventoryPortableControl: Equatable, Sendable {
    let modelType: String
    let stableIdentity: String
    let fields: [RecordDigestV1.Field]
}

struct DataInventoryAttachmentObservation: Equatable, Sendable {
    let operationID: UUID
    let attachment: AttachmentSnapshot
    let deletedAt: Date?
    let deleteOperationID: UUID?
}

private struct DataInventoryRawFact {
    let modelType: String
    let recordType: String
    let recordID: UUID
    let digestHex: String
    let fields: [RecordDigestV1.Field]

    var recordKey: String {
        recordType + ":" + recordID.uuidString.lowercased()
    }
}

private struct DataInventoryCollectedModel {
    let modelType: String
    let rowCount: Int64
    let facts: [DataInventoryRawFact]
    let revisions: [DataInventoryDatabaseEntry]
    let controls: [DataInventoryDatabaseEntry]
    let portableControls: [DataInventoryPortableControl]

    init(
        modelType: String,
        rowCount: Int64,
        facts: [DataInventoryRawFact],
        revisions: [DataInventoryDatabaseEntry],
        controls: [DataInventoryDatabaseEntry],
        portableControls: [DataInventoryPortableControl] = []
    ) {
        self.modelType = modelType
        self.rowCount = rowCount
        self.facts = facts
        self.revisions = revisions
        self.controls = controls
        self.portableControls = portableControls
    }
}

enum DataInventoryBoundedFetchContract {
    static func validate(
        preflightCount: Int,
        fetchedCount: Int
    ) throws {
        guard preflightCount >= 0,
              preflightCount
                <= DataInventoryTaxonomy.maximumRowsPerModel,
              fetchedCount == preflightCount,
              fetchedCount
                <= DataInventoryTaxonomy.maximumRowsPerModel else {
            throw AppDataFailure.corruptionSuspected
        }
    }
}

@ModelActor
actor DataInventoryDatabaseCaptureActor {
    func capture(
        layout: AppDataStoreLayout,
        schemaVersion: String =
            PortableDataSchemaContract.v13.schemaVersion
    ) throws -> DataInventoryDatabaseCapture {
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .production
        )
        let foundation: (
            datasetID: UUID,
            nextLocalRevision: Int64,
            factCount: Int,
            revisionCount: Int
        )
        switch schemaVersion {
        case PortableDataSchemaContract.v12.schemaVersion:
            foundation = try bootstrapper
                .validateV12DataInventoryFoundation(in: modelContext)
        case PortableDataSchemaContract.v13.schemaVersion:
            foundation = try bootstrapper
                .validateV13DataInventoryFoundation(in: modelContext)
        default:
            throw AppDataFailure.corruptionSuspected
        }
        let contract = try PortableDataSchemaContract.resolve(
            schemaVersion: schemaVersion
        )
        let collected = try collectAllModels(
            includesContentFavorite:
                schemaVersion
                    == PortableDataSchemaContract.v13.schemaVersion
        )
        let models = collected.models
        guard models.count == contract.modelNames.count,
              Set(models.map(\.modelType))
                == Set(contract.modelNames) else {
            throw AppDataFailure.corruptionSuspected
        }

        let revisionRows = models
            .first { $0.modelType == "RecordRevision" }?
            .revisions ?? []
        let revisionsByKey = try revisionMap(
            revisionRows,
            datasetID: foundation.datasetID
        )
        let rawFacts = models.flatMap(\.facts)
        guard rawFacts.count == foundation.factCount,
              revisionRows.count == foundation.revisionCount,
              rawFacts.count == revisionsByKey.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let factEntries = try rawFacts.map { fact in
            guard let revision = revisionsByKey[fact.recordKey] else {
                throw AppDataFailure.corruptionSuspected
            }
            guard case let .revision(
                recordKey,
                recordType,
                recordID,
                datasetID,
                localRevision,
                digestVersion,
                _,
                digestHex
            ) = revision,
            recordKey == fact.recordKey,
            recordType == fact.recordType,
            recordID == fact.recordID,
            datasetID == foundation.datasetID,
            digestHex == fact.digestHex else {
                throw AppDataFailure.corruptionSuspected
            }
            return DataInventoryDatabaseEntry.fact(
                modelType: fact.modelType,
                recordType: fact.recordType,
                recordID: fact.recordID,
                datasetID: datasetID,
                recordKey: fact.recordKey,
                localRevision: localRevision,
                digestVersion: digestVersion,
                digestHex: fact.digestHex
            )
        }

        var entriesByModel: [String: [DataInventoryDatabaseEntry]] = [:]
        for entry in factEntries {
            guard case let .fact(modelType, _, _, _, _, _, _, _) = entry else {
                throw AppDataFailure.corruptionSuspected
            }
            entriesByModel[modelType, default: []].append(entry)
        }
        for model in models {
            entriesByModel[model.modelType, default: []]
                .append(contentsOf: model.revisions)
            entriesByModel[model.modelType, default: []]
                .append(contentsOf: model.controls)
        }

        let contractModelNames = Set(contract.modelNames)
        let snapshots = try DataInventoryTaxonomy
            .databaseModelsByCategory
            .compactMap { categoryKey, currentModels
                -> DataInventoryCategorySnapshot? in
                let expectedModels = currentModels.filter {
                    contractModelNames.contains($0)
                }
                guard !expectedModels.isEmpty else {
                    return nil
                }
                let selected = models.filter {
                    expectedModels.contains($0.modelType)
                }
                guard selected.count == expectedModels.count else {
                    throw AppDataFailure.corruptionSuspected
                }
                let counts = Dictionary(
                    uniqueKeysWithValues: selected.map {
                        ($0.modelType, $0.rowCount)
                    }
                )
                let entries = expectedModels.flatMap {
                    entriesByModel[$0] ?? []
                }
                return DataInventoryCategorySnapshot(
                    key: categoryKey,
                    kind: .database,
                    payload: .database(
                        DataInventoryDatabaseSnapshot(
                            modelRowCounts: counts,
                            entries: entries
                        )
                    )
                )
            }

        guard collected.metadataDatasetID == foundation.datasetID,
              collected.metadataNextLocalRevision
                == foundation.nextLocalRevision else {
            throw AppDataFailure.corruptionSuspected
        }
        return DataInventoryDatabaseCapture(
            datasetID: foundation.datasetID,
            nextLocalRevision: foundation.nextLocalRevision,
            factCount: foundation.factCount,
            revisionCount: foundation.revisionCount,
            categorySnapshots: snapshots,
            attachments: collected.attachments,
            portableFacts: rawFacts.map {
                DataInventoryPortableFact(
                    modelType: $0.modelType,
                    recordType: $0.recordType,
                    recordID: $0.recordID,
                    digestHex: $0.digestHex,
                    fields: $0.fields
                )
            },
            portableControls: models.flatMap(
                \.portableControls
            )
        )
    }

    private func collectAllModels(
        includesContentFavorite: Bool
    ) throws
        -> (
            models: [DataInventoryCollectedModel],
            attachments: [DataInventoryAttachmentObservation],
            metadataDatasetID: UUID,
            metadataNextLocalRevision: Int64
        ) {
        var result: [DataInventoryCollectedModel] = []
        var attachmentObservations: [DataInventoryAttachmentObservation] = []
        var metadataDatasetID: UUID?
        var metadataNextLocalRevision: Int64?

        func fact<T: PersistentModel>(
            _ type: T.Type,
            modelType: String,
            evidence: (T) throws
                -> (String, UUID, [RecordDigestV1.Field])
        ) throws {
            let rows = try boundedRows(type)
            result.append(
                DataInventoryCollectedModel(
                    modelType: modelType,
                    rowCount: Int64(rows.count),
                    facts: try rows.map { row in
                        let value = try evidence(row)
                        return DataInventoryRawFact(
                            modelType: modelType,
                            recordType: value.0,
                            recordID: value.1,
                            digestHex: try RecordDigestV1.sha256Hex(
                                recordType: value.0,
                                recordID: value.1,
                                fields: value.2
                            ),
                            fields: value.2
                        )
                    },
                    revisions: [],
                    controls: []
                )
            )
        }

        func digestFact<T: PersistentModel>(
            _ type: T.Type,
            modelType: String,
            identity: (T) -> UUID,
            fields: (T) throws -> [RecordDigestV1.Field]
        ) throws {
            try fact(type, modelType: modelType) { value in
                let id = identity(value)
                return (
                    modelType,
                    id,
                    try fields(value)
                )
            }
        }

        func control<T: PersistentModel>(
            _ type: T.Type,
            modelType: String,
            identity: (T) -> String,
            fields: (T) throws
                -> [RecordDigestV1.Field]
        ) throws {
            let rows = try boundedRows(type)
            let portable = try rows.map {
                DataInventoryPortableControl(
                    modelType: modelType,
                    stableIdentity: identity($0),
                    fields: try fields($0)
                )
            }
            result.append(
                DataInventoryCollectedModel(
                    modelType: modelType,
                    rowCount: Int64(rows.count),
                    facts: [],
                    revisions: [],
                    controls: rows.map {
                        .control(
                            modelType: modelType,
                            stableIdentity: identity($0)
                        )
                    },
                    portableControls: portable
                )
            )
        }

        try fact(HRTProfile.self, modelType: "HRTProfile") {
            ("HRTProfile", $0.id, try FactDigestV1.profile($0))
        }
        try fact(CountdownRecord.self, modelType: "CountdownRecord") {
            ("CountdownRecord", $0.id, try FactDigestV1.countdown($0))
        }
        try fact(RegimenVersion.self, modelType: "RegimenVersion") {
            ("RegimenVersion", $0.id, try FactDigestV1.regimen($0))
        }
        try fact(JourneyEntry.self, modelType: "JourneyEntry") {
            ("JourneyEntry", $0.id, try FactDigestV1.journey($0))
        }
        try fact(LabRecord.self, modelType: "LabRecord") {
            ("LabRecord", $0.id, try FactDigestV1.lab($0))
        }

        let metadataRows = try boundedRows(DatasetMetadata.self)
        result.append(
            DataInventoryCollectedModel(
                modelType: "DatasetMetadata",
                rowCount: Int64(metadataRows.count),
                facts: [],
                revisions: [],
                controls: metadataRows.map {
                    .control(
                        modelType: "DatasetMetadata",
                        stableIdentity: $0.singletonKey
                    )
                },
                portableControls: try metadataRows.map {
                    DataInventoryPortableControl(
                        modelType: "DatasetMetadata",
                        stableIdentity: $0.singletonKey,
                        fields: [
                            .init(
                                "createdAt",
                                try timestamp($0.createdAt)
                            ),
                            .init(
                                "datasetID",
                                .uuid($0.datasetID)
                            ),
                            .init(
                                "digestVersion",
                                .integer(
                                    Int64($0.digestVersion)
                                )
                            ),
                            .init(
                                "lastCommittedAt",
                                try optionalTimestamp(
                                    $0.lastCommittedAt
                                )
                            ),
                            .init(
                                "nextLocalRevision",
                                .integer(
                                    $0.nextLocalRevision
                                )
                            ),
                            .init(
                                "singletonKey",
                                .string($0.singletonKey)
                            )
                        ]
                    )
                }
            )
        )
        if metadataRows.count == 1 {
            metadataDatasetID = metadataRows[0].datasetID
            metadataNextLocalRevision =
                metadataRows[0].nextLocalRevision
        }
        try control(
            MigrationBackfillState.self,
            modelType: "MigrationBackfillState",
            identity: \.taskKey
        ) {
            [
                .init(
                    "completedAt",
                    try optionalTimestamp($0.completedAt)
                ),
                .init(
                    "phaseRawValue",
                    .string($0.phaseRawValue)
                ),
                .init(
                    "processedCountInPhase",
                    .integer(
                        Int64($0.processedCountInPhase)
                    )
                ),
                .init("taskKey", .string($0.taskKey)),
                .init(
                    "updatedAt",
                    try timestamp($0.updatedAt)
                )
            ]
        }
        let revisions = try boundedRows(RecordRevision.self)
        result.append(
            DataInventoryCollectedModel(
                modelType: "RecordRevision",
                rowCount: Int64(revisions.count),
                facts: [],
                revisions: revisions.map {
                    .revision(
                        recordKey: $0.recordKey,
                        recordType: $0.recordType,
                        recordID: $0.recordID,
                        datasetID: $0.datasetID,
                        localRevision: $0.localRevision,
                        digestVersion: Int64($0.digestVersion),
                        committedAt: $0.committedAt,
                        digestHex: $0.digestHex
                    )
                },
                controls: []
            )
        )
        try control(
            MigrationIssue.self,
            modelType: "MigrationIssue",
            identity: \.issueKey
        ) {
            [
                .init(
                    "detectedAt",
                    try timestamp($0.detectedAt)
                ),
                .init(
                    "issueKey",
                    .string($0.issueKey)
                ),
                .init(
                    "kindRawValue",
                    .string($0.kindRawValue)
                ),
                .init(
                    "recordID",
                    optionalUUID($0.recordID)
                ),
                .init(
                    "recordType",
                    .string($0.recordType)
                )
            ]
        }
        try digestFact(
            UserPreferencesRecord.self,
            modelType: "UserPreferencesRecord",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(
                    for: $0.singletonKey
                )
            },
            fields: CoreFactDigestV1.preferences
        )
        try digestFact(
            HrtJourneyProfileRecord.self,
            modelType: "HrtJourneyProfileRecord",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(
                    for: $0.singletonKey
                )
            },
            fields: CoreFactDigestV1.journeyProfile
        )
        try digestFact(
            HrtPeriodRecord.self,
            modelType: "HrtPeriodRecord",
            identity: \.id,
            fields: CoreFactDigestV1.period
        )
        try digestFact(
            RegimenPlanVersionRecord.self,
            modelType: "RegimenPlanVersionRecord",
            identity: \.id,
            fields: CoreFactDigestV1.regimen
        )
        try digestFact(
            RegimenItemRecord.self,
            modelType: "RegimenItemRecord",
            identity: \.id,
            fields: CoreFactDigestV1.item
        )
        try digestFact(
            ScheduleRuleRecord.self,
            modelType: "ScheduleRuleRecord",
            identity: \.id,
            fields: CoreFactDigestV1.schedule
        )
        try digestFact(
            HistoricalTimeRecord.self,
            modelType: "HistoricalTimeRecord",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(for: $0.recordKey)
            },
            fields: CoreFactDigestV1.historicalTime
        )
        try control(
            CoreTimeRegimenBackfillState.self,
            modelType: "CoreTimeRegimenBackfillState",
            identity: \.taskKey
        ) {
            [
                .init(
                    "assumedTimeZoneIdentifier",
                    .string($0.assumedTimeZoneIdentifier)
                ),
                .init(
                    "completedAt",
                    try optionalTimestamp($0.completedAt)
                ),
                .init("taskKey", .string($0.taskKey)),
                .init(
                    "updatedAt",
                    try timestamp($0.updatedAt)
                )
            ]
        }
        try digestFact(
            AdministrationEventRecord.self,
            modelType: "AdministrationEventRecord",
            identity: \.id,
            fields: TodayExecutionDigestV1.administrationEvent
        )
        try digestFact(
            OperationReceiptRecord.self,
            modelType: "OperationReceiptRecord",
            identity: \.operationID,
            fields: TodayExecutionDigestV1.operationReceipt
        )
        try digestFact(
            OperationReceiptLedgerRecord.self,
            modelType: "OperationReceiptLedgerRecord",
            identity: { _ in TodayExecutionDigestV1.receiptLedgerID },
            fields: TodayExecutionDigestV1.operationReceiptLedger
        )
        try digestFact(
            ReminderOverrideRecord.self,
            modelType: "ReminderOverrideRecord",
            identity: \.id,
            fields: TodayExecutionDigestV1.reminderOverride
        )
        try digestFact(
            ReminderPreferenceRecord.self,
            modelType: "ReminderPreferenceRecord",
            identity: \.id,
            fields: TodayExecutionDigestV1.reminderPreference
        )
        try control(
            NotificationCoverageRecord.self,
            modelType: "NotificationCoverageRecord",
            identity: \.coverageKey
        ) {
            [
                .init(
                    "confirmedPendingCount",
                    .integer(
                        Int64($0.confirmedPendingCount)
                    )
                ),
                .init(
                    "coverageKey",
                    .string($0.coverageKey)
                ),
                .init(
                    "desiredCount",
                    .integer(Int64($0.desiredCount))
                ),
                .init(
                    "lastErrorCode",
                    optionalString($0.lastErrorCode)
                ),
                .init(
                    "observedAt",
                    try timestamp($0.observedAt)
                ),
                .init(
                    "scheduledThrough",
                    try optionalTimestamp($0.scheduledThrough)
                ),
                .init(
                    "statusRawValue",
                    .string($0.statusRawValue)
                )
            ]
        }
        try control(
            TodayExecutionBackfillState.self,
            modelType: "TodayExecutionBackfillState",
            identity: \.taskKey
        ) {
            [
                .init(
                    "completedAt",
                    try optionalTimestamp($0.completedAt)
                ),
                .init("taskKey", .string($0.taskKey)),
                .init(
                    "updatedAt",
                    try timestamp($0.updatedAt)
                )
            ]
        }
        try digestFact(
            LabItemDefinitionRecord.self,
            modelType: "LabItemDefinitionRecord",
            identity: \.id,
            fields: PersonalTimelineDigestV1.labItemDefinition
        )
        try digestFact(
            LabSampleRecord.self,
            modelType: "LabSampleRecord",
            identity: \.id,
            fields: PersonalTimelineDigestV1.labSample
        )
        try digestFact(
            LabResultRecord.self,
            modelType: "LabResultRecord",
            identity: \.id,
            fields: PersonalTimelineDigestV1.labResult
        )
        try digestFact(
            StatusMetricDefinitionRecord.self,
            modelType: "StatusMetricDefinitionRecord",
            identity: \.id,
            fields: StatusDigestV1.metric
        )
        try digestFact(
            StatusObservationRecord.self,
            modelType: "StatusObservationRecord",
            identity: \.id,
            fields: StatusDigestV1.observation
        )
        let attachmentRows = try boundedRows(AttachmentRecord.self)
        result.append(
            DataInventoryCollectedModel(
                modelType: "AttachmentRecord",
                rowCount: Int64(attachmentRows.count),
                facts: try attachmentRows.map {
                    let fields = try AttachmentDigestV1.record($0)
                    return DataInventoryRawFact(
                        modelType: "AttachmentRecord",
                        recordType: "AttachmentRecord",
                        recordID: $0.id,
                        digestHex: try RecordDigestV1.sha256Hex(
                            recordType: "AttachmentRecord",
                            recordID: $0.id,
                            fields: fields
                        ),
                        fields: fields
                    )
                },
                revisions: [],
                controls: []
            )
        )
        attachmentObservations = try attachmentRows.map {
            guard let snapshot = AttachmentSnapshot($0) else {
                throw AppDataFailure.corruptionSuspected
            }
            return DataInventoryAttachmentObservation(
                operationID: $0.operationID,
                attachment: snapshot,
                deletedAt: $0.deletedAt,
                deleteOperationID: $0.deleteOperationID
            )
        }
        try control(
            PersonalTimelineBackfillState.self,
            modelType: "PersonalTimelineBackfillState",
            identity: \.taskKey
        ) {
            [
                .init(
                    "completedAt",
                    try optionalTimestamp($0.completedAt)
                ),
                .init("taskKey", .string($0.taskKey)),
                .init(
                    "updatedAt",
                    try timestamp($0.updatedAt)
                )
            ]
        }
        try digestFact(
            CountdownStateRecord.self,
            modelType: "CountdownStateRecord",
            identity: \.id,
            fields: CountdownDigestV1.state
        )
        try digestFact(
            CountdownLifecycleEventRecord.self,
            modelType: "CountdownLifecycleEventRecord",
            identity: \.id,
            fields: CountdownDigestV1.event
        )
        try digestFact(
            CountdownReminderRuleRecord.self,
            modelType: "CountdownReminderRuleRecord",
            identity: \.id,
            fields: CountdownDigestV1.reminder
        )
        try control(
            CountdownNotificationCoverageRecord.self,
            modelType: "CountdownNotificationCoverageRecord",
            identity: \.coverageKey
        ) {
            [
                .init(
                    "confirmedPendingCount",
                    .integer(
                        Int64($0.confirmedPendingCount)
                    )
                ),
                .init(
                    "countdownID",
                    optionalUUID($0.countdownID)
                ),
                .init(
                    "coverageKey",
                    .string($0.coverageKey)
                ),
                .init(
                    "desiredCount",
                    .integer(Int64($0.desiredCount))
                ),
                .init(
                    "lastErrorCode",
                    optionalString($0.lastErrorCode)
                ),
                .init(
                    "observedAt",
                    try timestamp($0.observedAt)
                ),
                .init(
                    "scheduledFireAt",
                    try optionalTimestamp($0.scheduledFireAt)
                ),
                .init(
                    "statusRawValue",
                    .string($0.statusRawValue)
                )
            ]
        }
        try control(
            CountdownLifecycleBackfillState.self,
            modelType: "CountdownLifecycleBackfillState",
            identity: \.taskKey
        ) {
            [
                .init(
                    "assumedTimeZoneIdentifier",
                    .string($0.assumedTimeZoneIdentifier)
                ),
                .init(
                    "completedAt",
                    try optionalTimestamp($0.completedAt)
                ),
                .init("taskKey", .string($0.taskKey)),
                .init(
                    "updatedAt",
                    try timestamp($0.updatedAt)
                )
            ]
        }
        try digestFact(
            CountdownCommandAuditRecord.self,
            modelType: "CountdownCommandAuditRecord",
            identity: \.eventID,
            fields: CountdownIntegrityDigest.revisionFields
        )
        try digestFact(
            CountdownV6AuditCheckpointRecord.self,
            modelType: "CountdownV6AuditCheckpointRecord",
            identity: \.countdownID,
            fields: CountdownIntegrityDigest.checkpointRevisionFields
        )
        try digestFact(
            CountdownIntegrityBackfillState.self,
            modelType: "CountdownIntegrityBackfillState",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(for: $0.taskKey)
            },
            fields: CountdownIntegrityDigest.backfillState
        )
        try digestFact(
            OnboardingProgressRecord.self,
            modelType: "OnboardingProgressRecord",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(
                    for: $0.singletonKey
                )
            },
            fields: OnboardingDigestV1.progress
        )
        try digestFact(
            OnboardingBackfillState.self,
            modelType: "OnboardingBackfillState",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(for: $0.taskKey)
            },
            fields: OnboardingDigestV1.backfillState
        )
        try digestFact(
            HrtJourneyLifecycleEventRecord.self,
            modelType: "HrtJourneyLifecycleEventRecord",
            identity: \.id,
            fields: HrtJourneyLifecycleDigest.event
        )
        try digestFact(
            HrtJourneyLifecycleBackfillState.self,
            modelType: "HrtJourneyLifecycleBackfillState",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(for: $0.taskKey)
            },
            fields: HrtJourneyLifecycleDigest.backfillState
        )
        try digestFact(
            ParentRecordLifecycleHeadRecord.self,
            modelType: "ParentRecordLifecycleHeadRecord",
            identity: {
                ParentRecordLifecycleBackfill.stableHeadID(
                    for: $0.parentKey
                )
            },
            fields: ParentRecordLifecycleDigest.head
        )
        try digestFact(
            ParentRecordMutationEventRecord.self,
            modelType: "ParentRecordMutationEventRecord",
            identity: \.id,
            fields: ParentRecordLifecycleDigest.event
        )
        try digestFact(
            LabSampleCorrectionSnapshotRecord.self,
            modelType: "LabSampleCorrectionSnapshotRecord",
            identity: \.id,
            fields: ParentRecordLifecycleDigest.labCorrection
        )
        try digestFact(
            LabResultCorrectionSnapshotRecord.self,
            modelType: "LabResultCorrectionSnapshotRecord",
            identity: \.id,
            fields: {
                ParentRecordLifecycleDigest.labResultCorrection($0)
            }
        )
        try digestFact(
            StatusObservationCorrectionSnapshotRecord.self,
            modelType: "StatusObservationCorrectionSnapshotRecord",
            identity: \.id,
            fields: ParentRecordLifecycleDigest.statusCorrection
        )
        try digestFact(
            ParentRecordDeletionTombstoneRecord.self,
            modelType: "ParentRecordDeletionTombstoneRecord",
            identity: \.id,
            fields: ParentRecordLifecycleDigest.tombstone
        )
        try digestFact(
            ParentRecordLifecycleBackfillState.self,
            modelType: "ParentRecordLifecycleBackfillState",
            identity: {
                CoreTimeRegimenBackfill.stableUUID(for: $0.taskKey)
            },
            fields: ParentRecordLifecycleDigest.backfillState
        )
        try digestFact(
            PrivacyControlRecord.self,
            modelType: "PrivacyControlRecord",
            identity: { _ in PrivacyControlRecord.stableID },
            fields: PrivacyControlDigestV1.record
        )
        try digestFact(
            PrivacyControlBackfillState.self,
            modelType: "PrivacyControlBackfillState",
            identity: { _ in PrivacyControlBackfillState.stableID },
            fields: PrivacyControlDigestV1.backfillState
        )
        try digestFact(
            DataControlDeletionTombstoneRecord.self,
            modelType: "DataControlDeletionTombstoneRecord",
            identity: \.id,
            fields: DataControlDigestV1.tombstone
        )
        try digestFact(
            DataControlBackfillState.self,
            modelType: "DataControlBackfillState",
            identity: { _ in DataControlBackfillState.stableID },
            fields: DataControlDigestV1.backfillState
        )
        if includesContentFavorite {
            try digestFact(
                ContentFavoriteRecord.self,
                modelType: "ContentFavoriteRecord",
                identity: \.id,
                fields: ContentFavoriteDigestV1.record
            )
        }
        guard let metadataDatasetID,
              let metadataNextLocalRevision else {
            throw AppDataFailure.corruptionSuspected
        }
        return (
            result,
            attachmentObservations,
            metadataDatasetID,
            metadataNextLocalRevision
        )
    }

    private func boundedRows<T: PersistentModel>(
        _ type: T.Type
    ) throws -> [T] {
        let count = try modelContext.fetchCount(FetchDescriptor<T>())
        try DataInventoryBoundedFetchContract.validate(
            preflightCount: count,
            fetchedCount: count
        )
        var descriptor = FetchDescriptor<T>()
        descriptor.fetchLimit =
            DataInventoryTaxonomy.maximumRowsPerModel + 1
        let rows = try modelContext.fetch(descriptor)
        try DataInventoryBoundedFetchContract.validate(
            preflightCount: count,
            fetchedCount: rows.count
        )
        return rows
    }

    private func timestamp(
        _ value: Date
    ) throws -> RecordDigestV1.Value {
        .timestampMicroseconds(
            try RecordDigestV1.timestampMicroseconds(value)
        )
    }

    private func optionalTimestamp(
        _ value: Date?
    ) throws -> RecordDigestV1.Value {
        guard let value else { return .null }
        return try timestamp(value)
    }

    private func optionalString(
        _ value: String?
    ) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.string) ?? .null
    }

    private func optionalUUID(
        _ value: UUID?
    ) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.uuid) ?? .null
    }

    private func revisionMap(
        _ revisions: [DataInventoryDatabaseEntry],
        datasetID: UUID
    ) throws -> [String: DataInventoryDatabaseEntry] {
        var result: [String: DataInventoryDatabaseEntry] = [:]
        for revision in revisions {
            guard case let .revision(
                recordKey,
                recordType,
                recordID,
                revisionDatasetID,
                localRevision,
                digestVersion,
                committedAt,
                digestHex
            ) = revision,
            recordKey
                == recordType + ":" + recordID.uuidString.lowercased(),
            revisionDatasetID == datasetID,
            localRevision > 0,
            digestVersion == Int64(RecordDigestV1.version),
            committedAt.timeIntervalSince1970.isFinite,
            !digestHex.isEmpty,
            result.updateValue(revision, forKey: recordKey) == nil else {
                throw AppDataFailure.corruptionSuspected
            }
        }
        return result
    }

    func matchesWatermark(
        datasetID: UUID,
        nextLocalRevision: Int64
    ) throws -> Bool {
        var descriptor = FetchDescriptor<DatasetMetadata>()
        descriptor.fetchLimit = 2
        let metadata = try modelContext.fetch(descriptor)
        return metadata.count == 1
            && metadata[0].datasetID == datasetID
            && metadata[0].nextLocalRevision == nextLocalRevision
    }
}

struct DataInventoryStorageCapture {
    let categorySnapshots: [DataInventoryCategorySnapshot]
}

enum DataInventoryProductionStorageAudit {
    static func capture(
        layout: AppDataStoreLayout,
        generationID: UUID,
        database: DataInventoryDatabaseCapture
    ) throws -> DataInventoryStorageCapture {
        let applicationSupportURL =
            layout.rootURL.deletingLastPathComponent()
        let activeLayout =
            try DataInventoryActiveGenerationLayoutAudit.validate(
                applicationSupportURL: applicationSupportURL,
                generationID: generationID
            )
        let control = try DataInventoryManagedRootAudit
            .validatedReadyControlSnapshot(
                applicationSupportURL: applicationSupportURL,
                expectedGenerationID: generationID,
                expectedDatasetID: database.datasetID,
                expectedSchemaVersion: "13.0.0",
                expectedMinimumFactCount: database.factCount,
                expectedMinimumRevisionCount: database.revisionCount,
                activeGenerationLayout: activeLayout
            )
        let generationSnapshots = try generationCategories(
            layout: layout,
            generationID: generationID,
            datasetID: database.datasetID,
            migrationJournal: control.migrationJournal,
            portableRestoreJournal:
                control.portableRestoreJournal
        )
        return DataInventoryStorageCapture(
            categorySnapshots: [control.categorySnapshot]
                + generationSnapshots
                + [try legacyCategory(layout: layout)]
        )
    }

    private static func generationCategories(
        layout: AppDataStoreLayout,
        generationID: UUID,
        datasetID: UUID,
        migrationJournal: MigrationJournal?,
        portableRestoreJournal:
            PortableRestoreJournal?
    ) throws -> [DataInventoryCategorySnapshot] {
        let children = try FileManager.default.contentsOfDirectory(
            at: layout.generationsURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        )
        var snapshotsByKey: [String: [DataInventoryGenerationSnapshot]] =
            Dictionary(
                uniqueKeysWithValues:
                    DataInventoryTaxonomy.categorySpecifications
                    .filter { $0.kind == .generation }
                    .map { ($0.key, []) }
            )
        var hasInvalid = false
        var seenNames = Set<String>()
        var generationInodeKeys = Set<String>()
        for child in children {
            let name =
                child.lastPathComponent
                .precomposedStringWithCanonicalMapping
            guard name == child.lastPathComponent,
                  seenNames.insert(name).inserted else {
                hasInvalid = true
                continue
            }
            let values = try child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isSymbolicLink != true,
                  values.isDirectory == true,
                  let id = UUID(uuidString: name),
                  name == id.uuidString.lowercased() else {
                hasInvalid = true
                continue
            }
            let classification:
                DataInventoryGenerationClassification
            var roles: [DataInventoryGenerationJournalRole] = []
            if id == generationID {
                classification = .active
            } else if let portableRestoreJournal,
                      portableRestoreJournal.phase
                        == .activated,
                      portableRestoreJournal
                        .sourceGenerationID == id {
                classification = .inactiveProven
                roles = [.knownRollbackSource]
            } else if let migrationJournal,
                      migrationJournal.phase == .activated,
                      migrationJournal.sourceGenerationID == id {
                classification = .inactiveProven
                roles = [.knownRollbackSource]
            } else {
                classification = .inactiveUnproven
            }
            let scope: DataInventoryGenerationTreeScope =
                classification == .active
                ? .activeLogicalOverlay
                : .closedFullTree
            do {
                if classification != .active {
                    _ = try DataInventoryActiveGenerationLayoutAudit
                        .validate(
                            applicationSupportURL:
                                layout.rootURL
                                .deletingLastPathComponent(),
                            generationID: id
                        )
                }
                if classification == .inactiveProven {
                    let isPortableSource =
                        portableRestoreJournal?
                            .sourceGenerationID == id
                    let sourceDatasetID =
                        isPortableSource
                        ? portableRestoreJournal?
                            .sourceDatasetID
                        : datasetID
                    guard let sourceDatasetID else {
                        throw AppDataFailure
                            .corruptionSuspected
                    }
                    let bootstrapper = AppDataStoreBootstrapper(
                        layout: layout
                    )
                    let provenance: DataInventoryGenerationProvenance
                    if isPortableSource {
                        provenance = try bootstrapper
                            .validatePortableRestoreSourceForDataInventory(
                                generationID: id,
                                expectedDatasetID:
                                    sourceDatasetID
                            )
                    } else {
                        guard let sourceSchemaVersion =
                                migrationJournal?
                                .sourceSchemaVersion else {
                            throw AppDataFailure
                                .corruptionSuspected
                        }
                        provenance = try bootstrapper
                            .validateGenerationForDataInventory(
                                generationID: id,
                                schemaVersion:
                                    sourceSchemaVersion,
                                expectedDatasetID:
                                    sourceDatasetID
                            )
                    }
                    _ = try AttachmentFileStore(
                        rootURL: layout
                            .generationDirectoryURL(for: id)
                            .appending(
                                path: "Files",
                                directoryHint: .isDirectory
                            )
                    )
                    .dataInventoryCategorySnapshots(
                        observations: provenance.attachments
                    )
                }
                let files = try DataInventoryGenerationTreeAudit
                    .regularFiles(
                        at: child,
                        scope: scope,
                        knownInodeKeys: &generationInodeKeys
                    )
                snapshotsByKey[
                    classification.categoryKey,
                    default: []
                ].append(
                    DataInventoryGenerationSnapshot(
                        entryName: name,
                        generationID: id,
                        primaryClassification: classification,
                        journalRoles: roles,
                        relativePath:
                            "Unmanual/Generations/\(name)",
                        scope: scope,
                        files: files
                    )
                )
            } catch {
                hasInvalid = true
            }
        }
        return DataInventoryTaxonomy.categorySpecifications
            .filter { $0.kind == .generation }
            .map { specification in
                if specification.key
                    == "storage.generation.invalid",
                   hasInvalid {
                    return .failed(
                        key: specification.key,
                        kind: .generation
                    )
                }
                return DataInventoryCategorySnapshot(
                    key: specification.key,
                    kind: .generation,
                    payload: .generations(
                        snapshotsByKey[specification.key] ?? []
                    )
                )
            }
    }

    private static func legacyCategory(
        layout: AppDataStoreLayout
    ) throws -> DataInventoryCategorySnapshot {
        let applicationSupport =
            layout.rootURL.deletingLastPathComponent().standardizedFileURL
        let candidates = [
            layout.legacyStoreURL,
            URL(fileURLWithPath: layout.legacyStoreURL.path + "-wal"),
            URL(fileURLWithPath: layout.legacyStoreURL.path + "-shm")
        ]
        var files: [DataInventoryRegularFileSnapshot] = []
        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.path) {
            let standardized = candidate.standardizedFileURL
            let prefix = applicationSupport.path.hasSuffix("/")
                ? applicationSupport.path
                : applicationSupport.path + "/"
            guard standardized.path.hasPrefix(prefix) else {
                throw DataInventoryFileAuditError
                    .unsafeRelativePath(standardized.path)
            }
            let relative = String(
                standardized.path.dropFirst(prefix.count)
            )
            files.append(
                try DataInventoryRegularFileAudit.snapshot(
                    at: standardized,
                    relativePath: relative,
                    requiresSystemManagedProtection: true
                )
            )
        }
        return DataInventoryCategorySnapshot(
            key: "storage.legacy",
            kind: .control,
            payload: .regularFiles(files)
        )
    }
}

enum DataInventoryStableNotificationObservation {
    static func make(
        firstPending: [String],
        firstDelivered: [String],
        secondPending: [String],
        secondDelivered: [String]
    ) throws -> [DataInventoryNotificationRequestObservation] {
        let firstPendingSet = Set(firstPending)
        let firstDeliveredSet = Set(firstDelivered)
        let secondPendingSet = Set(secondPending)
        let secondDeliveredSet = Set(secondDelivered)
        guard firstPendingSet.count == firstPending.count,
              firstDeliveredSet.count == firstDelivered.count,
              secondPendingSet.count == secondPending.count,
              secondDeliveredSet.count == secondDelivered.count,
              firstPendingSet == secondPendingSet,
              firstDeliveredSet == secondDeliveredSet,
              secondPendingSet.isDisjoint(
                with: secondDeliveredSet
              ) else {
            throw AppDataFailure.storageUnavailable
        }
        return secondPendingSet.sorted().map {
            DataInventoryNotificationRequestObservation(
                identifier: $0,
                deliveryState: .pending
            )
        } + secondDeliveredSet.sorted().map {
            DataInventoryNotificationRequestObservation(
                identifier: $0,
                deliveryState: .delivered
            )
        }
    }
}

@MainActor
private struct SystemDataInventoryNotificationProvider:
    DataInventoryNotificationSnapshotProvider {
    func notificationRequests() async throws
        -> [DataInventoryNotificationRequestObservation] {
        let firstPending = await pendingIdentifiers()
        let firstDelivered = await deliveredIdentifiers()
        let secondPending = await pendingIdentifiers()
        let secondDelivered = await deliveredIdentifiers()
        return try DataInventoryStableNotificationObservation.make(
            firstPending: firstPending,
            firstDelivered: firstDelivered,
            secondPending: secondPending,
            secondDelivered: secondDelivered
        )
    }

    private func pendingIdentifiers() async -> [String] {
        let center = UNUserNotificationCenter.current()
        return await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests {
                continuation.resume(
                    returning: $0.map(\.identifier)
                )
            }
        }
    }

    private func deliveredIdentifiers() async -> [String] {
        let center = UNUserNotificationCenter.current()
        return await withCheckedContinuation { continuation in
            center.getDeliveredNotifications {
                continuation.resume(
                    returning: $0.map(\.request.identifier)
                )
            }
        }
    }
}

enum DataInventoryNotificationCategoryCapture {
    static func snapshots(
        _ result: Result<
            [DataInventoryNotificationRequestObservation],
            Error
        >
    ) -> [DataInventoryCategorySnapshot] {
        switch result {
        case let .success(observations):
            DataInventoryNotificationSnapshotFactory.categories(
                observations: observations
            )
        case .failure:
            DataInventoryTaxonomy.categorySpecifications
                .filter { $0.kind == .notification }
                .map {
                    .failed(key: $0.key, kind: .notification)
                }
        }
    }
}

actor DataInventoryProductionService {
    typealias BackupExportSnapshotBuilder =
        @Sendable (
            AuditedPortableBackup
        ) throws -> PortableBackupExportSnapshot

    private let layout: AppDataStoreLayout
    private let generationID: UUID
    private let databaseActor: DataInventoryDatabaseCaptureActor
    private let attachmentStore: AttachmentFileStore
    private let dataControlCoordinator: AppDataControlCoordinator
    private let portablePackageCleanup:
        PortablePackageCleanupCoordinator
    private let transferRootURL: URL
    private let sessionReleaseProbe:
        AppDataSessionReleaseProbe?
    private let afterTransferFirstSensitiveWrite:
        PortableManagedPathSecurity.MutationProbe
    private let backupExportSnapshotBuilder:
        BackupExportSnapshotBuilder
    private let notificationProvider =
        SystemDataInventoryNotificationProvider()
#if DEBUG
    private var shouldFailOnceForUITest: Bool
    private var shouldRejectExportConfirmationForUITest:
        Bool
#endif

    init?(
        store: BootstrappedAppDataStore,
        dataControlCoordinator: AppDataControlCoordinator,
        transferRootURL: URL? = nil,
        portablePackageCleanup:
            PortablePackageCleanupCoordinator? = nil,
        sessionReleaseProbe:
            AppDataSessionReleaseProbe? = nil,
        afterTransferFirstSensitiveWrite:
            @escaping PortableManagedPathSecurity
            .MutationProbe = {},
        backupExportSnapshotBuilder:
            @escaping BackupExportSnapshotBuilder = {
                try PortableBackupExportSnapshotBuilder
                    .make($0)
            }
    ) {
        guard let layout = store.layout,
              layout.storeURL(for: store.generationID)
                .standardizedFileURL
                == store.storeURL.standardizedFileURL else {
            return nil
        }
        self.layout = layout
        self.generationID = store.generationID
        self.databaseActor = DataInventoryDatabaseCaptureActor(
            modelContainer: store.container
        )
        self.attachmentStore = AttachmentFileStore(
            rootURL: store.attachmentRootURL
        )
        self.dataControlCoordinator = dataControlCoordinator
        let resolvedTransferRoot =
            transferRootURL
            ?? FileManager.default.temporaryDirectory
                .appending(
                    path: "UnmanualTransfers",
                    directoryHint: .isDirectory
                )
        self.transferRootURL = resolvedTransferRoot
        self.portablePackageCleanup =
            portablePackageCleanup
            ?? PortablePackageCleanupCoordinator(
                layout: layout,
                transferRootURL: resolvedTransferRoot
            )
        self.sessionReleaseProbe = sessionReleaseProbe
        self.afterTransferFirstSensitiveWrite =
            afterTransferFirstSensitiveWrite
        self.backupExportSnapshotBuilder =
            backupExportSnapshotBuilder
#if DEBUG
        self.shouldFailOnceForUITest = ProcessInfo.processInfo.arguments
            .contains("-unmanual-ui-test-inventory-fail-once")
        self.shouldRejectExportConfirmationForUITest =
            ProcessInfo.processInfo.arguments.contains(
                "-unmanual-ui-test-export-confirmation-state-changed"
            )
#endif
    }

    func manifest() async throws -> DataInventoryManifest {
        return try await dataControlCoordinator.withReadLease {
            try await self.manifestUnderReadLease()
        }
    }

    func readableJSONV2(
        capturedAt: Date = Date()
    ) async throws -> PortableDataV2Document {
        return try await dataControlCoordinator.withReadLease {
            try await self.portableDocumentUnderCurrentLease(
                capturedAt: capturedAt
            )
        }
    }

    func confirmedReadableJSONV2(
        expectedIdentity: PortableExportStateIdentity,
        capturedAt: Date
    ) async throws -> (
        document: PortableDataV2Document,
        encodedData: Data
    ) {
#if DEBUG
        if shouldRejectExportConfirmationForUITest {
            shouldRejectExportConfirmationForUITest = false
            throw PortableBackupError.stateChanged
        }
#endif
        return try await dataControlCoordinator.withReadLease {
            let document = try await self
                .portableDocumentUnderCurrentLease(
                    capturedAt: capturedAt
                )
            guard try PortableExportStateIdentity(document)
                    == expectedIdentity else {
                throw PortableBackupError.stateChanged
            }
            return (
                document,
                try PortableDataV2Codec.encode(document)
            )
        }
    }

    func completeBackupPackage(
        capturedAt: Date = Date(),
        expectedIdentity:
            PortableExportStateIdentity? = nil
    ) async throws -> AuditedPortableBackup {
#if DEBUG
        if expectedIdentity != nil,
           shouldRejectExportConfirmationForUITest {
            shouldRejectExportConfirmationForUITest = false
            throw PortableBackupError.stateChanged
        }
#endif
        return try await dataControlCoordinator.withReadLease {
            let database = try await self.databaseActor.capture(
                layout: self.layout
            )
            let manifest = try await self
                .manifestUnderReadLease()
            guard manifest.completeness == .complete,
                  manifest.categories.allSatisfy({
                      $0.status == .complete
                  }) else {
                throw AppDataFailure.corruptionSuspected
            }
            let document = try Self.makePortableDocument(
                database: database,
                generationID: self.generationID,
                capturedAt: capturedAt
            )
            if let expectedIdentity {
                guard try PortableExportStateIdentity(
                    document
                ) == expectedIdentity else {
                    throw PortableBackupError.stateChanged
                }
            }
            let activeByID = Dictionary(
                uniqueKeysWithValues: database.attachments
                    .filter {
                        $0.deletedAt == nil
                            && $0.deleteOperationID == nil
                    }
                    .map {
                        ($0.attachment.id, $0.attachment)
                    }
            )
            // Freeze and validate every package byte/count/path decision before
            // registering cleanup work or creating a transfer target.
            let preparedBuild = try PortableBackupPackageBuilder
                .prepare(document: document)
            let root = self.transferRootURL
            var intent = try await self
                .portablePackageCleanup.register(
                    kind: .backupTransfer
                )
            var destinationLease:
                PortablePackageDirectoryLease?
            do {
                let lease =
                    try PortableManagedPathSecurity
                    .createTransferPackageRootLease(
                        transferRootURL: root,
                        packageName:
                            intent.relativePath
                    )
                destinationLease = lease
                intent = try await self.portablePackageCleanup
                    .bind(
                        intent,
                        anchorIdentity:
                            lease
                            .anchorIdentity,
                        rootIdentity:
                            lease.identity,
                        packageIdentity:
                            lease.identity
                    )
                let audited = try PortableBackupPackageBuilder
                    .build(
                        prepared: preparedBuild,
                        destinationLease:
                            lease,
                        afterFirstSensitiveWrite:
                            self
                            .afterTransferFirstSensitiveWrite
                    ) { attachment in
                        guard let snapshot =
                                activeByID[
                                    attachment.attachmentID
                                ],
                              snapshot.ownerType.rawValue
                                == attachment.ownerType,
                              snapshot.ownerID
                                == attachment.ownerID,
                              snapshot.byteCount
                                == attachment.byteCount,
                              snapshot.sha256Hex
                                == attachment.sha256Hex else {
                            throw PortableBackupError
                                .attachmentMismatch
                        }
                        let sourceURL = try self
                            .attachmentStore
                            .auditedFileURL(
                                for: snapshot
                            )
                        return try PortableBackupFileAudit
                            .boundedData(
                                sourceURL,
                                maximumBytes: Int(
                                    PortableBackupLimits
                                        .maximumAttachmentBytes
                                )
                            )
                    }
                guard try await self.databaseActor
                    .matchesWatermark(
                        datasetID: database.datasetID,
                        nextLocalRevision:
                            database.nextLocalRevision
                    ) else {
                    throw PortableBackupError.stateChanged
                }
                return audited.retaining(lease)
            } catch {
                let originalError = error
                if let destinationLease {
                    do {
                        try destinationLease
                            .sanitizeAfterFailure()
                        intent = try await self
                            .portablePackageCleanup
                            .recordLeaseSanitization(
                                intent,
                                anchorIdentity:
                                    destinationLease
                                    .anchorIdentity,
                                rootIdentity:
                                    destinationLease.identity,
                                packageIdentity:
                                    destinationLease.identity
                            )
                    } catch {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                }
                do {
                    try await self
                        .portablePackageCleanup
                        .discard(intent)
                } catch {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                throw originalError
            }
        }
    }

    func completeBackupExportSnapshot(
        capturedAt: Date = Date(),
        expectedIdentity:
            PortableExportStateIdentity? = nil
    ) async throws -> PortableBackupExportSnapshot {
        let backup = try await completeBackupPackage(
            capturedAt: capturedAt,
            expectedIdentity: expectedIdentity
        )
        do {
            let builder = backupExportSnapshotBuilder
            let snapshot = try await Task.detached {
                try Task.checkCancellation()
                return try builder(backup)
            }.value
            try await portablePackageCleanup
                .discardTransferPackage(
                    at: backup.packageURL
                )
            return snapshot
        } catch {
            let originalError = error
            do {
                try await portablePackageCleanup
                    .discardTransferPackage(
                        at: backup.packageURL
                    )
            } catch {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            throw originalError
        }
    }

    func completeBackupPreview(
        capturedAt: Date = Date()
    ) async throws -> AuditedPortableBackup {
        let backup = try await completeBackupPackage(
            capturedAt: capturedAt
        )
        let preview = backup.detached()
        do {
            try await portablePackageCleanup
                .discardTransferPackage(
                    at: backup.packageURL
                )
            return preview
        } catch {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    private func portableDocumentUnderCurrentLease(
        capturedAt: Date
    ) async throws -> PortableDataV2Document {
        let manifest = try await manifestUnderReadLease()
        guard manifest.completeness == .complete,
              manifest.categories.allSatisfy({
                  $0.status == .complete
              }) else {
            throw AppDataFailure.corruptionSuspected
        }
        let database = try await databaseActor.capture(
            layout: layout
        )
        guard try await databaseActor.matchesWatermark(
            datasetID: database.datasetID,
            nextLocalRevision:
                database.nextLocalRevision
        ) else {
            throw AppDataFailure.corruptionSuspected
        }
        return try Self.makePortableDocument(
            database: database,
            generationID: generationID,
            capturedAt: capturedAt
        )
    }

    func stageImportedBackup(
        at sourceURL: URL
    ) async throws -> AuditedPortableBackup {
        // The provider tree, including its exact 2 GiB limit, is validated
        // before any cleanup intent or managed target exists.
        let sourceLease =
            try PortableExternalBackupSourceLease.prepare(
            at: sourceURL
        )
        let root = transferRootURL
        var intent = try await portablePackageCleanup
            .register(kind: .importTransfer)
        var destinationLease:
            PortablePackageDirectoryLease?
        do {
            let lease =
                try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: root,
                    packageName: intent.relativePath
                )
            destinationLease = lease
            intent = try await portablePackageCleanup.bind(
                intent,
                anchorIdentity:
                    lease.anchorIdentity,
                rootIdentity: lease.identity,
                packageIdentity:
                    lease.identity
            )
            return try PortableExternalBackupStager.copy(
                sourceLease: sourceLease,
                destinationLease: lease,
                afterFirstSensitiveWrite:
                    afterTransferFirstSensitiveWrite
            ).retaining(lease)
        } catch {
            let originalError = error
            if let destinationLease {
                do {
                    try destinationLease
                        .sanitizeAfterFailure()
                    intent = try await portablePackageCleanup
                        .recordLeaseSanitization(
                            intent,
                            anchorIdentity:
                                destinationLease
                                .anchorIdentity,
                            rootIdentity:
                                destinationLease.identity,
                            packageIdentity:
                                destinationLease.identity
                        )
                } catch {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
            }
            do {
                try await portablePackageCleanup
                    .discard(intent)
            } catch {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            throw originalError
        }
    }

    func discardTransferPackage(
        at url: URL
    ) async throws {
        try await portablePackageCleanup
            .discardTransferPackage(at: url)
    }

    func retryPendingPackageCleanup()
        async throws -> [URL] {
        try await portablePackageCleanup.retryPending()
        return try await portablePackageCleanup
            .pendingTransferURLs()
    }

    static func makePortableDocument(
        database: DataInventoryDatabaseCapture,
        generationID: UUID,
        capturedAt: Date,
        schemaVersion: String =
            PortableDataSchemaContract.v13.schemaVersion
    ) throws -> PortableDataV2Document {
        let contract = try PortableDataSchemaContract.resolve(
            schemaVersion: schemaVersion
        )
        var modelRowCounts: [String: Int64] = [:]
        var factsByKey: [String: DataInventoryDatabaseEntry] = [:]
        var revisionsByKey:
            [String: DataInventoryDatabaseEntry] = [:]
        var controlKeys: Set<String> = []
        for category in database.categorySnapshots {
            guard case let .database(snapshot) = category.payload else {
                throw AppDataFailure.corruptionSuspected
            }
            for (modelType, count) in snapshot.modelRowCounts {
                guard modelRowCounts.updateValue(
                    count,
                    forKey: modelType
                ) == nil else {
                    throw AppDataFailure.corruptionSuspected
                }
            }
            for entry in snapshot.entries {
                switch entry {
                case let .fact(
                    _,
                    _,
                    _,
                    _,
                    recordKey,
                    _,
                    _,
                    _
                ):
                    guard factsByKey.updateValue(
                        entry,
                        forKey: recordKey
                    ) == nil else {
                        throw AppDataFailure.corruptionSuspected
                    }
                case let .control(modelType, identity):
                    guard controlKeys.insert(
                        modelType + ":" + identity
                    ).inserted else {
                        throw AppDataFailure
                            .corruptionSuspected
                    }
                case let .revision(
                    recordKey,
                    _,
                    _,
                    _,
                    _,
                    _,
                    _,
                    _
                ):
                    guard revisionsByKey.updateValue(
                        entry,
                        forKey: recordKey
                    ) == nil else {
                        throw AppDataFailure
                            .corruptionSuspected
                    }
                }
            }
        }
        guard modelRowCounts.count == contract.modelNames.count,
              Set(modelRowCounts.keys) == Set(contract.modelNames),
              database.portableFacts.count
                == factsByKey.count,
              database.portableFacts.count
                == revisionsByKey.count,
              Set(database.portableControls.map {
                  $0.modelType + ":" + $0.stableIdentity
              }) == controlKeys,
              database.portableControls.count
                == controlKeys.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let controls = database.portableControls.map {
            PortableDataControl(
                modelType: $0.modelType,
                stableIdentity: $0.stableIdentity,
                disposition: portableControlDisposition(
                    $0.modelType
                ),
                fields: $0.fields.map {
                    PortableDataField(
                        name: $0.name,
                        value: PortableDataValue($0.value)
                    )
                }.sorted { $0.name < $1.name }
            )
        }
        let records = try database.portableFacts.map { fact in
            let key = fact.recordType + ":"
                + fact.recordID.uuidString.lowercased()
            guard let entry = factsByKey[key],
                  let revisionEntry = revisionsByKey[key],
                  case let .fact(
                      modelType,
                      recordType,
                      recordID,
                      datasetID,
                      recordKey,
                      localRevision,
                      digestVersion,
                      digestHex
                  ) = entry,
                  case let .revision(
                      revisionRecordKey,
                      revisionRecordType,
                      revisionRecordID,
                      revisionDatasetID,
                      revisionLocalRevision,
                      revisionDigestVersion,
                      committedAt,
                      revisionDigestHex
                  ) = revisionEntry,
                  modelType == fact.modelType,
                  recordType == fact.recordType,
                  recordID == fact.recordID,
                  recordKey == key,
                  digestHex == fact.digestHex,
                  revisionRecordKey == recordKey,
                  revisionRecordType == recordType,
                  revisionRecordID == recordID,
                  revisionDatasetID == datasetID,
                  revisionLocalRevision == localRevision,
                  revisionDigestVersion == digestVersion,
                  revisionDigestHex == digestHex,
                  digestVersion
                    == Int64(RecordDigestV1.version) else {
                throw AppDataFailure.corruptionSuspected
            }
            return PortableDataRecord(
                modelType: modelType,
                recordType: recordType,
                recordID: recordID,
                recordKey: recordKey,
                datasetID: datasetID,
                localRevision: localRevision,
                committedAtMicroseconds:
                    try RecordDigestV1
                        .timestampMicroseconds(committedAt),
                digestVersion: Int(digestVersion),
                digestHex: digestHex,
                fields: fact.fields.map {
                    PortableDataField(
                        name: $0.name,
                        value: PortableDataValue($0.value)
                    )
                }.sorted { $0.name < $1.name }
            )
        }.sorted { $0.recordKey < $1.recordKey }
        let attachments = database.attachments.compactMap {
            observation -> PortableDataAttachment? in
            guard observation.deletedAt == nil,
                  observation.deleteOperationID == nil else {
                return nil
            }
            let value = observation.attachment
            return PortableDataAttachment(
                attachmentID: value.id,
                ownerType: value.ownerType.rawValue,
                ownerID: value.ownerID,
                originalFilename: value.originalFilename,
                typeIdentifier: value.typeIdentifier,
                byteCount: value.byteCount,
                sha256Hex: value.sha256Hex
            )
        }.sorted {
            $0.attachmentID.uuidString
                < $1.attachmentID.uuidString
        }
        let payload = PortableDataV2Payload(
            schemaVersion: schemaVersion,
            datasetID: database.datasetID,
            sourceGenerationID: generationID,
            capturedAtMicroseconds:
                try RecordDigestV1.timestampMicroseconds(
                    capturedAt
                ),
            nextLocalRevision: database.nextLocalRevision,
            modelCounts: modelRowCounts.map {
                PortableDataModelCount(
                    modelType: $0.key,
                    rowCount: $0.value
                )
            }.sorted { $0.modelType < $1.modelType },
            records: records,
            controls: controls.sorted {
                $0.modelType != $1.modelType
                    ? $0.modelType < $1.modelType
                    : $0.stableIdentity
                        < $1.stableIdentity
            },
            activeAttachments: attachments
        )
        return try PortableDataV2Codec.makeDocument(
            payload: payload
        )
    }

    private static func portableControlDisposition(
        _ modelType: String
    ) -> PortableDataControlDisposition {
        switch modelType {
        case "DatasetMetadata":
            .embeddedInEnvelope
        case "NotificationCoverageRecord",
             "CountdownNotificationCoverageRecord":
            .deviceObservationOnly
        default:
            .rebuildOnRestore
        }
    }

    private func manifestUnderReadLease()
        async throws -> DataInventoryManifest {
#if DEBUG
        if shouldFailOnceForUITest {
            shouldFailOnceForUITest = false
            throw AppDataFailure.storageUnavailable
        }
#endif
        let database = try await databaseActor.capture(
            layout: layout
        )
        var snapshots = database.categorySnapshots

        do {
            snapshots += try attachmentStore
                .dataInventoryCategorySnapshots(
                    observations: database.attachments
                )
        } catch {
            snapshots += failedSnapshots(kind: .fileTree)
        }

        do {
            snapshots += try DataInventoryProductionStorageAudit
                .capture(
                    layout: layout,
                    generationID: generationID,
                    database: database
                )
                .categorySnapshots
        } catch {
            snapshots += failedStorageSnapshots()
        }

        do {
            try DataInventoryGlobalFileIdentityAudit.validate(
                layout: layout
            )
        } catch {
            snapshots = snapshots.map { snapshot in
                guard snapshot.key.hasPrefix("files.")
                        || snapshot.key.hasPrefix("storage.") else {
                    return snapshot
                }
                return .failed(
                    key: snapshot.key,
                    kind: snapshot.kind
                )
            }
        }

        do {
            let requests = try await notificationProvider
                .notificationRequests()
            snapshots += DataInventoryNotificationCategoryCapture
                .snapshots(.success(requests))
        } catch {
            snapshots += DataInventoryNotificationCategoryCapture
                .snapshots(.failure(error))
        }
        if try await !databaseActor.matchesWatermark(
            datasetID: database.datasetID,
            nextLocalRevision: database.nextLocalRevision
        ) {
            snapshots = snapshots.map { snapshot in
                guard snapshot.kind == .database else {
                    return snapshot
                }
                return .failed(
                    key: snapshot.key,
                    kind: snapshot.kind
                )
            }
        }
        return try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: database.datasetID,
            nextLocalRevision: database.nextLocalRevision,
            capturedAt: Date(),
            snapshots: snapshots
        )
    }

    private func failedSnapshots(
        kind: DataInventoryCategoryKind
    ) -> [DataInventoryCategorySnapshot] {
        DataInventoryTaxonomy.categorySpecifications
            .filter { $0.kind == kind }
            .map {
                .failed(key: $0.key, kind: $0.kind)
            }
    }

    private func failedStorageSnapshots()
        -> [DataInventoryCategorySnapshot] {
        DataInventoryTaxonomy.categorySpecifications
            .filter {
                $0.kind == .generation
                    || $0.key == "storage.control"
                    || $0.key == "storage.legacy"
            }
            .map {
                .failed(key: $0.key, kind: $0.kind)
            }
    }
}

private struct DataInventoryProductionServiceEnvironmentKey:
    EnvironmentKey {
    static let defaultValue: DataInventoryProductionService? = nil
}

extension EnvironmentValues {
    var dataInventoryService: DataInventoryProductionService? {
        get { self[DataInventoryProductionServiceEnvironmentKey.self] }
        set {
            self[DataInventoryProductionServiceEnvironmentKey.self] =
                newValue
        }
    }
}
