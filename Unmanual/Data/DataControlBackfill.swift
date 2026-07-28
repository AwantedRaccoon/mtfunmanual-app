import Foundation
import SwiftData

struct DataControlBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum DataControlBackfill {
    static func run(
        in container: ModelContainer,
        source: DataControlBackfillSource,
        now: Date = Date()
    ) throws -> DataControlBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard now.timeIntervalSince1970.isFinite else {
            throw AppDataFailure.migrationFailed
        }

        var stateDescriptor = FetchDescriptor<DataControlBackfillState>()
        stateDescriptor.fetchLimit = 2
        var tombstoneDescriptor =
            FetchDescriptor<DataControlDeletionTombstoneRecord>()
        tombstoneDescriptor.fetchLimit = 1
        let states = try context.fetch(stateDescriptor)
        let tombstones = try context.fetch(tombstoneDescriptor)
        guard states.count <= 1 else {
            throw AppDataFailure.migrationFailed
        }

        if let state = states.first, state.completedAt != nil {
            guard state.source == source else {
                throw AppDataFailure.migrationFailed
            }
            try DataControlRelationshipValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return DataControlBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }

        guard states.isEmpty, tombstones.isEmpty else {
            throw AppDataFailure.migrationFailed
        }
        try PrivacyControlRelationshipValidator.validate(
            in: context,
            failure: .migrationFailed
        )

        do {
            try context.transaction {
                let state = DataControlBackfillState(
                    source: source,
                    initialTombstoneCount: 0,
                    initialTombstoneSetDigest: try DataControlDigestV1
                        .initialTombstoneSetDigest(),
                    completedAt: now,
                    updatedAt: now
                )
                context.insert(state)
                try insertRevision(
                    for: state,
                    in: context,
                    committedAt: now
                )
                try DataControlRelationshipValidator.validate(
                    in: context,
                    failure: .migrationFailed
                )
                try context.save()
            }
            try DataControlRelationshipValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return DataControlBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func insertRevision(
        for state: DataControlBackfillState,
        in context: ModelContext,
        committedAt: Date
    ) throws {
        var descriptor = FetchDescriptor<DatasetMetadata>()
        descriptor.fetchLimit = 2
        let records = try context.fetch(descriptor)
        guard records.count == 1,
              let metadata = records.first,
              metadata.nextLocalRevision > 0,
              metadata.nextLocalRevision < Int64.max else {
            throw AppDataFailure.migrationFailed
        }
        let revision = metadata.nextLocalRevision
        context.insert(
            RecordRevision(
                recordKey: "DataControlBackfillState:"
                    + DataControlBackfillState.stableID.uuidString.lowercased(),
                recordType: "DataControlBackfillState",
                recordID: DataControlBackfillState.stableID,
                datasetID: metadata.datasetID,
                localRevision: revision,
                digestVersion: RecordDigestV1.version,
                digestHex: try RecordDigestV1.sha256Hex(
                    recordType: "DataControlBackfillState",
                    recordID: DataControlBackfillState.stableID,
                    fields: try DataControlDigestV1.backfillState(state)
                ),
                committedAt: committedAt
            )
        )
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
    }
}

enum DataControlRelationshipValidator {
    static let maximumTombstones = 65_536

    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        try PrivacyControlRelationshipValidator.validate(
            in: context,
            failure: failure
        )

        let metadata = try uniqueMetadata(in: context, failure: failure)
        let state = try uniqueState(in: context, failure: failure)
        guard state.taskKey == DataControlBackfillState.fixedKey,
              state.source != nil,
              state.initialTombstoneCount == 0,
              state.initialTombstoneSetDigest
                == (try DataControlDigestV1.initialTombstoneSetDigest()),
              let completedAt = state.completedAt,
              completedAt.timeIntervalSince1970.isFinite,
              state.updatedAt == completedAt else {
            throw failure
        }

        let stateRevision = try uniqueRevision(
            recordType: "DataControlBackfillState",
            recordID: DataControlBackfillState.stableID,
            in: context,
            failure: failure
        )
        guard stateRevision.datasetID == metadata.datasetID,
              stateRevision.localRevision > 0,
              stateRevision.localRevision < metadata.nextLocalRevision,
              stateRevision.digestVersion == RecordDigestV1.version,
              stateRevision.digestHex
                == (try RecordDigestV1.sha256Hex(
                    recordType: "DataControlBackfillState",
                    recordID: DataControlBackfillState.stableID,
                    fields: try DataControlDigestV1.backfillState(state)
                )),
              stateRevision.committedAt == completedAt else {
            throw failure
        }

        var tombstoneDescriptor =
            FetchDescriptor<DataControlDeletionTombstoneRecord>()
        tombstoneDescriptor.fetchLimit = maximumTombstones + 1
        let tombstones = try context.fetch(tombstoneDescriptor)
        guard tombstones.count <= maximumTombstones,
              Set(tombstones.map(\.targetKey)).count == tombstones.count,
              Set(tombstones.map(\.id)).count == tombstones.count,
              Set(tombstones.map(\.operationID)).count == tombstones.count else {
            throw failure
        }

        var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>()
        receiptDescriptor.fetchLimit = 65_537
        let receipts = try context.fetch(receiptDescriptor)
        guard receipts.count <= 65_536 else { throw failure }
        let receiptsByOperation = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )
        let dataControlReceipts = receipts.filter {
            $0.resultRecordType == "DataControlDeletionTombstoneRecord"
        }
        guard dataControlReceipts.count == tombstones.count else {
            throw failure
        }

        var attachmentDescriptor = FetchDescriptor<AttachmentRecord>()
        attachmentDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumAttachments + 1
        let attachments = try context.fetch(attachmentDescriptor)
        guard attachments.count
                <= ParentRecordLifecycleCapacity.maximumAttachments else {
            throw failure
        }
        let attachmentsByID = try AppDataIndex.checkedUniqueMap(
            attachments,
            keyedBy: \.id,
            failure: failure
        )
        let sourceFacts = try DataControlCurrentFactIndex(
            context: context,
            metadata: metadata,
            failure: failure
        )

