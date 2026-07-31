import Foundation
import SwiftData

enum PrivacyControlBackfillSource: String, Codable, Sendable {
    case bootstrapV11
    case schemaUpgradeV10
}

@Model
final class PrivacyControlRecord {
    static let fixedKey = "primary-privacy-control"
    static let contractVersion = 1
    static let stableID = CoreTimeRegimenBackfill.stableUUID(for: fixedKey)

    @Attribute(.unique) var singletonKey: String
    var contractVersion: Int
    var appLockEnabled: Bool
    var lastOperationID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        singletonKey: String = PrivacyControlRecord.fixedKey,
        contractVersion: Int = PrivacyControlRecord.contractVersion,
        appLockEnabled: Bool = false,
        lastOperationID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.singletonKey = singletonKey
        self.contractVersion = contractVersion
        self.appLockEnabled = appLockEnabled
        self.lastOperationID = lastOperationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class PrivacyControlBackfillState {
    static let fixedKey = "v10-to-v11-privacy-control"
    static let stableID = CoreTimeRegimenBackfill.stableUUID(for: fixedKey)

    @Attribute(.unique) var taskKey: String
    var sourceRawValue: String
    var initialPrivacyDigest: String
    var completedAt: Date?
    var updatedAt: Date

    var source: PrivacyControlBackfillSource? {
        PrivacyControlBackfillSource(rawValue: sourceRawValue)
    }

    init(
        taskKey: String = PrivacyControlBackfillState.fixedKey,
        source: PrivacyControlBackfillSource,
        initialPrivacyDigest: String,
        completedAt: Date?,
        updatedAt: Date
    ) {
        self.taskKey = taskKey
        self.sourceRawValue = source.rawValue
        self.initialPrivacyDigest = initialPrivacyDigest
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

struct PrivacyControlSnapshot: Equatable, Sendable {
    let appLockEnabled: Bool
    let localRevision: Int64
    let digestHex: String
    let lastOperationID: UUID?
    let updatedAt: Date
}

struct SetAppLockCommand: Equatable, Sendable {
    let operationID: UUID
    let expectedLocalRevision: Int64
    let expectedDigestHex: String
    let isEnabled: Bool
    let committedAt: Date

    init(
        operationID: UUID,
        expectedLocalRevision: Int64,
        expectedDigestHex: String,
        isEnabled: Bool,
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.expectedLocalRevision = expectedLocalRevision
        self.expectedDigestHex = expectedDigestHex
        self.isEnabled = isEnabled
        self.committedAt = committedAt
    }
}

struct SetAppLockResult: Equatable, Sendable {
    let snapshot: PrivacyControlSnapshot
    let didApply: Bool
}

enum PrivacyControlWriteFailure: Error, Equatable, Sendable {
    case invalidInput
    case staleRecord
    case operationConflict
    case corruptionSuspected
}

enum PrivacyControlDigestV1 {
    static func record(
        _ value: PrivacyControlRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("appLockEnabled", .bool(value.appLockEnabled)),
            .init(
                "contractVersion",
                .integer(Int64(value.contractVersion))
            ),
            .init(
                "createdAt",
                try RecordDigestV1.timestampValue(value.createdAt)
            ),
            .init(
                "lastOperationID",
                value.lastOperationID.map(RecordDigestV1.Value.uuid) ?? .null
            ),
            .init("singletonKey", .string(value.singletonKey)),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(value.updatedAt)
            )
        ]
    }

    static func backfillState(
        _ value: PrivacyControlBackfillState
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "completedAt",
                try value.completedAt.map(RecordDigestV1.timestampValue)
                    ?? .null
            ),
            .init(
                "initialPrivacyDigest",
                .string(value.initialPrivacyDigest)
            ),
            .init("source", .string(value.sourceRawValue)),
            .init("taskKey", .string(value.taskKey)),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(value.updatedAt)
            )
        ]
    }

    static func initialRecordDigest(createdAt: Date) throws -> String {
        let initial = PrivacyControlRecord(
            appLockEnabled: false,
            lastOperationID: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        return try RecordDigestV1.sha256Hex(
            recordType: "PrivacyControlRecord",
            recordID: PrivacyControlRecord.stableID,
            fields: try record(initial)
        )
    }

    static func setAppLockCommand(
        _ command: SetAppLockCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "SetAppLockCommand",
            recordID: command.operationID,
            fields: [
                .init(
                    "committedAt",
                    try RecordDigestV1.timestampValue(command.committedAt)
                ),
                .init(
                    "expectedDigestHex",
                    .string(command.expectedDigestHex)
                ),
                .init(
                    "expectedLocalRevision",
                    .integer(command.expectedLocalRevision)
                ),
                .init("isEnabled", .bool(command.isEnabled)),
                .init("operationID", .uuid(command.operationID)),
                .init(
                    "recordKey",
                    .string(
                        "PrivacyControlRecord:"
                            + PrivacyControlRecord.stableID.uuidString
                                .lowercased()
                    )
                )
            ]
        )
    }
}

