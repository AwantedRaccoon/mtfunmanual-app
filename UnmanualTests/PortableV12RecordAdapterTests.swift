import Foundation
import SwiftData
import XCTest
@testable import Unmanual

final class PortableV12RecordAdapterTests: XCTestCase {
    func testFrozenV12DocumentMaterializesInV13ContainerWithZeroFavorites()
        throws {
        let fixture = try PortableV12Fixture.make()
        let container = try AppModelContainerFactory
            .makeInMemoryContentFavoriteContainer()
        let context = ModelContext(container)

        _ = try PortableV12RecordAdapter.insert(
            fixture.document,
            into: context,
            deviceObservationDate: fixture.fixedDate
        )
        try context.save()
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            ),
            44
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<ContentFavoriteRecord>()
            ),
            0
        )
    }

    func testInMemoryInsertionCoversAll44RevisionedModelsAnd9Controls()
        throws {
        let fixture = try PortableV12Fixture.make()
        let container =
            try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        let context = ModelContext(container)
        let observationDate = fixture.fixedDate

        let result = try PortableV12RecordAdapter.insert(
            fixture.document,
            into: context,
            deviceObservationDate: observationDate
        )
        try context.save()

        XCTAssertEqual(
            result.recordModelTypes,
            Set(
                PortableDataV2RecordSchema
                    .fieldsByModelType.keys
            )
        )
        XCTAssertEqual(
            result.controlModelTypes,
            Set(
                PortableDataV2ControlSchema.contracts.keys
            )
        )
        XCTAssertEqual(result.insertedRecordCount, 44)
        XCTAssertEqual(result.insertedRevisionCount, 44)
        XCTAssertEqual(result.insertedControlCount, 9)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            ),
            44
        )
        for modelType in result.recordModelTypes {
            XCTAssertEqual(
                try revisionedModelCount(
                    modelType,
                    in: context
                ),
                1,
                modelType
            )
        }

        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        let headers = Dictionary(
            uniqueKeysWithValues:
                fixture.document.payload.records.map {
                    ($0.recordKey, $0)
                }
        )
        for revision in revisions {
            let header = try XCTUnwrap(
                headers[revision.recordKey]
            )
            XCTAssertEqual(revision.recordType, header.recordType)
            XCTAssertEqual(revision.recordID, header.recordID)
            XCTAssertEqual(revision.datasetID, header.datasetID)
            XCTAssertEqual(
                revision.localRevision,
                header.localRevision
            )
            XCTAssertEqual(
                revision.digestVersion,
                header.digestVersion
            )
            XCTAssertEqual(revision.digestHex, header.digestHex)
            XCTAssertEqual(
                try RecordDigestV1.timestampMicroseconds(
                    revision.committedAt
                ),
                header.committedAtMicroseconds
            )
        }

        let metadataRows: [DatasetMetadata] = try context.fetch(
            FetchDescriptor<DatasetMetadata>()
        )
        XCTAssertEqual(metadataRows.count, 1)
        let metadata = try XCTUnwrap(metadataRows.first)
        XCTAssertEqual(
            metadata.datasetID,
            fixture.document.payload.datasetID
        )
        XCTAssertEqual(
            metadata.nextLocalRevision,
            fixture.document.payload.nextLocalRevision
        )
        let coverageRows: [NotificationCoverageRecord] =
            try context.fetch(
                FetchDescriptor<NotificationCoverageRecord>()
            )
        XCTAssertEqual(coverageRows.count, 1)
        let coverage = try XCTUnwrap(coverageRows.first)
        XCTAssertEqual(
            coverage.status,
            NotificationCoverageStatus.staleObservation
        )
        XCTAssertEqual(coverage.desiredCount, 0)
        XCTAssertEqual(coverage.confirmedPendingCount, 0)
        XCTAssertNil(coverage.scheduledThrough)
        XCTAssertNil(coverage.lastErrorCode)
        XCTAssertEqual(coverage.observedAt, observationDate)
        let countdownCoverageRows:
            [CountdownNotificationCoverageRecord] =
            try context.fetch(
                FetchDescriptor<
                    CountdownNotificationCoverageRecord
                >()
            )
        XCTAssertEqual(countdownCoverageRows.count, 1)
        let countdownCoverage = try XCTUnwrap(
            countdownCoverageRows.first
        )
        XCTAssertEqual(
            countdownCoverage.status,
            NotificationCoverageStatus.staleObservation
        )
        XCTAssertEqual(countdownCoverage.desiredCount, 0)
        XCTAssertEqual(
            countdownCoverage.confirmedPendingCount,
            0
        )
        XCTAssertNil(countdownCoverage.scheduledFireAt)
        XCTAssertNil(countdownCoverage.lastErrorCode)
        XCTAssertEqual(
            countdownCoverage.observedAt,
            observationDate
        )
        let privacyRows: [PrivacyControlRecord] =
            try context.fetch(
                FetchDescriptor<PrivacyControlRecord>()
            )
        XCTAssertEqual(privacyRows.count, 1)
        let privacy = try XCTUnwrap(privacyRows.first)
        XCTAssertTrue(privacy.appLockEnabled)
    }

    func testRejectsUnknownEnumWithoutFallback() throws {
        let fixture = try PortableV12Fixture.make()
        let original = try XCTUnwrap(
            fixture.document.payload.records.first {
                $0.modelType == "JourneyEntry"
            }
        )
        let fields = original.fields.map { field in
            guard field.name == "kindRawValue" else {
                return field
            }
            return PortableDataField(
                name: field.name,
                value: PortableDataValue(
                    kind: .string,
                    stringValue: "unknown"
                )
            )
        }
        let digest = try RecordDigestV1.sha256Hex(
            recordType: original.recordType,
            recordID: original.recordID,
            fields: try fields.map {
                RecordDigestV1.Field(
                    $0.name,
                    try $0.value.recordDigestValue()
                )
            }
        )
        let mutatedRecord = PortableDataRecord(
            modelType: original.modelType,
            recordType: original.recordType,
            recordID: original.recordID,
            recordKey: original.recordKey,
            datasetID: original.datasetID,
            localRevision: original.localRevision,
            committedAtMicroseconds:
                original.committedAtMicroseconds,
            digestVersion: original.digestVersion,
            digestHex: digest,
            fields: fields
        )
        let records = fixture.document.payload.records.map {
            $0.recordKey == original.recordKey
                ? mutatedRecord
                : $0
        }
        let payload = PortableDataV2Payload(
            schemaVersion:
                PortableDataSchemaContract.v12.schemaVersion,
            datasetID: fixture.document.payload.datasetID,
            sourceGenerationID:
                fixture.document.payload.sourceGenerationID,
            capturedAtMicroseconds:
                fixture.document.payload.capturedAtMicroseconds,
            nextLocalRevision:
                fixture.document.payload.nextLocalRevision,
            modelCounts:
                fixture.document.payload.modelCounts,
            records: records,
            controls: fixture.document.payload.controls,
            activeAttachments: []
        )
        let mutated = try PortableDataV2Codec.makeDocument(
            payload: payload
        )
        let context = ModelContext(
            try AppModelContainerFactory
                .makeInMemoryDataControlContainer()
        )

        XCTAssertThrowsError(
            try PortableV12RecordAdapter.insert(
                mutated,
                into: context,
                deviceObservationDate: fixture.fixedDate
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableV12RecordAdapterError,
                .invalidEnum("kindRawValue")
            )
        }
    }

    func testRestoreSemanticPreflightRejectsUnknownEnumBeforeJournal()
        throws {
        let fixture = try PortableV12Fixture.make()
        let original = try XCTUnwrap(
            fixture.document.payload.records.first {
                $0.modelType == "JourneyEntry"
            }
        )
        let fields = original.fields.map { field in
            guard field.name == "kindRawValue" else {
                return field
            }
            return PortableDataField(
                name: field.name,
                value: PortableDataValue(
                    kind: .string,
                    stringValue: "unknown-preflight"
                )
            )
        }
        let digest = try RecordDigestV1.sha256Hex(
            recordType: original.recordType,
            recordID: original.recordID,
            fields: try fields.map {
                RecordDigestV1.Field(
                    $0.name,
                    try $0.value.recordDigestValue()
                )
            }
        )
        let replacement = PortableDataRecord(
            modelType: original.modelType,
            recordType: original.recordType,
            recordID: original.recordID,
            recordKey: original.recordKey,
            datasetID: original.datasetID,
            localRevision: original.localRevision,
            committedAtMicroseconds:
                original.committedAtMicroseconds,
            digestVersion: original.digestVersion,
            digestHex: digest,
            fields: fields
        )
        let payload = PortableDataV2Payload(
            schemaVersion:
                PortableDataSchemaContract.v12.schemaVersion,
            datasetID: fixture.document.payload.datasetID,
            sourceGenerationID:
                fixture.document.payload.sourceGenerationID,
            capturedAtMicroseconds:
                fixture.document.payload.capturedAtMicroseconds,
            nextLocalRevision:
                fixture.document.payload.nextLocalRevision,
            modelCounts:
                fixture.document.payload.modelCounts,
            records: fixture.document.payload.records.map {
                $0.recordKey == original.recordKey
                    ? replacement : $0
            },
            controls: fixture.document.payload.controls,
            activeAttachments: []
        )
        let document = try PortableDataV2Codec
            .makeDocument(payload: payload)
        let root = FileManager.default.temporaryDirectory
            .appending(
                path:
                    "PortableSemanticPreflight-"
                    + UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(
            path: "invalid.unmanualbackup",
            directoryHint: .isDirectory
        )
        let audited = try PortableBackupPackageBuilder
            .build(
                document: document,
                destinationURL: packageURL
            ) { _, _ in
                XCTFail("No attachment copy expected")
            }
        let layout = AppDataStoreLayout(
            rootURL: root.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            ),
            legacyStoreURL:
                root.appending(path: "legacy.sqlite")
        )

        XCTAssertThrowsError(
            try PortableRestorePreparationService
                .semanticPreflight(
                    audited,
                    layout: layout,
                    deviceObservationDate:
                        fixture.fixedDate
                )
        ) {
            XCTAssertEqual(
                $0 as? PortableV12RecordAdapterError,
                .invalidEnum("kindRawValue")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    layout.portableRestoreJournalURL
                        .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    layout.portableRestoreStagingRootURL
                        .path
            )
        )
    }

    private func revisionedModelCount(
        _ modelType: String,
        in context: ModelContext
    ) throws -> Int {
        switch modelType {
        case "AdministrationEventRecord":
            return try context.fetchCount(
                FetchDescriptor<AdministrationEventRecord>()
            )
        case "AttachmentRecord":
            return try context.fetchCount(
                FetchDescriptor<AttachmentRecord>()
            )
        case "CountdownCommandAuditRecord":
            return try context.fetchCount(
                FetchDescriptor<CountdownCommandAuditRecord>()
            )
        case "CountdownIntegrityBackfillState":
            return try context.fetchCount(
                FetchDescriptor<CountdownIntegrityBackfillState>()
            )
        case "CountdownLifecycleEventRecord":
            return try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            )
        case "CountdownRecord":
            return try context.fetchCount(
                FetchDescriptor<CountdownRecord>()
            )
        case "CountdownReminderRuleRecord":
            return try context.fetchCount(
                FetchDescriptor<CountdownReminderRuleRecord>()
            )
        case "CountdownStateRecord":
            return try context.fetchCount(
                FetchDescriptor<CountdownStateRecord>()
            )
        case "CountdownV6AuditCheckpointRecord":
            return try context.fetchCount(
                FetchDescriptor<CountdownV6AuditCheckpointRecord>()
            )
        case "DataControlBackfillState":
            return try context.fetchCount(
                FetchDescriptor<DataControlBackfillState>()
            )
        case "DataControlDeletionTombstoneRecord":
            return try context.fetchCount(
                FetchDescriptor<
                    DataControlDeletionTombstoneRecord
                >()
            )
        case "HistoricalTimeRecord":
            return try context.fetchCount(
                FetchDescriptor<HistoricalTimeRecord>()
            )
        case "HRTProfile":
            return try context.fetchCount(
                FetchDescriptor<HRTProfile>()
            )
        case "HrtJourneyLifecycleBackfillState":
            return try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleBackfillState>()
            )
        case "HrtJourneyLifecycleEventRecord":
            return try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            )
        case "HrtJourneyProfileRecord":
            return try context.fetchCount(
                FetchDescriptor<HrtJourneyProfileRecord>()
            )
        case "HrtPeriodRecord":
            return try context.fetchCount(
                FetchDescriptor<HrtPeriodRecord>()
            )
        case "JourneyEntry":
            return try context.fetchCount(
                FetchDescriptor<JourneyEntry>()
            )
        case "LabItemDefinitionRecord":
            return try context.fetchCount(
                FetchDescriptor<LabItemDefinitionRecord>()
            )
        case "LabRecord":
            return try context.fetchCount(
                FetchDescriptor<LabRecord>()
            )
        case "LabResultCorrectionSnapshotRecord":
            return try context.fetchCount(
                FetchDescriptor<
                    LabResultCorrectionSnapshotRecord
                >()
            )
        case "LabResultRecord":
            return try context.fetchCount(
                FetchDescriptor<LabResultRecord>()
            )
        case "LabSampleCorrectionSnapshotRecord":
            return try context.fetchCount(
                FetchDescriptor<
                    LabSampleCorrectionSnapshotRecord
                >()
            )
        case "LabSampleRecord":
            return try context.fetchCount(
                FetchDescriptor<LabSampleRecord>()
            )
        case "OnboardingBackfillState":
            return try context.fetchCount(
                FetchDescriptor<OnboardingBackfillState>()
            )
        case "OnboardingProgressRecord":
            return try context.fetchCount(
                FetchDescriptor<OnboardingProgressRecord>()
            )
        case "OperationReceiptLedgerRecord":
            return try context.fetchCount(
                FetchDescriptor<OperationReceiptLedgerRecord>()
            )
        case "OperationReceiptRecord":
            return try context.fetchCount(
                FetchDescriptor<OperationReceiptRecord>()
            )
        case "ParentRecordDeletionTombstoneRecord":
            return try context.fetchCount(
                FetchDescriptor<
                    ParentRecordDeletionTombstoneRecord
                >()
            )
        case "ParentRecordLifecycleBackfillState":
            return try context.fetchCount(
                FetchDescriptor<
                    ParentRecordLifecycleBackfillState
                >()
            )
        case "ParentRecordLifecycleHeadRecord":
            return try context.fetchCount(
                FetchDescriptor<
                    ParentRecordLifecycleHeadRecord
                >()
            )
        case "ParentRecordMutationEventRecord":
            return try context.fetchCount(
                FetchDescriptor<
                    ParentRecordMutationEventRecord
                >()
            )
        case "PrivacyControlBackfillState":
            return try context.fetchCount(
                FetchDescriptor<PrivacyControlBackfillState>()
            )
        case "PrivacyControlRecord":
            return try context.fetchCount(
                FetchDescriptor<PrivacyControlRecord>()
            )
        case "RegimenItemRecord":
            return try context.fetchCount(
                FetchDescriptor<RegimenItemRecord>()
            )
        case "RegimenPlanVersionRecord":
            return try context.fetchCount(
                FetchDescriptor<RegimenPlanVersionRecord>()
            )
        case "RegimenVersion":
            return try context.fetchCount(
                FetchDescriptor<RegimenVersion>()
            )
        case "ReminderOverrideRecord":
            return try context.fetchCount(
                FetchDescriptor<ReminderOverrideRecord>()
            )
        case "ReminderPreferenceRecord":
            return try context.fetchCount(
                FetchDescriptor<ReminderPreferenceRecord>()
            )
        case "ScheduleRuleRecord":
            return try context.fetchCount(
                FetchDescriptor<ScheduleRuleRecord>()
            )
        case "StatusMetricDefinitionRecord":
            return try context.fetchCount(
                FetchDescriptor<StatusMetricDefinitionRecord>()
            )
        case "StatusObservationCorrectionSnapshotRecord":
            return try context.fetchCount(
                FetchDescriptor<
                    StatusObservationCorrectionSnapshotRecord
                >()
            )
        case "StatusObservationRecord":
            return try context.fetchCount(
                FetchDescriptor<StatusObservationRecord>()
            )
        case "UserPreferencesRecord":
            return try context.fetchCount(
                FetchDescriptor<UserPreferencesRecord>()
            )
        default:
            XCTFail("Missing count assertion for \(modelType)")
            return -1
        }
    }
}