        if !dataControlReceipts.isEmpty {
            try validateCurrentReceiptLedger(
                receipts: receipts,
                context: context,
                failure: failure
            )
        }

        for tombstone in tombstones {
            try validate(
                tombstone,
                metadata: metadata,
                receipts: receipts,
                receiptsByOperation: receiptsByOperation,
                attachmentsByID: attachmentsByID,
                sourceFacts: sourceFacts,
                context: context,
                failure: failure
            )
        }
    }

    private static func validate(
        _ tombstone: DataControlDeletionTombstoneRecord,
        metadata: DatasetMetadata,
        receipts: [OperationReceiptRecord],
        receiptsByOperation: [UUID: OperationReceiptRecord],
        attachmentsByID: [UUID: AttachmentRecord],
        sourceFacts: DataControlCurrentFactIndex,
        context: ModelContext,
        failure: AppDataFailure
    ) throws {
        guard tombstone.id == tombstone.operationID,
              let kind = tombstone.targetKind,
              kind.validates(
                  stableKey: tombstone.targetStableKey,
                  targetID: tombstone.targetID
              ),
              tombstone.targetKey
                == kind.targetKey(stableKey: tombstone.targetStableKey),
              tombstone.sourceDatasetID == metadata.datasetID,
              tombstone.sourceNextLocalRevision > 0,
              tombstone.sourceNextLocalRevision < metadata.nextLocalRevision,
              tombstone.expectedLocalRevision > 0,
              tombstone.expectedLocalRevision
                < tombstone.sourceNextLocalRevision,
              isDigest(tombstone.expectedDigestHex),
              isDigest(tombstone.impactDigest),
              isDigest(tombstone.commandDigest),
              tombstone.retainedRecordCount >= 0,
              tombstone.deletedAttachmentCount >= 0,
              tombstone.deletedAttachmentBytes >= 0,
              tombstone.affectedReminderCount >= 0,
              tombstone.timestamp != nil else {
            throw failure
        }

        guard let snapshot = DataControlTargetSnapshotManifest.decode(
            tombstone.targetSnapshotManifest
        ),
        snapshot.targetKind == kind,
        snapshot.targetStableKey == tombstone.targetStableKey,
        snapshot.targetID == tombstone.targetID,
        snapshot.expectedRecordKey == tombstone.expectedRecordKey,
        snapshot.expectedLocalRevision == tombstone.expectedLocalRevision,
        tombstone.expectedRecordKey
            == "DataControlTarget:" + tombstone.targetKey,
        tombstone.expectedDigestHex
            == (try DataControlDigestV1.targetToken(
                tombstone.targetSnapshotManifest
            )),
        !snapshot.sources.contains(where: {
            $0.recordKey.hasPrefix("AttachmentRecord:")
                || $0.recordKey.hasPrefix("OperationReceiptRecord:")
        }),
        let attachmentEntries = DataControlAttachmentManifest.decode(
            tombstone.attachmentManifest
        ),
        let notificationEntries =
            DataControlPendingNotificationManifest.decode(
                tombstone.notificationManifest
            ),
        attachmentEntries.count == tombstone.deletedAttachmentCount,
        notificationEntries.count == tombstone.affectedReminderCount,
        kind.isPlannerTarget || notificationEntries.isEmpty else {
            throw failure
        }
        try sourceFacts.validate(
            snapshot: snapshot,
            kind: kind,
            targetID: tombstone.targetID,
            failure: failure
        )

        var attachmentBytes: Int64 = 0
        let sourceKeys = Set(snapshot.sources.map(\.recordKey))
        let manifestAttachmentIDs = Set(
            attachmentEntries.map(\.attachmentID)
        )
        for entry in attachmentEntries {
            let (sum, overflow) = attachmentBytes
                .addingReportingOverflow(entry.byteCount)
            guard !overflow,
                  attachmentOwnerBelongsToSource(
                      ownerType: entry.ownerType,
                      ownerID: entry.ownerID,
                      sourceKeys: sourceKeys
                  ),
                  let attachment = attachmentsByID[entry.attachmentID],
                  attachment.ownerTypeRawValue == entry.ownerType,
                  attachment.ownerID == entry.ownerID,
                  attachment.relativePath == entry.relativePath,
                  attachment.originalFilename == entry.originalFilename,
                  attachment.typeIdentifier == entry.contentType,
                  (try? RecordDigestV1.timestampMicroseconds(
                      attachment.createdAt
                  ))
                    == (try? RecordDigestV1.timestampMicroseconds(
                        entry.createdAt
                    )),
                  attachment.byteCount == entry.byteCount,
                  attachment.sha256Hex == entry.sha256Hex,
                  attachment.deleteOperationID
                    == entry.deletionOperationID,
                  attachment.deletedAt == tombstone.committedAt else {
                throw failure
            }
            attachmentBytes = sum

            let attachmentReceipts = receipts.filter {
                $0.resultRecordType == "AttachmentRecord"
                    && $0.resultRecordID == entry.attachmentID
            }
            guard attachmentReceipts.count == 2,
                  Set(attachmentReceipts.map(\.operationID))
                    == Set([
                        attachment.operationID,
                        entry.deletionOperationID
                    ]),
                  let creationReceipt = receiptsByOperation[
                      attachment.operationID
                  ],
                  let deletionReceipt = receiptsByOperation[
                      entry.deletionOperationID
                  ] else {
                throw failure
            }
            try validateAttachmentSixRowClosure(
                entry: entry,
                attachment: attachment,
                creationReceipt: creationReceipt,
                deletionReceipt: deletionReceipt,
                expectedDeletionRevision:
                    tombstone.sourceNextLocalRevision,
                expectedDeletedAt: tombstone.committedAt,
                metadata: metadata,
                in: context,
                failure: failure
            )
        }
        guard attachmentBytes == tombstone.deletedAttachmentBytes else {
            throw failure
        }
        for attachment in attachmentsByID.values
        where sourceKeys.contains(
            attachment.ownerTypeRawValue + ":"
                + attachment.ownerID.uuidString.lowercased()
        ) {
            guard attachment.deletedAt != nil else { throw failure }
            if attachment.deletedAt == tombstone.committedAt {
                guard manifestAttachmentIDs.contains(attachment.id) else {
                    throw failure
                }
            }
        }

        let associatedReceiptCount = receipts.reduce(into: 0) { count, receipt in
            let resultKey = receipt.resultRecordType + ":"
                + receipt.resultRecordID.uuidString.lowercased()
            if sourceKeys.contains(resultKey) {
                count += 1
            }
        }
        guard let retainedRecordCount = retainedRecordCount(
            sourceCount: snapshot.sources.count,
            associatedReceiptCount: associatedReceiptCount,
            deletedAttachmentCount: attachmentEntries.count
        ),
        retainedRecordCount == tombstone.retainedRecordCount else {
            throw failure
        }

        let impact = DeletionImpact(
            generationID: tombstone.sourceGenerationID,
            datasetID: tombstone.sourceDatasetID,
            expectedNextLocalRevision: tombstone.sourceNextLocalRevision,
            targetKind: kind,
            targetStableKey: tombstone.targetStableKey,
            targetID: tombstone.targetID,
            expectedRecordKey: tombstone.expectedRecordKey,
            expectedLocalRevision: tombstone.expectedLocalRevision,
            expectedDigestHex: tombstone.expectedDigestHex,
            targetSnapshotManifest: tombstone.targetSnapshotManifest,
            attachmentManifest: tombstone.attachmentManifest,
            notificationManifest: tombstone.notificationManifest,
            retainedRecordCount: tombstone.retainedRecordCount,
            deletedAttachmentCount: tombstone.deletedAttachmentCount,
            deletedAttachmentBytes: tombstone.deletedAttachmentBytes,
            affectedReminderCount: tombstone.affectedReminderCount
        )
        guard tombstone.impactDigest
                == (try DataControlDigestV1.impact(impact)),
              let timestamp = tombstone.timestamp else {
            throw failure
        }
        let command = DeleteDataControlTargetCommand(
            operationID: tombstone.operationID,
            generationID: tombstone.sourceGenerationID,
            datasetID: tombstone.sourceDatasetID,
            expectedNextLocalRevision: tombstone.sourceNextLocalRevision,
            targetKind: kind,
            targetStableKey: tombstone.targetStableKey,
            targetID: tombstone.targetID,
            expectedRecordKey: tombstone.expectedRecordKey,
            expectedLocalRevision: tombstone.expectedLocalRevision,
            expectedDigestHex: tombstone.expectedDigestHex,
            targetSnapshotManifest: tombstone.targetSnapshotManifest,
            impactDigest: tombstone.impactDigest,
            attachmentManifest: tombstone.attachmentManifest,
            notificationManifest: tombstone.notificationManifest,
            timestamp: timestamp
        )
        guard tombstone.commandDigest
                == (try DataControlDigestV1.deleteCommand(command)),
              let receipt = receiptsByOperation[tombstone.operationID],
              receipt.resultRecordType
                == "DataControlDeletionTombstoneRecord",
              receipt.resultRecordID == tombstone.id,
              receipt.commandDigest == tombstone.commandDigest,
              receipt.committedAt == tombstone.committedAt else {
            throw failure
        }

        let revision = try uniqueRevision(
            recordType: "DataControlDeletionTombstoneRecord",
            recordID: tombstone.id,
            in: context,
            failure: failure
        )
        let receiptRevision = try uniqueRevision(
            recordType: "OperationReceiptRecord",
            recordID: receipt.operationID,
            in: context,
            failure: failure
        )
        guard revision.datasetID == tombstone.sourceDatasetID,
              revision.localRevision == tombstone.sourceNextLocalRevision,
              revision.digestVersion == RecordDigestV1.version,
              revision.digestHex == (try RecordDigestV1.sha256Hex(
                  recordType: "DataControlDeletionTombstoneRecord",
                  recordID: tombstone.id,
                  fields: try DataControlDigestV1.tombstone(tombstone)
              )),
              revision.committedAt == tombstone.committedAt,
              receiptRevision.localRevision == revision.localRevision,
              receiptRevision.committedAt == tombstone.committedAt else {
            throw failure
        }
    }

    private static func validateCurrentReceiptLedger(
        receipts: [OperationReceiptRecord],
        context: ModelContext,
        failure: AppDataFailure
    ) throws {
        guard !receipts.isEmpty else { throw failure }
        let receiptType = "OperationReceiptRecord"
        var revisionDescriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordType == receiptType }
        )
        revisionDescriptor.fetchLimit = 65_537
        let receiptRevisions = try context.fetch(revisionDescriptor)
        guard receiptRevisions.count == receipts.count,
              receiptRevisions.count <= 65_536 else {
            throw failure
        }
        let revisionsByID = try AppDataIndex.checkedUniqueMap(
            receiptRevisions,
            keyedBy: \.recordID,
            failure: failure
        )
        guard let maximumRevision = receiptRevisions
            .map(\.localRevision)
            .max() else {
            throw failure
        }
        let maximumReceipts = receipts.filter {
            revisionsByID[$0.operationID]?.localRevision == maximumRevision
        }
        guard !maximumReceipts.isEmpty else { throw failure }

        var ledgerDescriptor =
            FetchDescriptor<OperationReceiptLedgerRecord>()
        ledgerDescriptor.fetchLimit = 2
        let ledgers = try context.fetch(ledgerDescriptor)
        let ledgerID = TodayExecutionDigestV1.receiptLedgerID
        let ledgerRevision = try uniqueRevision(
            recordType: "OperationReceiptLedgerRecord",
            recordID: ledgerID,
            in: context,
            failure: failure
        )
        guard ledgers.count == 1,
              let ledger = ledgers.first,
              ledger.ledgerKey == OperationReceiptLedgerRecord.fixedKey,
              ledger.receiptCount == receipts.count,
              ledger.receiptSetDigest
                == (try TodayExecutionDigestV1.receiptSetDigest(receipts)),
              ledgerRevision.localRevision == maximumRevision,
              ledgerRevision.digestVersion == RecordDigestV1.version,
              ledgerRevision.digestHex == (try RecordDigestV1.sha256Hex(
                  recordType: "OperationReceiptLedgerRecord",
                  recordID: ledgerID,
                  fields: TodayExecutionDigestV1
                    .operationReceiptLedger(ledger)
              )),
              ledgerRevision.committedAt == ledger.updatedAt,
              maximumReceipts.allSatisfy({
                  $0.committedAt == ledger.updatedAt
                      && revisionsByID[$0.operationID]?.committedAt
                        == ledger.updatedAt
              }) else {
            throw failure
        }
    }

    static func validateSourceClosure(
        snapshot: DataControlTargetSnapshot,
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        let metadata = try uniqueMetadata(in: context, failure: failure)
        let sourceFacts = try DataControlCurrentFactIndex(
            context: context,
            metadata: metadata,
            failure: failure
        )
        try sourceFacts.validate(
            snapshot: snapshot,
            kind: snapshot.targetKind,
            targetID: snapshot.targetID,
            failure: failure
        )
    }

    static func validateCurrentReceiptLedger(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        var descriptor = FetchDescriptor<OperationReceiptRecord>()
        descriptor.fetchLimit = 65_537
        let receipts = try context.fetch(descriptor)
        guard receipts.count <= 65_536 else { throw failure }
        try validateCurrentReceiptLedger(
            receipts: receipts,
            context: context,
            failure: failure
        )
    }

    static func attachmentOwnerBelongsToSource(
        ownerType: String,
        ownerID: UUID,
        sourceKeys: Set<String>
    ) -> Bool {
        sourceKeys.contains(
            ownerType + ":" + ownerID.uuidString.lowercased()
        )
    }

    static func validateAttachmentSixRowClosure(
        entry: DataControlAttachmentManifestEntry,
        attachment: AttachmentRecord,
        creationReceipt: OperationReceiptRecord,
        deletionReceipt: OperationReceiptRecord,
        expectedDeletionRevision: Int64,
        expectedDeletedAt: Date,
        metadata: DatasetMetadata,
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        let attachmentRevision = try uniqueRevision(
            recordType: "AttachmentRecord",
            recordID: attachment.id,
            in: context,
            failure: failure
        )
        let creationReceiptRevision = try uniqueRevision(
            recordType: "OperationReceiptRecord",
            recordID: creationReceipt.operationID,
            in: context,
            failure: failure
        )
        let deletionReceiptRevision = try uniqueRevision(
            recordType: "OperationReceiptRecord",
            recordID: deletionReceipt.operationID,
            in: context,
            failure: failure
        )
        let expectedAttachmentDigest = try RecordDigestV1.sha256Hex(
            recordType: "AttachmentRecord",
            recordID: attachment.id,
            fields: try AttachmentDigestV1.record(attachment)
        )
        let expectedCreationReceiptDigest = try RecordDigestV1.sha256Hex(
            recordType: "OperationReceiptRecord",
            recordID: creationReceipt.operationID,
            fields: TodayExecutionDigestV1.operationReceipt(
                creationReceipt
            )
        )
        let expectedDeletionReceiptDigest = try RecordDigestV1.sha256Hex(
            recordType: "OperationReceiptRecord",
            recordID: deletionReceipt.operationID,
            fields: TodayExecutionDigestV1.operationReceipt(
                deletionReceipt
            )
        )
        let creationCommand = AddAttachmentMetadataCommand(
            operationID: attachment.operationID,
            attachmentID: attachment.id,
            ownerType: try attachmentOwner(
                rawValue: attachment.ownerTypeRawValue,
                failure: failure
            ),
            ownerID: attachment.ownerID,
            relativePath: attachment.relativePath,
            originalFilename: attachment.originalFilename,
            typeIdentifier: attachment.typeIdentifier,
            byteCount: attachment.byteCount,
            sha256Hex: attachment.sha256Hex,
            committedAt: attachment.createdAt
        )
        let deletionCommand = DeleteAttachmentCommand(
            operationID: entry.deletionOperationID,
            attachmentID: entry.attachmentID,
            committedAt: expectedDeletedAt
        )

        guard expectedDeletionRevision > 0,
              attachment.id == entry.attachmentID,
              attachment.operationID != entry.deletionOperationID,
              attachment.deleteOperationID == entry.deletionOperationID,
              attachment.deletedAt == expectedDeletedAt,
              creationReceipt.operationID == attachment.operationID,
              creationReceipt.resultRecordType == "AttachmentRecord",
              creationReceipt.resultRecordID == attachment.id,
              creationReceipt.committedAt == attachment.createdAt,
              creationReceipt.commandDigest
                == (try AttachmentDigestV1.command(creationCommand)),
              deletionReceipt.operationID == entry.deletionOperationID,
              deletionReceipt.resultRecordType == "AttachmentRecord",
              deletionReceipt.resultRecordID == attachment.id,
              deletionReceipt.committedAt == expectedDeletedAt,
              deletionReceipt.commandDigest
                == (try AttachmentDigestV1.deleteCommand(deletionCommand)),
              attachmentRevision.datasetID == metadata.datasetID,
              attachmentRevision.localRevision
                == expectedDeletionRevision,
              attachmentRevision.digestVersion == RecordDigestV1.version,
              attachmentRevision.digestHex == expectedAttachmentDigest,
              attachmentRevision.committedAt == expectedDeletedAt,
              creationReceiptRevision.datasetID == metadata.datasetID,
              creationReceiptRevision.localRevision > 0,
              creationReceiptRevision.localRevision
                < expectedDeletionRevision,
              creationReceiptRevision.digestVersion
                == RecordDigestV1.version,
              creationReceiptRevision.digestHex
                == expectedCreationReceiptDigest,
              creationReceiptRevision.committedAt
                == creationReceipt.committedAt,
              deletionReceiptRevision.datasetID == metadata.datasetID,
              deletionReceiptRevision.localRevision
                == expectedDeletionRevision,
              deletionReceiptRevision.digestVersion
                == RecordDigestV1.version,
              deletionReceiptRevision.digestHex
                == expectedDeletionReceiptDigest,
              deletionReceiptRevision.committedAt
                == expectedDeletedAt else {
            throw failure
        }
    }

    private static func attachmentOwner(
        rawValue: String,
        failure: AppDataFailure
    ) throws -> AttachmentOwnerType {
        guard let owner = AttachmentOwnerType(rawValue: rawValue) else {
            throw failure
        }
        return owner
    }

    private static func uniqueMetadata(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> DatasetMetadata {
        var descriptor = FetchDescriptor<DatasetMetadata>()
        descriptor.fetchLimit = 2
        let records = try context.fetch(descriptor)
        guard records.count == 1,
              let record = records.first,
              record.singletonKey == DatasetMetadata.fixedKey,
              record.nextLocalRevision > 0 else {
            throw failure
        }
        return record
    }

    private static func uniqueState(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> DataControlBackfillState {
        var descriptor = FetchDescriptor<DataControlBackfillState>()
        descriptor.fetchLimit = 2
        let records = try context.fetch(descriptor)
        guard records.count == 1, let record = records.first else {
            throw failure
        }
        return record
    }

    private static func uniqueRevision(
        recordType: String,
        recordID: UUID,
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> RecordRevision {
        let recordKey = recordType + ":" + recordID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == recordKey }
        )
        descriptor.fetchLimit = 2
        let revisions = try context.fetch(descriptor)
        guard revisions.count == 1,
              let revision = revisions.first,
              revision.recordType == recordType,
              revision.recordID == recordID else {
            throw failure
        }
        return revision
    }

    private static func retainedRecordCount(
        sourceCount: Int,
        associatedReceiptCount: Int,
        deletedAttachmentCount: Int
    ) -> Int? {
        guard sourceCount >= 0,
              associatedReceiptCount >= 0,
              deletedAttachmentCount >= 0 else {
            return nil
        }
        let (sourceRows, sourceOverflow) =
            sourceCount.multipliedReportingOverflow(by: 2)
        let (receiptRows, receiptOverflow) =
            associatedReceiptCount.multipliedReportingOverflow(by: 2)
        let (attachmentRows, attachmentOverflow) =
            deletedAttachmentCount.multipliedReportingOverflow(by: 6)
        let (first, firstOverflow) = sourceRows.addingReportingOverflow(
            receiptRows
        )
        let (second, secondOverflow) = first.addingReportingOverflow(
            attachmentRows
        )
        let (result, finalOverflow) = second.addingReportingOverflow(4)
        guard !sourceOverflow, !receiptOverflow, !attachmentOverflow,
              !firstOverflow, !secondOverflow, !finalOverflow else {
            return nil
        }
        return result
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }
}