struct ValidatedOperationReceiptSet {
    let receiptsByOperationID: [UUID: OperationReceiptRecord]
    let revisionsByOperationID: [UUID: RecordRevision]
    let ledger: OperationReceiptLedgerRecord?
    let ledgerRevision: RecordRevision?
}

enum OperationReceiptLedgerIntegrityValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> ValidatedOperationReceiptSet {
        var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>()
        receiptDescriptor.fetchLimit = 65_537
        let receipts = try context.fetch(receiptDescriptor)
        guard receipts.count <= 65_536 else {
            throw failure
        }
        let receiptsByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )

        let receiptRecordType = "OperationReceiptRecord"
        var receiptRevisionDescriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordType == receiptRecordType
            }
        )
        receiptRevisionDescriptor.fetchLimit = 65_537
        let receiptRevisions = try context.fetch(
            receiptRevisionDescriptor
        )
        guard receiptRevisions.count <= 65_536 else {
            throw failure
        }
        let revisionsByOperationID = try AppDataIndex.checkedUniqueMap(
            receiptRevisions,
            keyedBy: \.recordID,
            failure: failure
        )

        var ledgerDescriptor =
            FetchDescriptor<OperationReceiptLedgerRecord>()
        ledgerDescriptor.fetchLimit = 2
        let ledgers = try context.fetch(ledgerDescriptor)
        let ledgerRecordKey = "OperationReceiptLedgerRecord:"
            + TodayExecutionDigestV1.receiptLedgerID.uuidString
                .lowercased()
        var ledgerRevisionDescriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordKey == ledgerRecordKey
            }
        )
        ledgerRevisionDescriptor.fetchLimit = 2
        let ledgerRevisions = try context.fetch(
            ledgerRevisionDescriptor
        )

        if receipts.isEmpty,
           receiptRevisions.isEmpty,
           ledgers.isEmpty,
           ledgerRevisions.isEmpty {
            return ValidatedOperationReceiptSet(
                receiptsByOperationID: [:],
                revisionsByOperationID: [:],
                ledger: nil,
                ledgerRevision: nil
            )
        }

        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard receipts.count == receiptRevisions.count,
              ledgers.count == 1,
              ledgerRevisions.count == 1,
              metadataRecords.count == 1,
              let ledger = ledgers.first,
              let ledgerRevision = ledgerRevisions.first,
              let metadata = metadataRecords.first,
              ledger.ledgerKey
                == OperationReceiptLedgerRecord.fixedKey,
              ledger.receiptCount == receipts.count,
              ledger.receiptSetDigest
                == (try TodayExecutionDigestV1.receiptSetDigest(receipts)),
              ledger.updatedAt.timeIntervalSince1970.isFinite,
              ledgerRevision.recordKey == ledgerRecordKey,
              ledgerRevision.recordType
                == "OperationReceiptLedgerRecord",
              ledgerRevision.recordID
                == TodayExecutionDigestV1.receiptLedgerID,
              ledgerRevision.datasetID == metadata.datasetID,
              ledgerRevision.localRevision > 0,
              ledgerRevision.localRevision
                < metadata.nextLocalRevision,
              ledgerRevision.digestVersion == RecordDigestV1.version,
              ledgerRevision.digestHex
                == (try RecordDigestV1.sha256Hex(
                    recordType: "OperationReceiptLedgerRecord",
                    recordID: TodayExecutionDigestV1.receiptLedgerID,
                    fields: TodayExecutionDigestV1
                        .operationReceiptLedger(ledger)
                )),
              ledgerRevision.committedAt == ledger.updatedAt else {
            throw failure
        }

        for receipt in receipts {
            guard receipt.commandDigest.count == 64,
                  receipt.commandDigest.allSatisfy({
                      $0.isHexDigit && !$0.isUppercase
                  }),
                  receipt.committedAt.timeIntervalSince1970.isFinite,
                  let revision =
                    revisionsByOperationID[receipt.operationID],
                  revision.recordKey == "OperationReceiptRecord:"
                    + receipt.operationID.uuidString.lowercased(),
                  revision.recordType == receiptRecordType,
                  revision.recordID == receipt.operationID,
                  revision.datasetID == metadata.datasetID,
                  revision.localRevision > 0,
                  revision.localRevision < metadata.nextLocalRevision,
                  revision.digestVersion == RecordDigestV1.version,
                  revision.digestHex
                    == (try RecordDigestV1.sha256Hex(
                        recordType: receiptRecordType,
                        recordID: receipt.operationID,
                        fields: try TodayExecutionDigestV1
                            .operationReceipt(receipt)
                    )),
                  revision.committedAt >= receipt.committedAt else {
                throw failure
            }
        }
        if let maximumReceiptRevision = receiptRevisions
            .map(\.localRevision)
            .max() {
            guard ledgerRevision.localRevision
                    >= maximumReceiptRevision else {
                throw failure
            }
        }

        return ValidatedOperationReceiptSet(
            receiptsByOperationID: receiptsByOperationID,
            revisionsByOperationID: revisionsByOperationID,
            ledger: ledger,
            ledgerRevision: ledgerRevision
        )
    }
}