private struct PortableV12Fixture {
    let document: PortableDataV2Document
    let fixedDate: Date

    static func make() throws -> PortableV12Fixture {
        let fixedDate = Date(
            timeIntervalSince1970: 1_767_326_645
        )
        let microseconds =
            try RecordDigestV1.timestampMicroseconds(fixedDate)
        let datasetID = id("dataset")
        let sourceGenerationID = id("generation")
        let types = PortableDataV2RecordSchema
            .fieldsByModelType.keys.sorted()
        var records: [PortableDataRecord] = []
        for (index, modelType) in types.enumerated() {
            records.append(
                try record(
                    modelType: modelType,
                    datasetID: datasetID,
                    localRevision: Int64(index + 1),
                    microseconds: microseconds
                )
            )
        }
        let controls = try PortableDataV2ControlSchema
            .contracts.keys.sorted().map {
                try control(
                    modelType: $0,
                    datasetID: datasetID,
                    nextLocalRevision: 45,
                    microseconds: microseconds
                )
            }
        let counts = PortableDataSchemaContract.v12
            .modelNames.sorted().map { modelType in
                PortableDataModelCount(
                    modelType: modelType,
                    rowCount: modelType == "RecordRevision"
                        ? 44
                        : 1
                )
            }
        let payload = PortableDataV2Payload(
            schemaVersion:
                PortableDataSchemaContract.v12.schemaVersion,
            datasetID: datasetID,
            sourceGenerationID: sourceGenerationID,
            capturedAtMicroseconds: microseconds,
            nextLocalRevision: 45,
            modelCounts: counts,
            records: records,
            controls: controls,
            activeAttachments: []
        )
        return PortableV12Fixture(
            document: try PortableDataV2Codec.makeDocument(
                payload: payload
            ),
            fixedDate: fixedDate
        )
    }