private struct DataControlCurrentFact {
    let entry: DataControlTargetSourceEntry
    let permitsHistoricalOccurrenceSnapshot: Bool
}

private struct DataControlCurrentFactIndex {
    private static let maximumRowsPerModel = 65_536
    private static let maximumRevisions = 1_000_000

    private let metadata: DatasetMetadata
    private let revisionsByKey: [String: RecordRevision]
    private let journeysByID: [UUID: JourneyEntry]
    private let historicalTimes: [HistoricalTimeRecord]
    private let versionsByID: [UUID: RegimenPlanVersionRecord]
    private let itemsByID: [UUID: RegimenItemRecord]
    private let scheduleRulesByID: [UUID: ScheduleRuleRecord]
    private let reminderPreferences: [ReminderPreferenceRecord]
    private let reminderOverrides: [ReminderOverrideRecord]
    private let administrationEvents: [AdministrationEventRecord]
    private let legacyHrtProfiles: [HRTProfile]
    private let hrtJourneyProfiles: [HrtJourneyProfileRecord]
    private let hrtPeriods: [HrtPeriodRecord]
    private let hrtLifecycleEvents: [HrtJourneyLifecycleEventRecord]

    init(
        context: ModelContext,
        metadata: DatasetMetadata,
        failure: AppDataFailure
    ) throws {
        self.metadata = metadata
        var revisionDescriptor = FetchDescriptor<RecordRevision>()
        revisionDescriptor.fetchLimit = Self.maximumRevisions + 1
        let revisions = try context.fetch(revisionDescriptor)
        guard revisions.count <= Self.maximumRevisions else { throw failure }
        revisionsByKey = try AppDataIndex.checkedUniqueMap(
            revisions,
            keyedBy: \.recordKey,
            failure: failure
        )

        let journeys = try Self.fetchBounded(
            JourneyEntry.self,
            context: context,
            failure: failure
        )
        journeysByID = try AppDataIndex.checkedUniqueMap(
            journeys,
            keyedBy: \.id,
            failure: failure
        )
        historicalTimes = try Self.fetchBounded(
            HistoricalTimeRecord.self,
            context: context,
            failure: failure
        )
        let versions = try Self.fetchBounded(
            RegimenPlanVersionRecord.self,
            context: context,
            failure: failure
        )
        versionsByID = try AppDataIndex.checkedUniqueMap(
            versions,
            keyedBy: \.id,
            failure: failure
        )
        let items = try Self.fetchBounded(
            RegimenItemRecord.self,
            context: context,
            failure: failure
        )
        itemsByID = try AppDataIndex.checkedUniqueMap(
            items,
            keyedBy: \.id,
            failure: failure
        )
        let rules = try Self.fetchBounded(
            ScheduleRuleRecord.self,
            context: context,
            failure: failure
        )
        scheduleRulesByID = try AppDataIndex.checkedUniqueMap(
            rules,
            keyedBy: \.id,
            failure: failure
        )
        reminderPreferences = try Self.fetchBounded(
            ReminderPreferenceRecord.self,
            context: context,
            failure: failure
        )
        reminderOverrides = try Self.fetchBounded(
            ReminderOverrideRecord.self,
            context: context,
            failure: failure
        )
        administrationEvents = try Self.fetchBounded(
            AdministrationEventRecord.self,
            context: context,
            failure: failure
        )
        legacyHrtProfiles = try Self.fetchBounded(
            HRTProfile.self,
            context: context,
            failure: failure
        )
        hrtJourneyProfiles = try Self.fetchBounded(
            HrtJourneyProfileRecord.self,
            context: context,
            failure: failure
        )
        hrtPeriods = try Self.fetchBounded(
            HrtPeriodRecord.self,
            context: context,
            failure: failure
        )
        hrtLifecycleEvents = try Self.fetchBounded(
            HrtJourneyLifecycleEventRecord.self,
            context: context,
            failure: failure
        )
    }