enum PrivacyControlRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        let tuple = try records(in: context, failure: failure)
        guard validates(tuple.record),
              validates(tuple.state) else {
            throw failure
        }
        guard let completedAt = tuple.state.completedAt,
              tuple.record.createdAt == completedAt,
              tuple.state.updatedAt == completedAt,
              tuple.state.initialPrivacyDigest
                == (try PrivacyControlDigestV1.initialRecordDigest(
                    createdAt: tuple.record.createdAt
                )) else {
            throw failure
        }
        let privacyRevision = try validateRevision(
            recordType: "PrivacyControlRecord",
            recordID: PrivacyControlRecord.stableID,
            fields: try PrivacyControlDigestV1.record(tuple.record),
            context: context,
            failure: failure
        )
        _ = try validateRevision(
            recordType: "PrivacyControlBackfillState",
            recordID: PrivacyControlBackfillState.stableID,
            fields: try PrivacyControlDigestV1.backfillState(tuple.state),
            context: context,
            failure: failure
        )

        let receiptSet = try OperationReceiptLedgerIntegrityValidator
            .validate(in: context, failure: failure)
        let privacyReceipts = receiptSet.receiptsByOperationID.values
            .filter {
                $0.resultRecordType == "PrivacyControlRecord"
            }
        let privacyReceiptRevisions = try privacyReceipts.map { receipt in
            guard receipt.resultRecordID
                    == PrivacyControlRecord.stableID,
                  receipt.committedAt >= tuple.record.createdAt,
                  receipt.committedAt <= tuple.record.updatedAt,
                  let revision = receiptSet
                    .revisionsByOperationID[receipt.operationID],
                  revision.committedAt == receipt.committedAt,
                  revision.localRevision
                    <= privacyRevision.localRevision else {
                throw failure
            }
            return revision
        }
        guard Set(privacyReceiptRevisions.map(\.localRevision)).count
                == privacyReceiptRevisions.count,
              (tuple.record.lastOperationID == nil)
                == privacyReceipts.isEmpty else {
            throw failure
        }
        if !privacyReceipts.isEmpty {
            guard let ledger = receiptSet.ledger,
                  let ledgerRevision = receiptSet.ledgerRevision,
                  let maximumReceiptRevision = receiptSet
                    .revisionsByOperationID.values
                    .map(\.localRevision)
                    .max(),
                  ledgerRevision.localRevision
                    == maximumReceiptRevision else {
                throw failure
            }
            let receiptsAtLedgerRevision = receiptSet
                .receiptsByOperationID.values.filter { receipt in
                    receiptSet.revisionsByOperationID[
                        receipt.operationID
                    ]?.localRevision == maximumReceiptRevision
                }
            guard !receiptsAtLedgerRevision.isEmpty,
                  receiptsAtLedgerRevision.allSatisfy({
                      $0.committedAt == ledger.updatedAt
                          && receiptSet.revisionsByOperationID[
                              $0.operationID
                          ]?.committedAt == ledger.updatedAt
                  }) else {
                throw failure
            }
        }

        if let operationID = tuple.record.lastOperationID {
            guard let receipt =
                    receiptSet.receiptsByOperationID[operationID],
                  receipt.resultRecordType == "PrivacyControlRecord",
                  receipt.resultRecordID == PrivacyControlRecord.stableID,
                  receipt.committedAt == tuple.record.updatedAt else {
                throw failure
            }
            let receiptKey = recordKey(
                type: "OperationReceiptRecord",
                id: operationID
            )
            guard let receiptRevision = receiptSet
                    .revisionsByOperationID[operationID],
                  receiptRevision.recordKey == receiptKey,
                  privacyRevision.localRevision
                    == receiptRevision.localRevision,
                  privacyRevision.committedAt
                    == receipt.committedAt,
                  receiptRevision.committedAt
                    == receipt.committedAt else {
                throw failure
            }
        }
    }

    static func snapshot(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> PrivacyControlSnapshot {
        try validate(in: context, failure: failure)
        let tuple = try records(in: context, failure: failure)
        let key = recordKey(
            type: "PrivacyControlRecord",
            id: PrivacyControlRecord.stableID
        )
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == key }
        )
        descriptor.fetchLimit = 2
        let revisions = try context.fetch(descriptor)
        guard revisions.count == 1, let revision = revisions.first else {
            throw failure
        }
        return PrivacyControlSnapshot(
            appLockEnabled: tuple.record.appLockEnabled,
            localRevision: revision.localRevision,
            digestHex: revision.digestHex,
            lastOperationID: tuple.record.lastOperationID,
            updatedAt: tuple.record.updatedAt
        )
    }

    static func validates(_ value: PrivacyControlRecord) -> Bool {
        value.singletonKey == PrivacyControlRecord.fixedKey
            && value.contractVersion == PrivacyControlRecord.contractVersion
            && value.createdAt.timeIntervalSince1970.isFinite
            && value.updatedAt.timeIntervalSince1970.isFinite
            && value.updatedAt >= value.createdAt
    }

    static func validates(_ value: PrivacyControlBackfillState) -> Bool {
        value.taskKey == PrivacyControlBackfillState.fixedKey
            && value.source != nil
            && value.initialPrivacyDigest.count == 64
            && value.initialPrivacyDigest.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
            && value.completedAt?.timeIntervalSince1970.isFinite == true
            && value.updatedAt.timeIntervalSince1970.isFinite
    }

    private static func records(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> (
        record: PrivacyControlRecord,
        state: PrivacyControlBackfillState
    ) {
        var recordDescriptor = FetchDescriptor<PrivacyControlRecord>()
        recordDescriptor.fetchLimit = 2
        var stateDescriptor =
            FetchDescriptor<PrivacyControlBackfillState>()
        stateDescriptor.fetchLimit = 2
        let records = try context.fetch(recordDescriptor)
        let states = try context.fetch(stateDescriptor)
        guard records.count == 1,
              states.count == 1,
              let record = records.first,
              let state = states.first else {
            throw failure
        }
        return (record, state)
    }

    private static func validateRevision(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        context: ModelContext,
        failure: AppDataFailure
    ) throws -> RecordRevision {
        let key = recordKey(type: recordType, id: recordID)
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == key }
        )
        descriptor.fetchLimit = 2
        let revisions = try context.fetch(descriptor)
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard revisions.count == 1,
              metadataRecords.count == 1,
              let revision = revisions.first,
              let metadata = metadataRecords.first,
              revision.recordType == recordType,
              revision.recordID == recordID,
              revision.datasetID == metadata.datasetID,
              revision.digestVersion == RecordDigestV1.version,
              revision.digestHex == (try RecordDigestV1.sha256Hex(
                  recordType: recordType,
                  recordID: recordID,
                  fields: fields
              )) else {
            throw failure
        }
        return revision
    }

    private static func recordKey(type: String, id: UUID) -> String {
        type + ":" + id.uuidString.lowercased()
    }
}
