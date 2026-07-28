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
        layout: AppDataStoreLayout
    ) throws -> DataInventoryDatabaseCapture {
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .production
        )
        let foundation = try bootstrapper
            .validateV12DataInventoryFoundation(in: modelContext)
        let collected = try collectAllModels()
        let models = collected.models
        guard models.count == 54,
              Set(models.map(\.modelType))
                == Set(DataInventoryTaxonomy.allDatabaseModelNames) else {
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

        let snapshots = try DataInventoryTaxonomy
            .databaseModelsByCategory
            .map { categoryKey, expectedModels in
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
            attachments: collected.attachments
        )
    }

    private func collectAllModels() throws
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
            evidence: (T) throws -> (String, UUID, String)
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
                            digestHex: value.2
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
                    try RecordDigestV1.sha256Hex(
                        recordType: modelType,
                        recordID: id,
                        fields: try fields(value)
                    )
                )
            }
        }

        func control<T: PersistentModel>(
            _ type: T.Type,
            modelType: String,
            identity: (T) -> String
        ) throws {
            let rows = try boundedRows(type)
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
                    }
                )
            )
        }

        try fact(HRTProfile.self, modelType: "HRTProfile") {
            ("HRTProfile", $0.id, try FactDigestV1.digest($0))
        }
        try fact(CountdownRecord.self, modelType: "CountdownRecord") {
            ("CountdownRecord", $0.id, try FactDigestV1.digest($0))
        }
        try fact(RegimenVersion.self, modelType: "RegimenVersion") {
            ("RegimenVersion", $0.id, try FactDigestV1.digest($0))
        }
        try fact(JourneyEntry.self, modelType: "JourneyEntry") {
            ("JourneyEntry", $0.id, try FactDigestV1.digest($0))
        }
        try fact(LabRecord.self, modelType: "LabRecord") {
            ("LabRecord", $0.id, try FactDigestV1.digest($0))
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
        )
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
        )
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
        )
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
        )
        try control(
            TodayExecutionBackfillState.self,
            modelType: "TodayExecutionBackfillState",
            identity: \.taskKey
        )
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
                    DataInventoryRawFact(
                        modelType: "AttachmentRecord",
                        recordType: "AttachmentRecord",
                        recordID: $0.id,
                        digestHex: try RecordDigestV1.sha256Hex(
                            recordType: "AttachmentRecord",
                            recordID: $0.id,
                            fields: try AttachmentDigestV1.record($0)
                        )
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
        )
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
        )
        try control(
            CountdownLifecycleBackfillState.self,
            modelType: "CountdownLifecycleBackfillState",
            identity: \.taskKey
        )
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
                expectedSchemaVersion: "12.0.0",
                expectedMinimumFactCount: database.factCount,
                expectedMinimumRevisionCount: database.revisionCount,
                activeGenerationLayout: activeLayout
            )
        let generationSnapshots = try generationCategories(
            layout: layout,
            generationID: generationID,
            datasetID: database.datasetID,
            migrationJournal: control.migrationJournal
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
        migrationJournal: MigrationJournal?
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
                    guard let sourceSchemaVersion =
                            migrationJournal?.sourceSchemaVersion else {
                        throw AppDataFailure.corruptionSuspected
                    }
                    let provenance = try AppDataStoreBootstrapper(
                        layout: layout
                    )
                    .validateGenerationForDataInventory(
                        generationID: id,
                        schemaVersion: sourceSchemaVersion,
                        expectedDatasetID: datasetID
                    )
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
    private let layout: AppDataStoreLayout
    private let generationID: UUID
    private let databaseActor: DataInventoryDatabaseCaptureActor
    private let attachmentStore: AttachmentFileStore
    private let dataControlCoordinator: AppDataControlCoordinator
    private let sessionReleaseProbe:
        AppDataSessionReleaseProbe?
    private let notificationProvider =
        SystemDataInventoryNotificationProvider()
#if DEBUG
    private var shouldFailOnceForUITest: Bool
#endif

    init?(
        store: BootstrappedAppDataStore,
        dataControlCoordinator: AppDataControlCoordinator,
        sessionReleaseProbe:
            AppDataSessionReleaseProbe? = nil
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
        self.sessionReleaseProbe = sessionReleaseProbe
#if DEBUG
        self.shouldFailOnceForUITest = ProcessInfo.processInfo.arguments
            .contains("-unmanual-ui-test-inventory-fail-once")
#endif
    }

    func manifest() async throws -> DataInventoryManifest {
        try await dataControlCoordinator.withReadLease {
            try await self.manifestUnderReadLease()
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