    func validate(
        snapshot: DataControlTargetSnapshot,
        kind: DataControlTargetKind,
        targetID: UUID?,
        failure: AppDataFailure
    ) throws {
        let currentFacts: [DataControlCurrentFact]
        switch kind {
        case .journeyEntry:
            guard let targetID else { throw failure }
            currentFacts = try journeyClosure(
                targetID: targetID,
                failure: failure
            )
        case .administrationOccurrence:
            currentFacts = try occurrenceClosure(
                snapshot: snapshot,
                failure: failure
            )
        case .draftRegimenVersion, .sealedRegimenVersion:
            guard let targetID else { throw failure }
            currentFacts = try regimenClosure(
                targetID: targetID,
                kind: kind,
                failure: failure
            )
        case .hrtJourney:
            currentFacts = try hrtJourneyClosure(failure: failure)
        }

        let currentByKey = try AppDataIndex.checkedUniqueMap(
            currentFacts,
            keyedBy: \.entry.recordKey,
            failure: failure
        )
        let snapshotByKey = try AppDataIndex.checkedUniqueMap(
            snapshot.sources,
            keyedBy: \.recordKey,
            failure: failure
        )
        guard Set(currentByKey.keys) == Set(snapshotByKey.keys) else {
            throw failure
        }
        for (recordKey, current) in currentByKey {
            guard let historical = snapshotByKey[recordKey] else {
                throw failure
            }
            if current.permitsHistoricalOccurrenceSnapshot {
                guard historical.localRevision
                        <= current.entry.localRevision,
                      historical.localRevision > 0 else {
                    throw failure
                }
                if historical.localRevision == current.entry.localRevision {
                    guard historical.digestHex == current.entry.digestHex else {
                        throw failure
                    }
                }
            } else {
                guard historical == current.entry else { throw failure }
            }
        }
    }

