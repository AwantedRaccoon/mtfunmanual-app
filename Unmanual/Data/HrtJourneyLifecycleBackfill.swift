import Foundation
import SwiftData

struct HrtJourneyLifecycleBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum HrtJourneyLifecycleBackfill {
    static func run(
        in container: ModelContainer,
        sourceSchemaVersion: String,
        now: Date = Date()
    ) throws -> HrtJourneyLifecycleBackfillOutcome {
        guard ["8.0.0", "9.0.0"].contains(sourceSchemaVersion),
              now.timeIntervalSince1970.isFinite else {
            throw AppDataFailure.migrationFailed
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var stateDescriptor =
            FetchDescriptor<HrtJourneyLifecycleBackfillState>()
        stateDescriptor.fetchLimit = 2
        let existingStates = try context.fetch(stateDescriptor)
        guard existingStates.count <= 1 else {
            throw AppDataFailure.migrationFailed
        }
        if let state = existingStates.first, state.completedAt != nil {
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return HrtJourneyLifecycleBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }

        var eventDescriptor =
            FetchDescriptor<HrtJourneyLifecycleEventRecord>()
        eventDescriptor.fetchLimit = 2
        guard try context.fetch(eventDescriptor).isEmpty else {
            throw AppDataFailure.migrationFailed
        }
        let initialFactsDigest =
            try HrtJourneyLifecycleDigest.facts(
                in: context,
                failure: .migrationFailed
            )
        let periods = try context.fetch(FetchDescriptor<HrtPeriodRecord>())
        var profileDescriptor = FetchDescriptor<HrtJourneyProfileRecord>()
        profileDescriptor.fetchLimit = 2
        let hasJourney = try !context.fetch(profileDescriptor).isEmpty
        let migrationTimestamp = try HistoricalTimestamp.captured(
            instant: now,
            timeZoneIdentifier: "UTC",
            precision: .second,
            provenance: .migrationAssumed
        )
        let committedAt = migrationTimestamp.instant

        do {
            try context.transaction {
                var metadataDescriptor =
                    FetchDescriptor<DatasetMetadata>()
                metadataDescriptor.fetchLimit = 2
                let metadataRecords = try context.fetch(metadataDescriptor)
                guard metadataRecords.count == 1,
                      let metadata = metadataRecords.first,
                      metadata.nextLocalRevision > 0,
                      metadata.nextLocalRevision < Int64.max else {
                    throw AppDataFailure.migrationFailed
                }
                let revision = metadata.nextLocalRevision
                metadata.nextLocalRevision += 1
                let event: HrtJourneyLifecycleEventRecord?
                if hasJourney {
                    let datasetText =
                        metadata.datasetID.uuidString.lowercased()
                    let created = HrtJourneyLifecycleEventRecord(
                        id: CoreTimeRegimenBackfill.stableUUID(
                            for: "HrtJourneyLifecycleEvent:migrated:"
                                + datasetText
                        ),
                        operationID: CoreTimeRegimenBackfill.stableUUID(
                            for: "HrtJourneyLifecycleOperation:migrated:"
                                + datasetText
                        ),
                        kind: .migratedSnapshot,
                        source: .migration,
                        previousEventID: nil,
                        periodID: nil,
                        transitionDate: nil,
                        noteSnapshot: "",
                        timestamp: migrationTimestamp,
                        preFactsDigest: initialFactsDigest,
                        postFactsDigest: initialFactsDigest
                    )
                    context.insert(created)
                    event = created
                } else {
                    event = nil
                }
                let state = existingStates.first
                    ?? HrtJourneyLifecycleBackfillState(
                        sourceSchemaVersion: sourceSchemaVersion,
                        initialPeriodCount: periods.count,
                        initialEventCount: event == nil ? 0 : 1,
                        initialFactsDigest: initialFactsDigest,
                        completedAt: committedAt,
                        updatedAt: committedAt
                    )
                if existingStates.isEmpty {
                    context.insert(state)
                } else {
                    state.sourceSchemaVersion = sourceSchemaVersion
                    state.initialPeriodCount = periods.count
                    state.initialEventCount = event == nil ? 0 : 1
                    state.initialFactsDigest = initialFactsDigest
                    state.completedAt = committedAt
                    state.updatedAt = committedAt
                }
                if let event {
                    try insertRevision(
                        recordType: "HrtJourneyLifecycleEventRecord",
                        recordID: event.id,
                        fields: try HrtJourneyLifecycleDigest.event(event),
                        datasetID: metadata.datasetID,
                        localRevision: revision,
                        committedAt: committedAt,
                        in: context
                    )
                }
                try insertRevision(
                    recordType: "HrtJourneyLifecycleBackfillState",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: HrtJourneyLifecycleBackfillState.fixedKey
                    ),
                    fields: try HrtJourneyLifecycleDigest.backfillState(
                        state
                    ),
                    datasetID: metadata.datasetID,
                    localRevision: revision,
                    committedAt: committedAt,
                    in: context
                )
                metadata.lastCommittedAt = committedAt
                try context.save()
            }
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return HrtJourneyLifecycleBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func insertRevision(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        datasetID: UUID,
        localRevision: Int64,
        committedAt: Date,
        in context: ModelContext
    ) throws {
        let recordKey =
            recordType + ":" + recordID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == recordKey }
        )
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else {
            throw AppDataFailure.migrationFailed
        }
        context.insert(
            RecordRevision(
                recordKey: recordKey,
                recordType: recordType,
                recordID: recordID,
                datasetID: datasetID,
                localRevision: localRevision,
                digestVersion: RecordDigestV1.version,
                digestHex: try RecordDigestV1.sha256Hex(
                    recordType: recordType,
                    recordID: recordID,
                    fields: fields
                ),
                committedAt: committedAt
            )
        )
    }
}
