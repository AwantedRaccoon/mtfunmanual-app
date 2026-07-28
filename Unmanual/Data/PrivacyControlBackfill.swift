import Foundation
import SwiftData

struct PrivacyControlBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum PrivacyControlBackfill {
    static func run(
        in container: ModelContainer,
        source: PrivacyControlBackfillSource,
        now: Date = Date()
    ) throws -> PrivacyControlBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard now.timeIntervalSince1970.isFinite else {
            throw AppDataFailure.migrationFailed
        }

        var recordDescriptor = FetchDescriptor<PrivacyControlRecord>()
        recordDescriptor.fetchLimit = 2
        var stateDescriptor =
            FetchDescriptor<PrivacyControlBackfillState>()
        stateDescriptor.fetchLimit = 2
        let existingRecords = try context.fetch(recordDescriptor)
        let existingStates = try context.fetch(stateDescriptor)
        guard existingRecords.count <= 1, existingStates.count <= 1 else {
            throw AppDataFailure.migrationFailed
        }

        if let state = existingStates.first, state.completedAt != nil {
            guard state.source == source else {
                throw AppDataFailure.migrationFailed
            }
            try PrivacyControlRelationshipValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return PrivacyControlBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }

        do {
            try context.transaction {
                guard existingRecords.isEmpty,
                      existingStates.isEmpty else {
                    throw AppDataFailure.migrationFailed
                }
                let record = PrivacyControlRecord(
                    appLockEnabled: false,
                    createdAt: now,
                    updatedAt: now
                )
                let initialDigest = try PrivacyControlDigestV1
                    .initialRecordDigest(
                        createdAt: now
                    )
                let state = PrivacyControlBackfillState(
                    source: source,
                    initialPrivacyDigest: initialDigest,
                    completedAt: now,
                    updatedAt: now
                )
                context.insert(record)
                context.insert(state)
                try insertRevisions(
                    record: record,
                    state: state,
                    in: context,
                    committedAt: now
                )
                try PrivacyControlRelationshipValidator.validate(
                    in: context,
                    failure: .migrationFailed
                )
                try context.save()
            }
            try PrivacyControlRelationshipValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return PrivacyControlBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func insertRevisions(
        record: PrivacyControlRecord,
        state: PrivacyControlBackfillState,
        in context: ModelContext,
        committedAt: Date
    ) throws {
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard metadataRecords.count == 1,
              let metadata = metadataRecords.first,
              metadata.nextLocalRevision > 0,
              metadata.nextLocalRevision < Int64.max else {
            throw AppDataFailure.migrationFailed
        }
        let revision = metadata.nextLocalRevision
        let facts: [(
            type: String,
            id: UUID,
            fields: [RecordDigestV1.Field]
        )] = [
            (
                "PrivacyControlRecord",
                PrivacyControlRecord.stableID,
                try PrivacyControlDigestV1.record(record)
            ),
            (
                "PrivacyControlBackfillState",
                PrivacyControlBackfillState.stableID,
                try PrivacyControlDigestV1.backfillState(state)
            )
        ]
        for fact in facts {
            let key = fact.type + ":" + fact.id.uuidString.lowercased()
            context.insert(
                RecordRevision(
                    recordKey: key,
                    recordType: fact.type,
                    recordID: fact.id,
                    datasetID: metadata.datasetID,
                    localRevision: revision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try RecordDigestV1.sha256Hex(
                        recordType: fact.type,
                        recordID: fact.id,
                        fields: fact.fields
                    ),
                    committedAt: committedAt
                )
            )
        }
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
    }
}
