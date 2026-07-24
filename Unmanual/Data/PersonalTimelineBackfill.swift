import CryptoKit
import Foundation
import SwiftData

struct PersonalTimelineBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum PersonalTimelineBackfill {
    static func run(
        in container: ModelContainer,
        now: Date = Date()
    ) throws -> PersonalTimelineBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<PersonalTimelineBackfillState>()
        descriptor.fetchLimit = 2
        let states = try context.fetch(descriptor)
        guard states.count <= 1 else { throw AppDataFailure.migrationFailed }
        if let state = states.first, state.completedAt != nil {
            return PersonalTimelineBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }

        do {
            try context.transaction {
                let state = states.first ?? PersonalTimelineBackfillState(updatedAt: now)
                if states.isEmpty { context.insert(state) }
                let facts = try migrateLegacyLabs(in: context, now: now)
                try ensureRevisions(for: facts, in: context, now: now)
                state.completedAt = now
                state.updatedAt = now
            }
            return PersonalTimelineBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    static func legacySampleID(for legacyID: UUID) -> UUID {
        stableUUID(namespace: "legacy-lab-sample", value: legacyID.uuidString)
    }

    private struct BackfilledFacts {
        var definitions: [LabItemDefinitionRecord] = []
        var samples: [LabSampleRecord] = []
        var results: [LabResultRecord] = []
        var historicalTimes: [HistoricalTimeRecord] = []
        var receipts: [OperationReceiptRecord] = []
    }

    private static func migrateLegacyLabs(
        in context: ModelContext,
        now: Date
    ) throws -> BackfilledFacts {
        let legacy = try context.fetch(
            FetchDescriptor<LabRecord>(
                sortBy: [SortDescriptor(\.sampledAt), SortDescriptor(\.id)]
            )
        )
        let existingSamples = Set(
            try context.fetch(FetchDescriptor<LabSampleRecord>()).map(\.id)
        )
        let existingResults = Set(
            try context.fetch(FetchDescriptor<LabResultRecord>()).map(\.id)
        )
        let existingDefinitions = Set(
            try context.fetch(FetchDescriptor<LabItemDefinitionRecord>()).map(\.id)
        )
        let existingReceiptOperationIDs = Set(
            try context.fetch(FetchDescriptor<OperationReceiptRecord>())
                .map(\.operationID)
        )
        let legacyTimes = try context.fetch(FetchDescriptor<HistoricalTimeRecord>())
        let legacyTimeByID = try AppDataIndex.checkedUniqueMap(
            legacyTimes.filter { $0.sourceRecordType == "LabRecord" },
            keyedBy: \.sourceRecordID,
            failure: .migrationFailed
        )

        var facts = BackfilledFacts()
        for source in legacy {
            let sampleID = legacySampleID(for: source.id)
            let definitionID = stableUUID(
                namespace: "legacy-lab-definition",
                value: source.id.uuidString
            )
            guard !existingSamples.contains(sampleID),
                  !existingResults.contains(source.id),
                  !existingDefinitions.contains(definitionID),
                  let legacyTime = legacyTimeByID[source.id],
                  let timestamp = legacyTime.historicalTimestamp,
                  let associationState = HistoricalAssociationState(
                      rawValue: legacyTime.associationStateRawValue
                  ) else {
                throw AppDataFailure.migrationFailed
            }

            let hasName = !source.itemName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let definition = LabItemDefinitionRecord(
                id: definitionID,
                displayName: hasName ? source.itemName : "未命名旧版项目",
                code: source.itemCode,
                createdAt: source.createdAt
            )
            let operationID = stableUUID(
                namespace: "legacy-lab-operation",
                value: source.id.uuidString
            )
            guard !existingReceiptOperationIDs.contains(operationID) else {
                throw AppDataFailure.migrationFailed
            }
            let sample = LabSampleRecord(
                id: sampleID,
                operationID: operationID,
                contextNote: source.contextNote,
                createdAt: source.createdAt
            )
            let parsed = try? LabDecimalValue.parse(source.rawValue)
            guard source.numericValue.isFinite else {
                throw AppDataFailure.migrationFailed
            }
            let result = LabResultRecord(
                id: source.id,
                sampleID: sampleID,
                sortOrder: 0,
                itemDefinitionID: definitionID,
                itemNameSnapshot: source.itemName,
                itemCodeSnapshot: source.itemCode,
                rawValueOriginal: source.rawValue,
                comparator: parsed?.comparator,
                canonicalDecimalString: parsed?.canonicalDecimal
                    ?? String(source.numericValue),
                unitOriginal: source.unit,
                referenceRangeOriginal: source.referenceRangeOriginal,
                operationID: operationID,
                createdAt: source.createdAt
            )
            let historical = HistoricalTimeRecord(
                sourceRecordType: "LabSampleRecord",
                sourceRecordID: sampleID,
                timestamp: timestamp,
                legacyAssociationID: legacyTime.legacyAssociationID,
                resolvedRegimenVersionID: legacyTime.resolvedRegimenVersionID,
                associationState: associationState
            )
            let receipt = OperationReceiptRecord(
                operationID: operationID,
                commandDigest: try legacyLabCommandDigest(
                    source: source,
                    definition: definition,
                    sample: sample,
                    result: result,
                    historicalTime: historical
                ),
                resultRecordType: "LabSampleRecord",
                resultRecordID: sampleID,
                committedAt: source.createdAt
            )
            context.insert(definition)
            context.insert(sample)
            context.insert(result)
            context.insert(historical)
            context.insert(receipt)
            facts.definitions.append(definition)
            facts.samples.append(sample)
            facts.results.append(result)
            facts.historicalTimes.append(historical)
            facts.receipts.append(receipt)
        }
        return facts
    }

    private static func ensureRevisions(
        for facts: BackfilledFacts,
        in context: ModelContext,
        now: Date
    ) throws {
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard metadataRecords.count == 1, let metadata = metadataRecords.first else {
            throw AppDataFailure.migrationFailed
        }
        var revisionFacts: [(String, UUID, [RecordDigestV1.Field], Date)] = []
        revisionFacts += try facts.definitions.map {
            ("LabItemDefinitionRecord", $0.id, try PersonalTimelineDigestV1.labItemDefinition($0), $0.createdAt)
        }
        revisionFacts += try facts.samples.map {
            ("LabSampleRecord", $0.id, try PersonalTimelineDigestV1.labSample($0), $0.createdAt)
        }
        revisionFacts += try facts.results.map {
            ("LabResultRecord", $0.id, try PersonalTimelineDigestV1.labResult($0), $0.createdAt)
        }
        revisionFacts += try facts.historicalTimes.map {
            (
                "HistoricalTimeRecord",
                CoreTimeRegimenBackfill.stableUUID(for: $0.recordKey),
                try CoreFactDigestV1.historicalTime($0),
                $0.instant
            )
        }
        revisionFacts += try facts.receipts.map {
            (
                "OperationReceiptRecord",
                $0.operationID,
                try TodayExecutionDigestV1.operationReceipt($0),
                $0.committedAt
            )
        }
        revisionFacts.sort {
            $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.uuidString < $1.1.uuidString
        }
        let existingKeys = Set(
            try context.fetch(FetchDescriptor<RecordRevision>()).map(\.recordKey)
        )
        for (type, id, fields, createdAt) in revisionFacts {
            let key = type + ":" + id.uuidString.lowercased()
            guard !existingKeys.contains(key),
                  metadata.nextLocalRevision > 0,
                  metadata.nextLocalRevision < Int64.max else {
                throw AppDataFailure.migrationFailed
            }
            context.insert(
                RecordRevision(
                    recordKey: key,
                    recordType: type,
                    recordID: id,
                    datasetID: metadata.datasetID,
                    localRevision: metadata.nextLocalRevision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try RecordDigestV1.sha256Hex(
                        recordType: type,
                        recordID: id,
                        fields: fields
                    ),
                    committedAt: max(createdAt, now)
                )
            )
            metadata.nextLocalRevision += 1
        }

        if !facts.receipts.isEmpty {
            var ledgerDescriptor =
                FetchDescriptor<OperationReceiptLedgerRecord>()
            ledgerDescriptor.fetchLimit = 2
            let ledgers = try context.fetch(ledgerDescriptor)
            guard ledgers.count == 1,
                  let ledger = ledgers.first,
                  ledger.ledgerKey == OperationReceiptLedgerRecord.fixedKey,
                  metadata.nextLocalRevision > 1 else {
                throw AppDataFailure.migrationFailed
            }
            var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>()
            receiptDescriptor.fetchLimit = 65_537
            let receipts = try context.fetch(receiptDescriptor)
            guard receipts.count <= 65_536 else {
                throw AppDataFailure.migrationFailed
            }
            ledger.receiptCount = receipts.count
            ledger.receiptSetDigest = try TodayExecutionDigestV1.receiptSetDigest(
                receipts
            )
            ledger.updatedAt = now

            let ledgerRecordType = "OperationReceiptLedgerRecord"
            let ledgerRecordID = TodayExecutionDigestV1.receiptLedgerID
            let ledgerRecordKey =
                ledgerRecordType + ":" + ledgerRecordID.uuidString.lowercased()
            var ledgerRevisionDescriptor = FetchDescriptor<RecordRevision>(
                predicate: #Predicate { $0.recordKey == ledgerRecordKey }
            )
            ledgerRevisionDescriptor.fetchLimit = 2
            let ledgerRevisions = try context.fetch(ledgerRevisionDescriptor)
            guard ledgerRevisions.count == 1,
                  let ledgerRevision = ledgerRevisions.first else {
                throw AppDataFailure.migrationFailed
            }
            ledgerRevision.recordType = ledgerRecordType
            ledgerRevision.recordID = ledgerRecordID
            ledgerRevision.datasetID = metadata.datasetID
            // The final receipt and its ledger projection are one atomic change.
            ledgerRevision.localRevision = metadata.nextLocalRevision - 1
            ledgerRevision.digestVersion = RecordDigestV1.version
            ledgerRevision.digestHex = try RecordDigestV1.sha256Hex(
                recordType: ledgerRecordType,
                recordID: ledgerRecordID,
                fields: TodayExecutionDigestV1.operationReceiptLedger(ledger)
            )
            ledgerRevision.committedAt = now
        }
        metadata.lastCommittedAt = now
    }

    private static func legacyLabCommandDigest(
        source: LabRecord,
        definition: LabItemDefinitionRecord,
        sample: LabSampleRecord,
        result: LabResultRecord,
        historicalTime: HistoricalTimeRecord
    ) throws -> String {
        var fields: [RecordDigestV1.Field] = [
            .init("legacyRecordID", .uuid(source.id)),
            .init("sampleID", .uuid(sample.id))
        ]
        fields += try prefixed(
            FactDigestV1.lab(source),
            prefix: "legacy"
        )
        fields += try prefixed(
            PersonalTimelineDigestV1.labItemDefinition(definition),
            prefix: "definition"
        )
        fields += try prefixed(
            PersonalTimelineDigestV1.labSample(sample),
            prefix: "sample"
        )
        fields += try prefixed(
            PersonalTimelineDigestV1.labResult(result),
            prefix: "result"
        )
        fields += try prefixed(
            CoreFactDigestV1.historicalTime(historicalTime),
            prefix: "historicalTime"
        )
        return try RecordDigestV1.sha256Hex(
            recordType: "LegacyLabSampleBackfillCommand",
            recordID: sample.operationID,
            fields: fields
        )
    }

    private static func prefixed(
        _ fields: [RecordDigestV1.Field],
        prefix: String
    ) -> [RecordDigestV1.Field] {
        fields.map {
            RecordDigestV1.Field(prefix + "." + $0.name, $0.value)
        }
    }

    private static func stableUUID(namespace: String, value: String) -> UUID {
        let digest = SHA256.hash(data: Data((namespace + "\0" + value).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