    private static func record(
        modelType: String,
        datasetID: UUID,
        localRevision: Int64,
        microseconds: Int64
    ) throws -> PortableDataRecord {
        let contracts = try XCTUnwrap(
            PortableDataV2RecordSchema
                .fieldsByModelType[modelType]
        )
        var fields = contracts.map {
            PortableDataField(
                name: $0.name,
                value: value(
                    modelType: modelType,
                    field: $0,
                    microseconds: microseconds
                )
            )
        }
        fields = try canonicalizedFields(
            modelType: modelType,
            fields: fields
        )
        let recordID = try identity(
            modelType: modelType,
            fields: fields
        )
        if modelType == "CountdownCommandAuditRecord" {
            fields = try sealedAuditFields(
                fields,
                recordID: recordID
            )
        } else if modelType
                    == "CountdownV6AuditCheckpointRecord" {
            fields = try sealedCheckpointFields(
                fields,
                recordID: recordID
            )
        }
        let digest = try RecordDigestV1.sha256Hex(
            recordType: modelType,
            recordID: recordID,
            fields: try fields.map {
                RecordDigestV1.Field(
                    $0.name,
                    try $0.value.recordDigestValue()
                )
            }
        )
        return PortableDataRecord(
            modelType: modelType,
            recordType: modelType,
            recordID: recordID,
            recordKey: modelType + ":"
                + recordID.uuidString.lowercased(),
            datasetID: datasetID,
            localRevision: localRevision,
            committedAtMicroseconds: microseconds,
            digestVersion: RecordDigestV1.version,
            digestHex: digest,
            fields: fields
        )
    }