    private func journeyClosure(
        targetID: UUID,
        failure: AppDataFailure
    ) throws -> [DataControlCurrentFact] {
        guard let journey = journeysByID[targetID] else { throw failure }
        let times = historicalTimes.filter {
            $0.sourceRecordType == "JourneyEntry"
                && $0.sourceRecordID == targetID
        }
        guard times.count == 1 else { throw failure }
        return [
            try fact(
                recordType: "JourneyEntry",
                recordID: journey.id,
                fields: try FactDigestV1.journey(journey),
                failure: failure
            ),
            try historicalFact(times[0], failure: failure)
        ]
    }

    private func occurrenceClosure(
        snapshot: DataControlTargetSnapshot,
        failure: AppDataFailure
    ) throws -> [DataControlCurrentFact] {
        guard let projection = snapshot.occurrenceProjection,
              let identity = ScheduleOccurrenceResolver.identity(
                  for: snapshot.targetStableKey
              ),
              projection.key == snapshot.targetStableKey,
              identity.ruleID == projection.scheduleRuleID,
              Int64(identity.revision) == projection.scheduleRevision,
              identity.date.year == projection.localYear,
              identity.date.month == projection.localMonth,
              identity.date.day == projection.localDay,
              identity.time.hour == projection.localHour,
              identity.time.minute == projection.localMinute,
              projection.localSecond == 0,
              projection.localNanosecond == 0,
              let schedule = scheduleRulesByID[
                  projection.scheduleRuleID
              ],
              let item = itemsByID[projection.regimenItemID],
              let version = versionsByID[projection.regimenVersionID],
              schedule.regimenItemID == item.id,
              item.regimenVersionID == version.id else {
            throw failure
        }
        try validateOccurrenceProjection(
            projection,
            identity: identity,
            schedule: schedule,
            item: item,
            version: version,
            failure: failure
        )

        var facts: [DataControlCurrentFact] = [
            try fact(
                recordType: "RegimenPlanVersionRecord",
                recordID: version.id,
                fields: try CoreFactDigestV1.regimen(version),
                permitsHistoricalOccurrenceSnapshot: true,
                failure: failure
            ),
            try fact(
                recordType: "RegimenItemRecord",
                recordID: item.id,
                fields: CoreFactDigestV1.item(item),
                permitsHistoricalOccurrenceSnapshot: true,
                failure: failure
            ),
            try fact(
                recordType: "ScheduleRuleRecord",
                recordID: schedule.id,
                fields: CoreFactDigestV1.schedule(schedule),
                permitsHistoricalOccurrenceSnapshot: true,
                failure: failure
            )
        ]
        let events = administrationEvents.filter {
            $0.occurrenceKey == snapshot.targetStableKey
        }
        let overrides = reminderOverrides.filter {
            $0.occurrenceKey == snapshot.targetStableKey
        }
        for event in events {
            facts.append(
                try fact(
                    recordType: "AdministrationEventRecord",
                    recordID: event.id,
                    fields: try TodayExecutionDigestV1
                        .administrationEvent(event),
                    failure: failure
                )
            )
        }
        for override in overrides {
            facts.append(
                try fact(
                    recordType: "ReminderOverrideRecord",
                    recordID: override.id,
                    fields: try TodayExecutionDigestV1
                        .reminderOverride(override),
                    failure: failure
                )
            )
        }
        let eventIDs = Set(events.map(\.id))
        let times = historicalTimes.filter {
            $0.sourceRecordType == "AdministrationEventRecord"
                && eventIDs.contains($0.sourceRecordID)
        }
        guard times.count == events.count else { throw failure }
        for time in times {
            facts.append(try historicalFact(time, failure: failure))
        }
        return facts
    }

