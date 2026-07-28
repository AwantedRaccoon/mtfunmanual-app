import Foundation
import SwiftData
import XCTest
@testable import Unmanual

final class DataControlFoundationTests: XCTestCase {
    func testBootstrapCreatesCanonicalEmptyMarkerAndRevision() throws {
        let container = try makeV11ReadyDataControlContainer()
        let context = ModelContext(container)
        let metadataBefore = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let expectedRevision = metadataBefore.nextLocalRevision
        let completedAt = Date(timeIntervalSince1970: 1_800_100_000)

        let outcome = try DataControlBackfill.run(
            in: container,
            source: .bootstrapV12,
            now: completedAt
        )

        XCTAssertEqual(
            outcome,
            DataControlBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        )
        let state = try XCTUnwrap(
            context.fetch(FetchDescriptor<DataControlBackfillState>()).first
        )
        XCTAssertEqual(state.taskKey, DataControlBackfillState.fixedKey)
        XCTAssertEqual(state.source, .bootstrapV12)
        XCTAssertEqual(state.initialTombstoneCount, 0)
        XCTAssertEqual(
            state.initialTombstoneSetDigest,
            try DataControlDigestV1.initialTombstoneSetDigest()
        )
        XCTAssertEqual(
            state.initialTombstoneSetDigest,
            try RecordDigestV1.sha256Hex(
                recordType: "DataControlTombstoneSetV1",
                recordID: CoreTimeRegimenBackfill.stableUUID(
                    for: "data-control-tombstone-set-v1"
                ),
                fields: [.init("count", .integer(0))]
            )
        )
        XCTAssertEqual(state.completedAt, completedAt)
        XCTAssertEqual(state.updatedAt, completedAt)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<DataControlDeletionTombstoneRecord>()
            ),
            0
        )

        let recordKey = "DataControlBackfillState:"
            + DataControlBackfillState.stableID.uuidString.lowercased()
        let revision = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate { $0.recordKey == recordKey }
                )
            ).first
        )
        XCTAssertEqual(revision.localRevision, expectedRevision)
        XCTAssertEqual(revision.committedAt, completedAt)
        XCTAssertEqual(
            revision.digestHex,
            try RecordDigestV1.sha256Hex(
                recordType: "DataControlBackfillState",
                recordID: DataControlBackfillState.stableID,
                fields: try DataControlDigestV1.backfillState(state)
            )
        )
        XCTAssertNoThrow(
            try DataControlRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testCompletedBackfillIsIdempotentOnlyForSameSource() throws {
        let container = try makeV11ReadyDataControlContainer()
        let completedAt = Date(timeIntervalSince1970: 1_800_100_010)
        _ = try DataControlBackfill.run(
            in: container,
            source: .bootstrapV12,
            now: completedAt
        )

        XCTAssertEqual(
            try DataControlBackfill.run(
                in: container,
                source: .bootstrapV12,
                now: completedAt.addingTimeInterval(10)
            ),
            DataControlBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        )
        XCTAssertThrowsError(
            try DataControlBackfill.run(
                in: container,
                source: .schemaUpgradeV11,
                now: completedAt.addingTimeInterval(20)
            )
        ) {
            XCTAssertEqual($0 as? AppDataFailure, .migrationFailed)
        }
    }

    func testValidatorRejectsTamperedInitialTombstoneSetDigest() throws {
        let container = try makeReadyDataControlContainer()
        let context = ModelContext(container)
        let state = try XCTUnwrap(
            context.fetch(FetchDescriptor<DataControlBackfillState>()).first
        )
        state.initialTombstoneSetDigest = String(repeating: "0", count: 64)
        try context.save()

        XCTAssertThrowsError(
            try DataControlRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) {
            XCTAssertEqual($0 as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testV11StoreLightweightMigratesToV12BeforeBackfill() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "DataControlMigration-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "user.sqlite")
        let datasetID = UUID()

        do {
            let v11 = try AppModelContainerFactory
                .makePrivacyControlContainer(at: storeURL)
            let context = ModelContext(v11)
            context.insert(
                DatasetMetadata(
                    datasetID: datasetID,
                    createdAt: Date(timeIntervalSince1970: 1_800_100_020)
                )
            )
            try context.save()
            _ = try PrivacyControlBackfill.run(
                in: v11,
                source: .bootstrapV11,
                now: Date(timeIntervalSince1970: 1_800_100_021)
            )
        }

        let v12 = try AppModelContainerFactory
            .makeDataControlContainer(at: storeURL)
        let outcome = try DataControlBackfill.run(
            in: v12,
            source: .schemaUpgradeV11,
            now: Date(timeIntervalSince1970: 1_800_100_022)
        )
        let context = ModelContext(v12)
        XCTAssertTrue(outcome.didChangeStore)
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID,
            datasetID
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<DataControlBackfillState>()
                ).first
            ).source,
            .schemaUpgradeV11
        )
    }

    func testCanonicalManifestCodecsRoundTripAndRejectTrailingBytes()
        throws {
        XCTAssertEqual(
            DataControlAttachmentManifest.encode([]),
            "dcm1-a.AAAAAA"
        )
        XCTAssertEqual(
            DataControlPendingNotificationManifest.encode([]),
            "dcm1-n.AAAAAA"
        )

        let targetID = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let snapshot = DataControlTargetSnapshot(
            targetKind: .journeyEntry,
            targetStableKey: targetID.uuidString.lowercased(),
            targetID: targetID,
            expectedRecordKey: "DataControlTarget:journeyEntry:"
                + targetID.uuidString.lowercased(),
            sources: [
                DataControlTargetSourceEntry(
                    recordKey: "JourneyEntry:"
                        + targetID.uuidString.lowercased(),
                    localRevision: 7,
                    digestHex: String(repeating: "a", count: 64)
                )
            ],
            occurrenceProjection: nil
        )
        let encodedSnapshot = try XCTUnwrap(
            DataControlTargetSnapshotManifest.encode(snapshot)
        )
        XCTAssertEqual(
            DataControlTargetSnapshotManifest.decode(encodedSnapshot),
            snapshot
        )
        XCTAssertNil(
            DataControlTargetSnapshotManifest.decode(encodedSnapshot + "A")
        )

        let attachment = DataControlAttachmentManifestEntry(
            attachmentID: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!,
            ownerType: AttachmentOwnerType.journeyEntry.rawValue,
            ownerID: targetID,
            relativePath: "Attachments/aa/file.jpg",
            originalFilename: "证明.jpg",
            contentType: "public.jpeg",
            createdAt: Date(timeIntervalSince1970: 1_800_100_030),
            byteCount: 128,
            sha256Hex: String(repeating: "b", count: 64),
            deletionOperationID: UUID(
                uuidString: "99999999-8888-7777-6666-555555555555"
            )!
        )
        let attachmentManifest = try XCTUnwrap(
            DataControlAttachmentManifest.encode([attachment])
        )
        XCTAssertEqual(
            DataControlAttachmentManifest.decode(attachmentManifest),
            [attachment]
        )

        let notifications = [
            DataControlPendingNotificationEntry(
                namespace: .countdown,
                identifier: "unmanual.countdown.v1.b"
            ),
            DataControlPendingNotificationEntry(
                namespace: .execution,
                identifier: "unmanual.exec.v1.a"
            )
        ]
        let notificationManifest = try XCTUnwrap(
            DataControlPendingNotificationManifest.encode(notifications)
        )
        XCTAssertEqual(
            DataControlPendingNotificationManifest.decode(
                notificationManifest
            ),
            [notifications[1], notifications[0]]
        )
    }

    func testV12SchemaIsStrictlyAdditive() {
        XCTAssertEqual(AppSchemaV11PrivacyControl.models.count, 52)
        XCTAssertEqual(AppSchemaV12DataControl.models.count, 54)
        XCTAssertTrue(
            AppSchemaV12DataControl.models.dropLast(2)
                .elementsEqual(
                    AppSchemaV11PrivacyControl.models,
                    by: { ObjectIdentifier($0) == ObjectIdentifier($1) }
                )
        )
        XCTAssertTrue(
            AppSchemaV12DataControl.models.suffix(2).contains {
                ObjectIdentifier($0)
                    == ObjectIdentifier(
                        DataControlDeletionTombstoneRecord.self
                    )
            }
        )
        XCTAssertTrue(
            AppSchemaV12DataControl.models.suffix(2).contains {
                ObjectIdentifier($0)
                    == ObjectIdentifier(DataControlBackfillState.self)
            }
        )
    }

    func testSourceClosureRejectsOmittedAndExtraJourneyFacts() throws {
        let container = try makeReadyDataControlContainer()
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let revision = metadata.nextLocalRevision
        let committedAt = Date(timeIntervalSince1970: 1_800_100_100)
        let journey = JourneyEntry(
            text: "记录",
            kind: .moment,
            occurredAt: committedAt,
            createdAt: committedAt
        )
        let timestamp = try HistoricalTimestamp.captured(
            instant: committedAt,
            timeZoneIdentifier: "UTC",
            precision: .second
        )
        let historical = HistoricalTimeRecord(
            sourceRecordType: "JourneyEntry",
            sourceRecordID: journey.id,
            timestamp: timestamp,
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        context.insert(journey)
        context.insert(historical)
        let entries = try [
            insertRevision(
                recordType: "JourneyEntry",
                recordID: journey.id,
                fields: FactDigestV1.journey(journey),
                revision: revision,
                committedAt: committedAt,
                metadata: metadata,
                context: context
            ),
            insertRevision(
                recordType: "HistoricalTimeRecord",
                recordID: CoreTimeRegimenBackfill.stableUUID(
                    for: historical.recordKey
                ),
                fields: CoreFactDigestV1.historicalTime(historical),
                revision: revision,
                committedAt: committedAt,
                metadata: metadata,
                context: context
            )
        ]
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
        try context.save()

        let base = DataControlTargetSnapshot(
            targetKind: .journeyEntry,
            targetStableKey: journey.id.uuidString.lowercased(),
            targetID: journey.id,
            expectedRecordKey: "DataControlTarget:journeyEntry:"
                + journey.id.uuidString.lowercased(),
            sources: entries,
            occurrenceProjection: nil
        )
        XCTAssertNoThrow(
            try DataControlRelationshipValidator.validateSourceClosure(
                snapshot: base,
                in: context,
                failure: .corruptionSuspected
            )
        )

        let omitted = DataControlTargetSnapshot(
            targetKind: base.targetKind,
            targetStableKey: base.targetStableKey,
            targetID: base.targetID,
            expectedRecordKey: base.expectedRecordKey,
            sources: [entries[0]],
            occurrenceProjection: nil
        )
        XCTAssertThrowsError(
            try DataControlRelationshipValidator.validateSourceClosure(
                snapshot: omitted,
                in: context,
                failure: .corruptionSuspected
            )
        )

        let extra = DataControlTargetSnapshot(
            targetKind: base.targetKind,
            targetStableKey: base.targetStableKey,
            targetID: base.targetID,
            expectedRecordKey: base.expectedRecordKey,
            sources: entries + [
                DataControlTargetSourceEntry(
                    recordKey: "JourneyEntry:"
                        + UUID().uuidString.lowercased(),
                    localRevision: revision,
                    digestHex: String(repeating: "c", count: 64)
                )
            ],
            occurrenceProjection: nil
        )
        XCTAssertThrowsError(
            try DataControlRelationshipValidator.validateSourceClosure(
                snapshot: extra,
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testOccurrenceClosureRejectsProjectionIdentityMismatch() throws {
        let container = try makeReadyDataControlContainer()
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let revision = metadata.nextLocalRevision
        let committedAt = Date(timeIntervalSince1970: 1_800_100_110)
        let start = try CivilDateFact(year: 2027, month: 1, day: 1)
        let date = try CivilDateFact(year: 2027, month: 1, day: 2)
        let time = try HistoricalLocalTime(
            hour: 9,
            minute: 0,
            second: 0
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let instant = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    timeZone: calendar.timeZone,
                    year: date.year,
                    month: date.month,
                    day: date.day,
                    hour: time.hour,
                    minute: time.minute
                )
            )
        )
        let version = RegimenPlanVersionRecord(
            code: "test",
            title: "测试方案",
            effectiveStartDate: start,
            editState: .sealed,
            createdAt: committedAt
        )
        let item = RegimenItemRecord(
            regimenVersionID: version.id,
            sortOrder: 0,
            displayName: "测试项",
            createdAt: committedAt
        )
        let rule = ScheduleRuleRecord(
            regimenItemID: item.id,
            kind: .dailyTimes,
            anchorDate: start,
            localTimes: "09:00",
            timeZoneBehavior: .floatingLocal,
            revision: 1,
            createdAt: committedAt
        )
        context.insert(version)
        context.insert(item)
        context.insert(rule)
        let entries = try [
            insertRevision(
                recordType: "RegimenPlanVersionRecord",
                recordID: version.id,
                fields: CoreFactDigestV1.regimen(version),
                revision: revision,
                committedAt: committedAt,
                metadata: metadata,
                context: context
            ),
            insertRevision(
                recordType: "RegimenItemRecord",
                recordID: item.id,
                fields: CoreFactDigestV1.item(item),
                revision: revision,
                committedAt: committedAt,
                metadata: metadata,
                context: context
            ),
            insertRevision(
                recordType: "ScheduleRuleRecord",
                recordID: rule.id,
                fields: CoreFactDigestV1.schedule(rule),
                revision: revision,
                committedAt: committedAt,
                metadata: metadata,
                context: context
            )
        ]
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
        try context.save()
        let key = ScheduleOccurrenceResolver.occurrenceKey(
            ruleID: rule.id,
            revision: rule.revision,
            date: date,
            time: time
        )
        let validProjection = DataControlOccurrenceProjection(
            key: key,
            scheduleRuleID: rule.id,
            scheduleRevision: Int64(rule.revision),
            regimenVersionID: version.id,
            regimenItemID: item.id,
            displayTimeZoneIdentifier: "UTC",
            localYear: Int64(date.year),
            localMonth: Int64(date.month),
            localDay: Int64(date.day),
            localHour: Int64(time.hour),
            localMinute: Int64(time.minute),
            localSecond: Int64(time.second),
            localNanosecond: Int64(time.nanosecond),
            resolvedTimeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            instant: instant
        )
        let valid = DataControlTargetSnapshot(
            targetKind: .administrationOccurrence,
            targetStableKey: key,
            targetID: nil,
            expectedRecordKey: "DataControlTarget:administrationOccurrence:"
                + key,
            sources: entries,
            occurrenceProjection: validProjection
        )
        XCTAssertNoThrow(
            try DataControlRelationshipValidator.validateSourceClosure(
                snapshot: valid,
                in: context,
                failure: .corruptionSuspected
            )
        )

        let mismatched = DataControlTargetSnapshot(
            targetKind: valid.targetKind,
            targetStableKey: valid.targetStableKey,
            targetID: valid.targetID,
            expectedRecordKey: valid.expectedRecordKey,
            sources: valid.sources,
            occurrenceProjection: DataControlOccurrenceProjection(
                key: key,
                scheduleRuleID: rule.id,
                scheduleRevision: Int64(rule.revision),
                regimenVersionID: version.id,
                regimenItemID: UUID(),
                displayTimeZoneIdentifier: "UTC",
                localYear: Int64(date.year),
                localMonth: Int64(date.month),
                localDay: Int64(date.day),
                localHour: Int64(time.hour),
                localMinute: Int64(time.minute),
                localSecond: Int64(time.second),
                localNanosecond: Int64(time.nanosecond),
                resolvedTimeZoneIdentifier: "UTC",
                utcOffsetSeconds: 0,
                instant: instant
            )
        )
        XCTAssertThrowsError(
            try DataControlRelationshipValidator.validateSourceClosure(
                snapshot: mismatched,
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testAttachmentOwnerMustBelongToTargetSourceClosure() {
        let targetID = UUID()
        let keys: Set<String> = [
            "JourneyEntry:" + targetID.uuidString.lowercased()
        ]
        XCTAssertTrue(
            DataControlRelationshipValidator
                .attachmentOwnerBelongsToSource(
                    ownerType: "JourneyEntry",
                    ownerID: targetID,
                    sourceKeys: keys
                )
        )
        XCTAssertFalse(
            DataControlRelationshipValidator
                .attachmentOwnerBelongsToSource(
                    ownerType: "StatusObservationRecord",
                    ownerID: UUID(),
                    sourceKeys: keys
                )
        )
    }

    func testDataControlReceiptRequiresLedgerAtMaximumReceiptRevision()
        throws {
        let container = try makeReadyDataControlContainer()
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let revision = metadata.nextLocalRevision
        let committedAt = Date(timeIntervalSince1970: 1_800_100_120)
        let operationID = UUID()
        let receipt = OperationReceiptRecord(
            operationID: operationID,
            commandDigest: String(repeating: "d", count: 64),
            resultRecordType: "DataControlDeletionTombstoneRecord",
            resultRecordID: operationID,
            committedAt: committedAt
        )
        context.insert(receipt)
        _ = try insertRevision(
            recordType: "OperationReceiptRecord",
            recordID: operationID,
            fields: TodayExecutionDigestV1.operationReceipt(receipt),
            revision: revision,
            committedAt: committedAt,
            metadata: metadata,
            context: context
        )
        let ledger = OperationReceiptLedgerRecord(
            receiptCount: 1,
            receiptSetDigest: try TodayExecutionDigestV1.receiptSetDigest([
                receipt
            ]),
            updatedAt: committedAt
        )
        context.insert(ledger)
        _ = try insertRevision(
            recordType: "OperationReceiptLedgerRecord",
            recordID: TodayExecutionDigestV1.receiptLedgerID,
            fields: TodayExecutionDigestV1.operationReceiptLedger(ledger),
            revision: revision,
            committedAt: committedAt,
            metadata: metadata,
            context: context
        )
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
        try context.save()

        XCTAssertNoThrow(
            try DataControlRelationshipValidator
                .validateCurrentReceiptLedger(
                    in: context,
                    failure: .corruptionSuspected
                )
        )
        let ledgerKey = "OperationReceiptLedgerRecord:"
            + TodayExecutionDigestV1.receiptLedgerID.uuidString.lowercased()
        let ledgerRevision = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate { $0.recordKey == ledgerKey }
                )
            ).first
        )
        ledgerRevision.localRevision -= 1
        try context.save()
        XCTAssertThrowsError(
            try DataControlRelationshipValidator
                .validateCurrentReceiptLedger(
                    in: context,
                    failure: .corruptionSuspected
                )
        )
    }

    func testAttachmentSixRowClosureRejectsTerminalAndCreationTampering()
        throws {
        let container = try makeReadyDataControlContainer()
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let creationRevision = metadata.nextLocalRevision
        let deletionRevision = creationRevision + 1
        let createdAt = Date(timeIntervalSince1970: 1_800_100_140)
        let deletedAt = Date(timeIntervalSince1970: 1_800_100_150)
        let attachmentID = UUID()
        let ownerID = UUID()
        let creationOperationID = UUID()
        let deletionOperationID = UUID()
        let attachment = AttachmentRecord(
            id: attachmentID,
            ownerType: .journeyEntry,
            ownerID: ownerID,
            relativePath:
                "Attachments/"
                + String(
                    attachmentID.uuidString.lowercased().prefix(2)
                )
                + "/"
                + attachmentID.uuidString.lowercased()
                + ".jpg",
            originalFilename: "证据.jpg",
            typeIdentifier: "public.jpeg",
            byteCount: 128,
            sha256Hex: String(repeating: "a", count: 64),
            operationID: creationOperationID,
            deleteOperationID: deletionOperationID,
            createdAt: createdAt,
            deletedAt: deletedAt
        )
        let creationCommand = AddAttachmentMetadataCommand(
            operationID: creationOperationID,
            attachmentID: attachmentID,
            ownerType: .journeyEntry,
            ownerID: ownerID,
            relativePath: attachment.relativePath,
            originalFilename: attachment.originalFilename,
            typeIdentifier: attachment.typeIdentifier,
            byteCount: attachment.byteCount,
            sha256Hex: attachment.sha256Hex,
            committedAt: createdAt
        )
        let deletionCommand = DeleteAttachmentCommand(
            operationID: deletionOperationID,
            attachmentID: attachmentID,
            committedAt: deletedAt
        )
        let creationReceipt = OperationReceiptRecord(
            operationID: creationOperationID,
            commandDigest: try AttachmentDigestV1.command(
                creationCommand
            ),
            resultRecordType: "AttachmentRecord",
            resultRecordID: attachmentID,
            committedAt: createdAt
        )
        let deletionReceipt = OperationReceiptRecord(
            operationID: deletionOperationID,
            commandDigest: try AttachmentDigestV1.deleteCommand(
                deletionCommand
            ),
            resultRecordType: "AttachmentRecord",
            resultRecordID: attachmentID,
            committedAt: deletedAt
        )
        context.insert(attachment)
        context.insert(creationReceipt)
        context.insert(deletionReceipt)
        _ = try insertRevision(
            recordType: "AttachmentRecord",
            recordID: attachmentID,
            fields: try AttachmentDigestV1.record(attachment),
            revision: deletionRevision,
            committedAt: deletedAt,
            metadata: metadata,
            context: context
        )
        _ = try insertRevision(
            recordType: "OperationReceiptRecord",
            recordID: creationOperationID,
            fields: TodayExecutionDigestV1.operationReceipt(
                creationReceipt
            ),
            revision: creationRevision,
            committedAt: createdAt,
            metadata: metadata,
            context: context
        )
        _ = try insertRevision(
            recordType: "OperationReceiptRecord",
            recordID: deletionOperationID,
            fields: TodayExecutionDigestV1.operationReceipt(
                deletionReceipt
            ),
            revision: deletionRevision,
            committedAt: deletedAt,
            metadata: metadata,
            context: context
        )
        metadata.nextLocalRevision = deletionRevision + 1
        metadata.lastCommittedAt = deletedAt
        try context.save()
        let entry = DataControlAttachmentManifestEntry(
            attachmentID: attachmentID,
            ownerType: AttachmentOwnerType.journeyEntry.rawValue,
            ownerID: ownerID,
            relativePath: attachment.relativePath,
            originalFilename: attachment.originalFilename,
            contentType: attachment.typeIdentifier,
            createdAt: createdAt,
            byteCount: attachment.byteCount,
            sha256Hex: attachment.sha256Hex,
            deletionOperationID: deletionOperationID
        )

        XCTAssertNoThrow(
            try DataControlRelationshipValidator
                .validateAttachmentSixRowClosure(
                    entry: entry,
                    attachment: attachment,
                    creationReceipt: creationReceipt,
                    deletionReceipt: deletionReceipt,
                    expectedDeletionRevision: deletionRevision,
                    expectedDeletedAt: deletedAt,
                    metadata: metadata,
                    in: context,
                    failure: .corruptionSuspected
                )
        )

        let attachmentKey = "AttachmentRecord:"
            + attachmentID.uuidString.lowercased()
        let attachmentRevision = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate {
                        $0.recordKey == attachmentKey
                    }
                )
            ).first
        )
        let validAttachmentDigest = attachmentRevision.digestHex
        attachmentRevision.digestHex = String(repeating: "f", count: 64)
        try context.save()
        XCTAssertThrowsError(
            try DataControlRelationshipValidator
                .validateAttachmentSixRowClosure(
                    entry: entry,
                    attachment: attachment,
                    creationReceipt: creationReceipt,
                    deletionReceipt: deletionReceipt,
                    expectedDeletionRevision: deletionRevision,
                    expectedDeletedAt: deletedAt,
                    metadata: metadata,
                    in: context,
                    failure: .corruptionSuspected
                )
        )
        attachmentRevision.digestHex = validAttachmentDigest

        let creationReceiptKey = "OperationReceiptRecord:"
            + creationOperationID.uuidString.lowercased()
        let creationReceiptRevision = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate {
                        $0.recordKey == creationReceiptKey
                    }
                )
            ).first
        )
        creationReceiptRevision.committedAt =
            createdAt.addingTimeInterval(1)
        try context.save()
        XCTAssertThrowsError(
            try DataControlRelationshipValidator
                .validateAttachmentSixRowClosure(
                    entry: entry,
                    attachment: attachment,
                    creationReceipt: creationReceipt,
                    deletionReceipt: deletionReceipt,
                    expectedDeletionRevision: deletionRevision,
                    expectedDeletedAt: deletedAt,
                    metadata: metadata,
                    in: context,
                    failure: .corruptionSuspected
                )
        )
    }

    func testDraftSealedAndHrtTargetsRejectMissingTypedFacts()
        throws {
        let container = try makeReadyDataControlContainer()
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let revision = metadata.nextLocalRevision
        let committedAt = Date(timeIntervalSince1970: 1_800_100_160)
        let startDate = try CivilDateFact(
            year: 2026,
            month: 7,
            day: 28
        )
        let draft = RegimenPlanVersionRecord(
            code: "draft",
            title: "草稿",
            effectiveStartDate: startDate,
            editState: .draft,
            createdAt: committedAt
        )
        let sealed = RegimenPlanVersionRecord(
            code: "sealed",
            title: "封存",
            effectiveStartDate: startDate,
            editState: .sealed,
            createdAt: committedAt
        )
        let legacyProfile = HRTProfile(
            startDate: committedAt,
            createdAt: committedAt
        )
        let journeyProfile = HrtJourneyProfileRecord(
            firstEverStartDate: startDate,
            createdAt: committedAt
        )
        context.insert(draft)
        context.insert(sealed)
        context.insert(legacyProfile)
        context.insert(journeyProfile)
        let draftEntry = try insertRevision(
            recordType: "RegimenPlanVersionRecord",
            recordID: draft.id,
            fields: try CoreFactDigestV1.regimen(draft),
            revision: revision,
            committedAt: committedAt,
            metadata: metadata,
            context: context
        )
        let sealedEntry = try insertRevision(
            recordType: "RegimenPlanVersionRecord",
            recordID: sealed.id,
            fields: try CoreFactDigestV1.regimen(sealed),
            revision: revision,
            committedAt: committedAt,
            metadata: metadata,
            context: context
        )
        let legacyProfileEntry = try insertRevision(
            recordType: "HRTProfile",
            recordID: legacyProfile.id,
            fields: try FactDigestV1.profile(legacyProfile),
            revision: revision,
            committedAt: committedAt,
            metadata: metadata,
            context: context
        )
        let journeyProfileEntry = try insertRevision(
            recordType: "HrtJourneyProfileRecord",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: journeyProfile.singletonKey
            ),
            fields: CoreFactDigestV1.journeyProfile(journeyProfile),
            revision: revision,
            committedAt: committedAt,
            metadata: metadata,
            context: context
        )
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
        try context.save()

        let cases: [
            (
                kind: DataControlTargetKind,
                stableKey: String,
                id: UUID?,
                validSources: [DataControlTargetSourceEntry],
                extra: DataControlTargetSourceEntry
            )
        ] = [
            (
                kind: .draftRegimenVersion,
                stableKey: draft.id.uuidString.lowercased(),
                id: draft.id,
                validSources: [draftEntry],
                extra: sealedEntry
            ),
            (
                kind: .sealedRegimenVersion,
                stableKey: sealed.id.uuidString.lowercased(),
                id: sealed.id,
                validSources: [sealedEntry],
                extra: draftEntry
            ),
            (
                kind: .hrtJourney,
                stableKey: HrtJourneyProfileRecord.fixedKey,
                id: nil,
                validSources: [
                    legacyProfileEntry,
                    journeyProfileEntry
                ],
                extra: draftEntry
            )
        ]
        for testCase in cases {
            let valid = DataControlTargetSnapshot(
                targetKind: testCase.kind,
                targetStableKey: testCase.stableKey,
                targetID: testCase.id,
                expectedRecordKey: "DataControlTarget:"
                    + testCase.kind.targetKey(
                        stableKey: testCase.stableKey
                    ),
                sources: testCase.validSources,
                occurrenceProjection: nil
            )
            XCTAssertNoThrow(
                try DataControlRelationshipValidator
                    .validateSourceClosure(
                        snapshot: valid,
                        in: context,
                        failure: .corruptionSuspected
                    )
            )
            let omitted = DataControlTargetSnapshot(
                targetKind: testCase.kind,
                targetStableKey: testCase.stableKey,
                targetID: testCase.id,
                expectedRecordKey: valid.expectedRecordKey,
                sources: Array(testCase.validSources.dropLast()),
                occurrenceProjection: nil
            )
            XCTAssertThrowsError(
                try DataControlRelationshipValidator
                    .validateSourceClosure(
                        snapshot: omitted,
                        in: context,
                        failure: .corruptionSuspected
                    )
            )
            let extra = DataControlTargetSnapshot(
                targetKind: testCase.kind,
                targetStableKey: testCase.stableKey,
                targetID: testCase.id,
                expectedRecordKey: valid.expectedRecordKey,
                sources: testCase.validSources + [testCase.extra],
                occurrenceProjection: nil
            )
            XCTAssertThrowsError(
                try DataControlRelationshipValidator
                    .validateSourceClosure(
                        snapshot: extra,
                        in: context,
                        failure: .corruptionSuspected
                    )
            )
        }
    }

    private func makeV11ReadyDataControlContainer()
        throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        let context = ModelContext(container)
        context.insert(
            DatasetMetadata(
                createdAt: Date(timeIntervalSince1970: 1_800_099_990)
            )
        )
        try context.save()
        _ = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11,
            now: Date(timeIntervalSince1970: 1_800_099_991)
        )
        return container
    }

    private func makeReadyDataControlContainer() throws -> ModelContainer {
        let container = try makeV11ReadyDataControlContainer()
        _ = try DataControlBackfill.run(
            in: container,
            source: .bootstrapV12,
            now: Date(timeIntervalSince1970: 1_800_099_992)
        )
        return container
    }

    @discardableResult
    private func insertRevision(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        revision: Int64,
        committedAt: Date,
        metadata: DatasetMetadata,
        context: ModelContext
    ) throws -> DataControlTargetSourceEntry {
        let recordKey = recordType + ":" + recordID.uuidString.lowercased()
        let digest = try RecordDigestV1.sha256Hex(
            recordType: recordType,
            recordID: recordID,
            fields: fields
        )
        context.insert(
            RecordRevision(
                recordKey: recordKey,
                recordType: recordType,
                recordID: recordID,
                datasetID: metadata.datasetID,
                localRevision: revision,
                digestVersion: RecordDigestV1.version,
                digestHex: digest,
                committedAt: committedAt
            )
        )
        return DataControlTargetSourceEntry(
            recordKey: recordKey,
            localRevision: revision,
            digestHex: digest
        )
    }
}