    private static func canonicalizedFields(
        modelType: String,
        fields: [PortableDataField]
    ) throws -> [PortableDataField] {
        func uuid(_ name: String) throws -> UUID {
            try XCTUnwrap(
                fields.first { $0.name == name }?
                    .value.uuidValue,
                "\(modelType).\(name)"
            )
        }
        func integer(_ name: String) throws -> Int {
            try Int(
                XCTUnwrap(
                    fields.first { $0.name == name }?
                        .value.integerValue,
                    "\(modelType).\(name)"
                )
            )
        }
        let replacements: [String: PortableDataValue]
        switch modelType {
        case "CountdownReminderRuleRecord":
            replacements = [
                "ruleKey": PortableDataValue(
                    kind: .string,
                    stringValue:
                        CountdownReminderRuleRecord.key(
                            countdownID:
                                try uuid("countdownID")
                        )
                )
            ]
        case "ReminderPreferenceRecord":
            replacements = [
                "preferenceKey": PortableDataValue(
                    kind: .string,
                    stringValue:
                        ReminderPreferenceRecord.key(
                            scheduleRuleID:
                                try uuid("scheduleRuleID"),
                            revision:
                                try integer(
                                    "expectedRuleRevision"
                                )
                        )
                )
            ]
        case "ParentRecordLifecycleHeadRecord",
             "ParentRecordDeletionTombstoneRecord":
            let parentType =
                try XCTUnwrap(
                    ParentRecordType(
                        rawValue: try XCTUnwrap(
                            fields.first {
                                $0.name == "parentType"
                            }?.value.stringValue
                        )
                    )
                )
            replacements = [
                "parentKey": PortableDataValue(
                    kind: .string,
                    stringValue:
                        parentType.recordKey(
                            parentID: try uuid("parentID")
                        )
                )
            ]
        default:
            replacements = [:]
        }
        return fields.map {
            guard let replacement =
                    replacements[$0.name] else {
                return $0
            }
            return PortableDataField(
                name: $0.name,
                value: replacement
            )
        }.sorted {
            $0.name < $1.name
        }
    }