    private func regimenClosure(
        targetID: UUID,
        kind: DataControlTargetKind,
        failure: AppDataFailure
    ) throws -> [DataControlCurrentFact] {
        guard let version = versionsByID[targetID],
              (kind == .draftRegimenVersion
                && version.editState == .draft)
                || (kind == .sealedRegimenVersion
                    && version.editState == .sealed) else {
            throw failure
        }
        let items = itemsByID.values.filter {
            $0.regimenVersionID == targetID
        }
        let itemIDs = Set(items.map(\.id))
        let rules = scheduleRulesByID.values.filter {
            itemIDs.contains($0.regimenItemID)
        }
        let ruleIDs = Set(rules.map(\.id))
        let preferences = reminderPreferences.filter {
            ruleIDs.contains($0.scheduleRuleID)
        }
        let overrides = reminderOverrides.filter {
            ruleIDs.contains($0.scheduleRuleID)
        }
        let events = administrationEvents.filter {
            $0.regimenVersionID == targetID
        }
        let eventIDs = Set(events.map(\.id))
        let times = historicalTimes.filter {
            $0.sourceRecordType == "AdministrationEventRecord"
                && eventIDs.contains($0.sourceRecordID)
        }
        guard times.count == events.count else { throw failure }

        var facts: [DataControlCurrentFact] = [
            try fact(
                recordType: "RegimenPlanVersionRecord",
                recordID: version.id,
                fields: try CoreFactDigestV1.regimen(version),
                failure: failure
            )
        ]
        for item in items {
            facts.append(
                try fact(
                    recordType: "RegimenItemRecord",
                    recordID: item.id,
                    fields: CoreFactDigestV1.item(item),
                    failure: failure
                )
            )
        }
        for rule in rules {
            facts.append(
                try fact(
                    recordType: "ScheduleRuleRecord",
                    recordID: rule.id,
                    fields: CoreFactDigestV1.schedule(rule),
                    failure: failure
                )
            )
        }
        for preference in preferences {
            facts.append(
                try fact(
                    recordType: "ReminderPreferenceRecord",
                    recordID: preference.id,
                    fields: TodayExecutionDigestV1
                        .reminderPreference(preference),
                    failure: failure
                )
            )
        }
        for override in overrides {
            facts.append(
                try fact(
                    recordType: "ReminderOverrideRecord",
                    recordID: override.id,
                    fields: try TodayExecutionDigestV1
                        .reminderOverride(override),
                    failure: failure
                )
            )
        }
        for event in events {
            facts.append(
                try fact(
                    recordType: "AdministrationEventRecord",
                    recordID: event.id,
                    fields: try TodayExecutionDigestV1
                        .administrationEvent(event),
                    failure: failure
                )
            )
        }
        for time in times {
            facts.append(try historicalFact(time, failure: failure))
        }
        return facts
    }

