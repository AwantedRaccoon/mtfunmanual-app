import Foundation
import SwiftData

struct TodayExecutionBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
}

enum TodayExecutionBackfill {
    static func run(
        in container: ModelContainer,
        now: Date = Date()
    ) throws -> TodayExecutionBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var stateDescriptor = FetchDescriptor<TodayExecutionBackfillState>()
        stateDescriptor.fetchLimit = 2
        let states = try context.fetch(stateDescriptor)
        guard states.count <= 1 else { throw AppDataFailure.migrationFailed }

        if let state = states.first, state.completedAt != nil {
            try ensureSingleCoverage(in: context)
            try ensureReceiptLedger(in: context, now: now)
            return TodayExecutionBackfillOutcome(didComplete: true)
        }

        try context.transaction {
            let state = states.first ?? TodayExecutionBackfillState(updatedAt: now)
            if states.isEmpty { context.insert(state) }
            if try context.fetch(FetchDescriptor<NotificationCoverageRecord>()).isEmpty {
                context.insert(
                    NotificationCoverageRecord(
                        status: .disabledByUser,
                        observedAt: now
                    )
                )
            }
            state.completedAt = now
            state.updatedAt = now
            try context.save()
        }
        try ensureSingleCoverage(in: context)
        try ensureReceiptLedger(in: context, now: now)
        return TodayExecutionBackfillOutcome(didComplete: true)
    }

    private static func ensureSingleCoverage(in context: ModelContext) throws {
        let coverage = try context.fetch(FetchDescriptor<NotificationCoverageRecord>())
        guard coverage.count == 1,
              coverage.first?.coverageKey == NotificationCoverageRecord.fixedKey,
              coverage.first?.status != nil else {
            throw AppDataFailure.migrationFailed
        }
    }

    private static func ensureReceiptLedger(
        in context: ModelContext,
        now: Date
    ) throws {
        var ledgerDescriptor = FetchDescriptor<OperationReceiptLedgerRecord>()
        ledgerDescriptor.fetchLimit = 2
        let ledgers = try context.fetch(ledgerDescriptor)
        guard ledgers.count <= 1 else { throw AppDataFailure.migrationFailed }
        if let ledger = ledgers.first {
            let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
            guard ledger.ledgerKey == OperationReceiptLedgerRecord.fixedKey,
                  ledger.receiptCount == receipts.count,
                  ledger.receiptSetDigest == TodayExecutionDigestV1.receiptSetDigest(receipts) else {
                throw AppDataFailure.migrationFailed
            }
            return
        }

        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard metadataRecords.count == 1,
              let metadata = metadataRecords.first,
              metadata.nextLocalRevision > 0,
              metadata.nextLocalRevision < Int64.max else {
            throw AppDataFailure.migrationFailed
        }
        let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
        let ledger = OperationReceiptLedgerRecord(
            receiptCount: receipts.count,
            receiptSetDigest: TodayExecutionDigestV1.receiptSetDigest(receipts),
            updatedAt: now
        )
        try context.transaction {
            context.insert(ledger)
            let recordType = "OperationReceiptLedgerRecord"
            let recordID = TodayExecutionDigestV1.receiptLedgerID
            context.insert(
                RecordRevision(
                    recordKey: recordType + ":" + recordID.uuidString.lowercased(),
                    recordType: recordType,
                    recordID: recordID,
                    datasetID: metadata.datasetID,
                    localRevision: metadata.nextLocalRevision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try RecordDigestV1.sha256Hex(
                        recordType: recordType,
                        recordID: recordID,
                        fields: TodayExecutionDigestV1.operationReceiptLedger(ledger)
                    ),
                    committedAt: now
                )
            )
            metadata.nextLocalRevision += 1
            metadata.lastCommittedAt = now
            try context.save()
        }
    }
}