    private static func control(
        modelType: String,
        datasetID: UUID,
        nextLocalRevision: Int64,
        microseconds: Int64
    ) throws -> PortableDataControl {
        let contract = try XCTUnwrap(
            PortableDataV2ControlSchema.contracts[modelType]
        )
        let fields = contract.fields.map { field in
            PortableDataField(
                name: field.name,
                value: controlValue(
                    modelType: modelType,
                    field: field,
                    datasetID: datasetID,
                    nextLocalRevision: nextLocalRevision,
                    microseconds: microseconds
                )
            )
        }.sorted {
            $0.name < $1.name
        }
        let identity = try XCTUnwrap(
            fields.first {
                $0.name == contract.identityField
            }?.value.stringValue
        )
        return PortableDataControl(
            modelType: modelType,
            stableIdentity: identity,
            disposition: contract.disposition,
            fields: fields
        )
    }

    private static func value(
        modelType: String,
        field: PortableDataRecordFieldContract,
        microseconds: Int64
    ) -> PortableDataValue {
        if field.allowsNull {
            return PortableDataValue(kind: .null)
        }
        switch field.kind {
        case .null:
            return PortableDataValue(kind: .null)
        case .bool:
            return PortableDataValue(
                kind: .bool,
                boolValue:
                    modelType == "PrivacyControlRecord"
                        && field.name == "appLockEnabled"
            )
        case .integer:
            return PortableDataValue(
                kind: .integer,
                integerValue: integerValue(for: field.name)
            )
        case .double:
            return PortableDataValue(
                RecordDigestV1.Value.double(1.25)
            )
        case .string:
            return PortableDataValue(
                kind: .string,
                stringValue: stringValue(
                    modelType: modelType,
                    field: field.name
                )
            )
        case .uuid:
            return PortableDataValue(
                kind: .uuid,
                uuidValue: id(modelType + "." + field.name)
            )
        case .timestampMicroseconds:
            return PortableDataValue(
                kind: .timestampMicroseconds,
                integerValue: microseconds
            )
        }
    }

    private static func controlValue(
        modelType: String,
        field: PortableDataRecordFieldContract,
        datasetID: UUID,
        nextLocalRevision: Int64,
        microseconds: Int64
    ) -> PortableDataValue {
        if field.allowsNull {
            return PortableDataValue(kind: .null)
        }
        if field.name == "datasetID" {
            return PortableDataValue(
                kind: .uuid,
                uuidValue: datasetID
            )
        }
        if field.name == "nextLocalRevision" {
            return PortableDataValue(
                kind: .integer,
                integerValue: nextLocalRevision
            )
        }
        if field.name == "digestVersion" {
            return PortableDataValue(
                kind: .integer,
                integerValue: Int64(RecordDigestV1.version)
            )
        }
        return value(
            modelType: modelType,
            field: field,
            microseconds: microseconds
        )
    }