    private func hrtJourneyClosure(
        failure: AppDataFailure
    ) throws -> [DataControlCurrentFact] {
        guard legacyHrtProfiles.count == 1,
              hrtJourneyProfiles.count == 1,
              let legacy = legacyHrtProfiles.first,
              let profile = hrtJourneyProfiles.first,
              profile.singletonKey == HrtJourneyProfileRecord.fixedKey else {
            throw failure
        }
        var facts: [DataControlCurrentFact] = [
            try fact(
                recordType: "HRTProfile",
                recordID: legacy.id,
                fields: try FactDigestV1.profile(legacy),
                failure: failure
            ),
            try fact(
                recordType: "HrtJourneyProfileRecord",
                recordID: CoreTimeRegimenBackfill.stableUUID(
                    for: profile.singletonKey
                ),
                fields: CoreFactDigestV1.journeyProfile(profile),
                failure: failure
            )
        ]
        for period in hrtPeriods {
            facts.append(
                try fact(
                    recordType: "HrtPeriodRecord",
                    recordID: period.id,
                    fields: try CoreFactDigestV1.period(period),
                    failure: failure
                )
            )
        }
        for event in hrtLifecycleEvents {
            facts.append(
                try fact(
                    recordType: "HrtJourneyLifecycleEventRecord",
                    recordID: event.id,
                    fields: try HrtJourneyLifecycleDigest.event(event),
                    failure: failure
                )
            )
        }
        return facts
    }