    private static func integerValue(for field: String) -> Int64 {
        if field.localizedCaseInsensitiveContains("year") {
            return 2026
        }
        if field.localizedCaseInsensitiveContains("month") {
            return 1
        }
        if field.localizedCaseInsensitiveContains("day") {
            return field.localizedCaseInsensitiveContains("lead")
                ? 0 : 2
        }
        if field.localizedCaseInsensitiveContains("hour") {
            return 4
        }
        if field.localizedCaseInsensitiveContains("minute") {
            return 4
        }
        if field.localizedCaseInsensitiveContains("offset") {
            return 0
        }
        if field.localizedCaseInsensitiveContains("nanosecond") {
            return 0
        }
        if field.localizedCaseInsensitiveContains("second") {
            return 5
        }
        if field == "eventCount"
            || field.localizedCaseInsensitiveContains("revision")
            || field == "contractVersion" {
            return 1
        }
        return 0
    }

    private static func stringValue(
        modelType: String,
        field: String
    ) -> String {
        return switch (modelType, field) {
        case ("DatasetMetadata", "singletonKey"):
            DatasetMetadata.fixedKey
        case ("MigrationBackfillState", "taskKey"):
            MigrationBackfillState.fixedKey
        case ("MigrationBackfillState", "phaseRawValue"):
            MigrationBackfillPhase.complete.rawValue
        case ("MigrationIssue", "kindRawValue"):
            MigrationIssueKind.implausibleTimestamp.rawValue
        case ("CoreTimeRegimenBackfillState", "taskKey"):
            CoreTimeRegimenBackfillState.fixedKey
        case ("TodayExecutionBackfillState", "taskKey"):
            TodayExecutionBackfillState.fixedKey
        case ("PersonalTimelineBackfillState", "taskKey"):
            PersonalTimelineBackfillState.fixedKey
        case ("CountdownLifecycleBackfillState", "taskKey"):
            CountdownLifecycleBackfillState.fixedKey
        case ("NotificationCoverageRecord", "coverageKey"):
            NotificationCoverageRecord.fixedKey
        case ("CountdownNotificationCoverageRecord", "coverageKey"):
            CountdownNotificationCoverageRecord.fixedKey
        case ("NotificationCoverageRecord", "statusRawValue"),
             (
                 "CountdownNotificationCoverageRecord",
                 "statusRawValue"
             ):
            NotificationCoverageStatus.staleObservation.rawValue
        case ("UserPreferencesRecord", "singletonKey"):
            UserPreferencesRecord.fixedKey
        case ("OnboardingProgressRecord", "singletonKey"):
            OnboardingProgressRecord.fixedKey
        case ("PrivacyControlRecord", "singletonKey"):
            PrivacyControlRecord.fixedKey
        case ("OperationReceiptLedgerRecord", "ledgerKey"):
            OperationReceiptLedgerRecord.fixedKey
        case ("CountdownIntegrityBackfillState", "taskKey"):
            CountdownIntegrityBackfillState.fixedKey
        case ("OnboardingBackfillState", "taskKey"):
            OnboardingBackfillState.fixedKey
        case ("HrtJourneyLifecycleBackfillState", "taskKey"):
            HrtJourneyLifecycleBackfillState.fixedKey
        case ("ParentRecordLifecycleBackfillState", "taskKey"):
            ParentRecordLifecycleBackfillState.fixedKey
        case ("PrivacyControlBackfillState", "taskKey"):
            PrivacyControlBackfillState.fixedKey
        case ("DataControlBackfillState", "taskKey"):
            DataControlBackfillState.fixedKey
        case ("JourneyEntry", "kindRawValue"):
            JourneyEntryKind.moment.rawValue
        case ("AdministrationEventRecord", "status"):
            AdministrationStatus.taken.rawValue
        case ("LabItemDefinitionRecord", "kind"):
            LabItemDefinitionKind.custom.rawValue
        case ("ScheduleRuleRecord", "kind"):
            ScheduleRuleKind.dailyTimes.rawValue
        case ("ScheduleRuleRecord", "timeZoneBehavior"):
            ScheduleTimeZoneBehavior.floatingLocal.rawValue
        case ("CountdownLifecycleEventRecord", "kind"):
            CountdownLifecycleEventKind.created.rawValue
        case ("CountdownReminderRuleRecord", "timeZoneBehavior"):
            CountdownReminderTimeZoneBehavior
                .floatingLocalV1.rawValue
        case ("CountdownStateRecord", "lifecycle"):
            CountdownLifecycle.active.rawValue
        case ("CountdownStateRecord", "overdueMode"):
            CountdownOverdueMode.awaitingDecision.rawValue
        case ("CountdownCommandAuditRecord", "commandKind"):
            CountdownCommandAuditKind.create.rawValue
        case ("CountdownCommandAuditRecord", "auditSource"):
            CountdownCommandAuditSource.nativeV7.rawValue
        case ("CountdownCommandAuditRecord", "commandDigestVersion"):
            CountdownIntegrityDigest.commandVersion
        case ("CountdownV6AuditCheckpointRecord", "reminderAdmission"):
            CountdownReminderAdmission.disabledAtUpgrade.rawValue
        case ("OnboardingProgressRecord", "step"):
            OnboardingStep.privacy.rawValue
        case ("OnboardingBackfillState", "source"):
            OnboardingBackfillSource.newInstallV8.rawValue
        case ("HrtJourneyLifecycleEventRecord", "kind"):
            HrtJourneyLifecycleEventKind.started.rawValue
        case ("HrtJourneyLifecycleEventRecord", "source"):
            HrtJourneyLifecycleEventSource.user.rawValue
        case ("ParentRecordLifecycleHeadRecord", "parentType"),
             ("ParentRecordMutationEventRecord", "parentType"),
             ("ParentRecordDeletionTombstoneRecord", "parentType"):
            ParentRecordType.labSample.rawValue
        case ("ParentRecordLifecycleHeadRecord", "lifecycle"):
            ParentRecordLifecycle.active.rawValue
        case ("ParentRecordMutationEventRecord", "kind"):
            ParentRecordMutationEventKind.createdSnapshot.rawValue
        case ("PrivacyControlBackfillState", "source"):
            PrivacyControlBackfillSource.bootstrapV11.rawValue
        case ("DataControlBackfillState", "source"):
            DataControlBackfillSource.bootstrapV12.rawValue
        case ("DataControlDeletionTombstoneRecord", "targetKindRawValue"):
            DataControlTargetKind.hrtJourney.rawValue
        case ("DataControlDeletionTombstoneRecord", "targetStableKey"):
            "primary-hrt-journey"
        case ("DataControlDeletionTombstoneRecord", "targetKey"):
            "hrtJourney:primary-hrt-journey"
        case ("HistoricalTimeRecord", "associationState"),
             ("LabSampleCorrectionSnapshotRecord", "associationState"),
             ("StatusObservationCorrectionSnapshotRecord", "associationState"):
            HistoricalAssociationState.resolved.rawValue
        case (_, "precision"), (_, "precisionRawValue"),
             (_, "effectivePrecision"):
            HistoricalTimestampPrecision.second.rawValue
        case (_, "provenance"), (_, "provenanceRawValue"),
             (_, "effectiveProvenance"):
            HistoricalTimestampProvenance.captured.rawValue
        case (_, "timeZoneIdentifier"), (_, "timeZone"),
             (_, "assumedTimeZoneIdentifier"),
             (_, "effectiveTimeZone"):
            "UTC"
        case (_, "localDate"), (_, "effectiveLocalDate"):
            "2026-01-02"
        case ("RegimenPlanVersionRecord", "editState"):
            RegimenEditState.draft.rawValue
        case ("AttachmentRecord", "ownerType"):
            AttachmentOwnerType.journeyEntry.rawValue
        case ("HistoricalTimeRecord", "sourceRecordType"):
            "JourneyEntry"
        default:
            field == "digestHex"
                || field.localizedCaseInsensitiveContains("digest")
                ? String(repeating: "0", count: 64)
                : modelType + "." + field
        }
    }

    private static func identity(
        modelType: String,
        fields: [PortableDataField]
    ) throws -> UUID {
        func string(_ name: String) throws -> String {
            try XCTUnwrap(
                fields.first { $0.name == name }?
                    .value.stringValue,
                "\(modelType).\(name)"
            )
        }
        func uuid(_ name: String) throws -> UUID {
            try XCTUnwrap(
                fields.first { $0.name == name }?
                    .value.uuidValue,
                "\(modelType).\(name)"
            )
        }
        switch modelType {
        case "OnboardingProgressRecord":
            let key = try string("singletonKey")
            return CoreTimeRegimenBackfill
                .stableUUID(for: key)
        case "UserPreferencesRecord":
            return CoreTimeRegimenBackfill.stableUUID(
                for: UserPreferencesRecord.fixedKey
            )
        case "CountdownIntegrityBackfillState",
             "OnboardingBackfillState",
             "ParentRecordLifecycleBackfillState":
            let key = try string("taskKey")
            return CoreTimeRegimenBackfill
                .stableUUID(for: key)
        case "HrtJourneyProfileRecord":
            return CoreTimeRegimenBackfill.stableUUID(
                for: HrtJourneyProfileRecord.fixedKey
            )
        case "HrtJourneyLifecycleBackfillState":
            return CoreTimeRegimenBackfill.stableUUID(
                for:
                    HrtJourneyLifecycleBackfillState.fixedKey
            )
        case "HistoricalTimeRecord":
            return CoreTimeRegimenBackfill.stableUUID(
                for: try string("sourceRecordType") + ":"
                    + uuid("sourceRecordID").uuidString
                    .lowercased()
            )
        case "OperationReceiptRecord":
            return try uuid("operationID")
        case "OperationReceiptLedgerRecord":
            return TodayExecutionDigestV1.receiptLedgerID
        case "CountdownCommandAuditRecord":
            return id("countdown-lifecycle-event")
        case "CountdownLifecycleEventRecord":
            return id("countdown-lifecycle-event")
        case "ParentRecordLifecycleHeadRecord":
            let parentType = ParentRecordType(
                rawValue: try string("parentType")
            )!
            let key = parentType.recordKey(
                parentID: try uuid("parentID")
            )
            return ParentRecordLifecycleBackfill
                .stableHeadID(for: key)
        case "PrivacyControlRecord":
            return PrivacyControlRecord.stableID
        case "PrivacyControlBackfillState":
            return PrivacyControlBackfillState.stableID
        case "DataControlDeletionTombstoneRecord":
            return try uuid("id")
        case "DataControlBackfillState":
            return DataControlBackfillState.stableID
        default:
            return id(modelType + ".record")
        }
    }