    private func historicalFact(
        _ time: HistoricalTimeRecord,
        failure: AppDataFailure
    ) throws -> DataControlCurrentFact {
        try fact(
            recordType: "HistoricalTimeRecord",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: time.recordKey
            ),
            fields: try CoreFactDigestV1.historicalTime(time),
            failure: failure
        )
    }

    private func fact(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        permitsHistoricalOccurrenceSnapshot: Bool = false,
        failure: AppDataFailure
    ) throws -> DataControlCurrentFact {
        let recordKey = recordType + ":" + recordID.uuidString.lowercased()
        guard let revision = revisionsByKey[recordKey],
              revision.recordType == recordType,
              revision.recordID == recordID,
              revision.datasetID == metadata.datasetID,
              revision.localRevision > 0,
              revision.localRevision < metadata.nextLocalRevision,
              revision.digestVersion == RecordDigestV1.version,
              revision.digestHex == (try RecordDigestV1.sha256Hex(
                  recordType: recordType,
                  recordID: recordID,
                  fields: fields
              )) else {
            throw failure
        }
        return DataControlCurrentFact(
            entry: DataControlTargetSourceEntry(
                recordKey: recordKey,
                localRevision: revision.localRevision,
                digestHex: revision.digestHex
            ),
            permitsHistoricalOccurrenceSnapshot:
                permitsHistoricalOccurrenceSnapshot
        )
    }

    private func validateOccurrenceProjection(
        _ projection: DataControlOccurrenceProjection,
        identity: ScheduleOccurrenceIdentity,
        schedule: ScheduleRuleRecord,
        item: RegimenItemRecord,
        version: RegimenPlanVersionRecord,
        failure: AppDataFailure
    ) throws {
        guard TimeZone(identifier: projection.displayTimeZoneIdentifier)
                != nil,
              let resolvedTimeZone = TimeZone(
                  identifier: projection.resolvedTimeZoneIdentifier
              ),
              projection.utcOffsetSeconds
                == Int64(
                    resolvedTimeZone.secondsFromGMT(
                        for: projection.instant
                    )
                ),
              let localDate = try? CivilDateFact(
                  year: Int(projection.localYear),
                  month: Int(projection.localMonth),
                  day: Int(projection.localDay)
              ),
              let localTime = try? HistoricalLocalTime(
                  hour: Int(projection.localHour),
                  minute: Int(projection.localMinute),
                  second: Int(projection.localSecond),
                  nanosecond: Int(projection.localNanosecond)
              ),
              localDate == identity.date,
              localTime == identity.time else {
            throw failure
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: resolvedTimeZone,
            year: localDate.year,
            month: localDate.month,
            day: localDate.day,
            hour: localTime.hour,
            minute: localTime.minute,
            second: localTime.second,
            nanosecond: localTime.nanosecond
        )
        guard let resolvedInstant = calendar.date(from: components),
              (try? RecordDigestV1.timestampMicroseconds(resolvedInstant))
                == (try? RecordDigestV1.timestampMicroseconds(
                    projection.instant
                )) else {
            throw failure
        }

        guard schedule.revision == Int(projection.scheduleRevision) else {
            return
        }
        let expectedResolvedZone: String
        switch schedule.timeZoneBehavior {
        case .floatingLocal:
            expectedResolvedZone = projection.displayTimeZoneIdentifier
        case .fixedZone:
            guard let fixed = schedule.fixedTimeZoneIdentifier else {
                throw failure
            }
            expectedResolvedZone = fixed
        }
        guard projection.resolvedTimeZoneIdentifier == expectedResolvedZone,
              let kind = ScheduleRuleKind(
                  rawValue: schedule.kindRawValue
              ),
              let behavior = ScheduleTimeZoneBehavior(
                  rawValue: schedule.timeZoneBehaviorRawValue
              ),
              let anchor = try? CivilDateFact(
                  year: schedule.anchorYear,
                  month: schedule.anchorMonth,
                  day: schedule.anchorDay
              ),
              let versionStart = version.effectiveStartDate else {
            throw failure
        }
        let ruleEnd = try optionalCivilDate(
            year: schedule.endYear,
            month: schedule.endMonth,
            day: schedule.endDay,
            failure: failure
        )
        let activeStart = max(anchor, versionStart)
        let activeEnd: CivilDateFact?
        switch (ruleEnd, version.effectiveEndDate) {
        case let (rule?, version?): activeEnd = min(rule, version)
        case let (rule?, nil): activeEnd = rule
        case let (nil, version?): activeEnd = version
        case (nil, nil): activeEnd = nil
        }
        let spec = ScheduleRuleSpec(
            id: schedule.id,
            regimenVersionID: version.id,
            regimenItemID: item.id,
            displayName: item.displayName,
            kind: kind,
            anchorDate: anchor,
            activeStartDate: activeStart,
            endDate: activeEnd,
            localTimes: schedule.localTimes,
            weekdays: schedule.weekdays,
            intervalDays: schedule.intervalDays,
            timeZoneBehavior: behavior,
            fixedTimeZoneIdentifier: schedule.fixedTimeZoneIdentifier,
            revision: schedule.revision
        )
        guard ScheduleOccurrenceResolver.validatesStoredOccurrence(
            key: projection.key,
            plannedInstant: projection.instant,
            rule: spec
        ) else {
            throw failure
        }
    }

    private func optionalCivilDate(
        year: Int?,
        month: Int?,
        day: Int?,
        failure: AppDataFailure
    ) throws -> CivilDateFact? {
        if year == nil, month == nil, day == nil { return nil }
        guard let year, let month, let day,
              let value = try? CivilDateFact(
                  year: year,
                  month: month,
                  day: day
              ) else {
            throw failure
        }
        return value
    }

    private static func fetchBounded<T: PersistentModel>(
        _ type: T.Type,
        context: ModelContext,
        failure: AppDataFailure
    ) throws -> [T] {
        var descriptor = FetchDescriptor<T>()
        descriptor.fetchLimit = maximumRowsPerModel + 1
        let records = try context.fetch(descriptor)
        guard records.count <= maximumRowsPerModel else { throw failure }
        return records
    }
}