    private static func sealedAuditFields(
        _ fields: [PortableDataField],
        recordID: UUID
    ) throws -> [PortableDataField] {
        func value(_ name: String) throws
            -> RecordDigestV1.Value {
            try XCTUnwrap(
                fields.first { $0.name == name }
            ).value.recordDigestValue()
        }
        func string(_ name: String) throws -> String {
            guard case let .string(value) = try value(name) else {
                throw PortableDataV2Error.invalidValue
            }
            return value
        }
        func uuid(_ name: String) throws -> UUID {
            guard case let .uuid(value) = try value(name) else {
                throw PortableDataV2Error.invalidValue
            }
            return value
        }
        func date(_ name: String) throws -> Date {
            guard case let .timestampMicroseconds(value) =
                    try value(name) else {
                throw PortableDataV2Error.invalidValue
            }
            return Date(
                timeIntervalSince1970:
                    TimeInterval(value) / 1_000_000
            )
        }
        let audit = CountdownCommandAuditRecord(
            eventID: recordID,
            operationID: id(
                "CountdownLifecycleEventRecord.operationID"
            ),
            countdownID: try uuid("countdownID"),
            commandKind: .create,
            eventTimestampCommitment:
                try string("eventTimestampCommitment"),
            eventSemanticDigest:
                try string("eventSemanticDigest"),
            preFactsDigest: try string("preFactsDigest"),
            postFactsDigest: try string("postFactsDigest"),
            committedAt: try date("committedAt")
        )
        try audit.seal()
        return fields.map { field in
            switch field.name {
            case "eventID":
                PortableDataField(
                    name: field.name,
                    value: PortableDataValue(
                        kind: .uuid,
                        uuidValue: recordID
                    )
                )
            case "commandDigest":
                PortableDataField(
                    name: field.name,
                    value: PortableDataValue(
                        kind: .string,
                        stringValue: audit.commandDigest
                    )
                )
            case "auditDigest":
                PortableDataField(
                    name: field.name,
                    value: PortableDataValue(
                        kind: .string,
                        stringValue: audit.auditDigest
                    )
                )
            default:
                field
            }
        }
    }

    private static func sealedCheckpointFields(
        _ fields: [PortableDataField],
        recordID: UUID
    ) throws -> [PortableDataField] {
        func field(_ name: String) throws
            -> RecordDigestV1.Value {
            try XCTUnwrap(
                fields.first { $0.name == name }
            ).value.recordDigestValue()
        }
        guard case let .uuid(boundary) =
                try field("boundaryEventID"),
              case let .integer(count) =
                try field("prefixEventCount"),
              case let .string(prefix) =
                try field("prefixChainDigest"),
              case let .string(post) =
                try field("postFactsDigest"),
              case let .timestampMicroseconds(createdAt) =
                try field("createdAt") else {
            throw PortableDataV2Error.invalidValue
        }
        let checkpoint = CountdownV6AuditCheckpointRecord(
            countdownID: recordID,
            boundaryEventID: boundary,
            prefixEventCount: Int(count),
            prefixChainDigest: prefix,
            postFactsDigest: post,
            reminderAdmission: .disabledAtUpgrade,
            createdAt: Date(
                timeIntervalSince1970:
                    TimeInterval(createdAt) / 1_000_000
            )
        )
        try checkpoint.seal()
        return fields.map {
            $0.name == "checkpointDigest"
                ? PortableDataField(
                    name: $0.name,
                    value: PortableDataValue(
                        kind: .string,
                        stringValue:
                            checkpoint.checkpointDigest
                    )
                )
                : $0
        }
    }

    private static func id(_ seed: String) -> UUID {
        CoreTimeRegimenBackfill.stableUUID(
            for: "portable-v12-fixture:" + seed
        )
    }
}
