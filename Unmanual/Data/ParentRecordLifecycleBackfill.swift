import Foundation
import SwiftData

struct ParentRecordLifecycleBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum ParentRecordLifecycleBackfill {
    static func run(
        in container: ModelContainer,
        sourceSchemaVersion: String = "9.0.0",
        now: Date = Date()
    ) throws -> ParentRecordLifecycleBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor =
            FetchDescriptor<ParentRecordLifecycleBackfillState>()
        descriptor.fetchLimit = 2
        let existing = try context.fetch(descriptor)
        guard existing.count <= 1 else {
            throw AppDataFailure.migrationFailed
        }
        if existing.count == 1 {
            try ParentRecordLifecycleValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return ParentRecordLifecycleBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }
        guard sourceSchemaVersion == "9.0.0",
              now.timeIntervalSince1970.isFinite else {
            throw AppDataFailure.migrationFailed
        }

        do {
            try context.transaction {
                var sampleDescriptor = FetchDescriptor<LabSampleRecord>(
                    sortBy: [SortDescriptor(\.id)]
                )
                sampleDescriptor.fetchLimit =
                    ParentRecordLifecycleCapacity.maximumParents + 1
                let samples = try context.fetch(sampleDescriptor)
                var observationDescriptor =
                    FetchDescriptor<StatusObservationRecord>(
                        sortBy: [SortDescriptor(\.id)]
                    )
                observationDescriptor.fetchLimit =
                    ParentRecordLifecycleCapacity.maximumParents + 1
                let observations = try context.fetch(
                    observationDescriptor
                )
                guard samples.count
                        <= ParentRecordLifecycleCapacity.maximumParents,
                      observations.count
                        <= ParentRecordLifecycleCapacity.maximumParents,
                      samples.count + observations.count
                        <= ParentRecordLifecycleCapacity.maximumParents else {
                    throw AppDataFailure.migrationFailed
                }
                let maximumResultRows =
                    ParentRecordLifecycleCapacity.maximumParents
                        * PersonalTimelineCapacity
                            .maximumLabResultsPerSample
                var resultDescriptor =
                    FetchDescriptor<LabResultRecord>()
                resultDescriptor.fetchLimit = maximumResultRows + 1
                let results = try context.fetch(resultDescriptor)
                guard results.count <= maximumResultRows else {
                    throw AppDataFailure.migrationFailed
                }
                let resultsBySample = Dictionary(
                    grouping: results,
                    by: \.sampleID
                )
                let labSourceType = "LabSampleRecord"
                let statusSourceType = "StatusObservationRecord"
                var timeDescriptor =
                    FetchDescriptor<HistoricalTimeRecord>(
                        predicate: #Predicate {
                            $0.sourceRecordType == labSourceType
                                || $0.sourceRecordType
                                    == statusSourceType
                        }
                    )
                timeDescriptor.fetchLimit =
                    ParentRecordLifecycleCapacity.maximumParents + 1
                let relevantTimes = try context.fetch(timeDescriptor)
                guard relevantTimes.count
                        <= ParentRecordLifecycleCapacity.maximumParents else {
                    throw AppDataFailure.migrationFailed
                }
                let timeByKey = try AppDataIndex.checkedUniqueMap(
                    relevantTimes,
                    keyedBy: \.recordKey,
                    failure: .migrationFailed
                )
                var rootEntries: [(String, String)] = []
                var revisionFacts:
                    [(String, UUID, [RecordDigestV1.Field])] = []

                for sample in samples {
                    let type = ParentRecordType.labSample
                    let key = type.recordKey(parentID: sample.id)
                    guard let time = timeByKey[
                        type.sourceRecordType + ":"
                            + sample.id.uuidString.lowercased()
                    ],
                    let timestamp = time.historicalTimestamp else {
                        throw AppDataFailure.migrationFailed
                    }
                    let digest =
                        try ParentRecordLifecycleDigest.labBaseFacts(
                            sample: sample,
                            results: resultsBySample[sample.id, default: []],
                            time: time
                        )
                    let event = migrationEvent(
                        type: type,
                        parentID: sample.id,
                        factsDigest: digest,
                        now: now
                    )
                    let head = ParentRecordLifecycleHeadRecord(
                        parentType: type,
                        parentID: sample.id,
                        latestEventID: event.id,
                        eventCount: 1,
                        effectiveTimestamp: timestamp,
                        updatedAt: now
                    )
                    context.insert(event)
                    context.insert(head)
                    rootEntries.append((key, digest))
                    revisionFacts.append(
                        (
                            "ParentRecordMutationEventRecord",
                            event.id,
                            try ParentRecordLifecycleDigest.event(event)
                        )
                    )
                    revisionFacts.append(
                        (
                            "ParentRecordLifecycleHeadRecord",
                            stableHeadID(for: key),
                            try ParentRecordLifecycleDigest.head(head)
                        )
                    )
                }

                for observation in observations {
                    let type = ParentRecordType.statusObservation
                    let key = type.recordKey(parentID: observation.id)
                    guard let time = timeByKey[
                        type.sourceRecordType + ":"
                            + observation.id.uuidString.lowercased()
                    ],
                    let timestamp = time.historicalTimestamp else {
                        throw AppDataFailure.migrationFailed
                    }
                    let digest =
                        try ParentRecordLifecycleDigest.statusBaseFacts(
                            observation: observation,
                            time: time
                        )
                    let event = migrationEvent(
                        type: type,
                        parentID: observation.id,
                        factsDigest: digest,
                        now: now
                    )
                    let head = ParentRecordLifecycleHeadRecord(
                        parentType: type,
                        parentID: observation.id,
                        latestEventID: event.id,
                        eventCount: 1,
                        effectiveTimestamp: timestamp,
                        updatedAt: now
                    )
                    context.insert(event)
                    context.insert(head)
                    rootEntries.append((key, digest))
                    revisionFacts.append(
                        (
                            "ParentRecordMutationEventRecord",
                            event.id,
                            try ParentRecordLifecycleDigest.event(event)
                        )
                    )
                    revisionFacts.append(
                        (
                            "ParentRecordLifecycleHeadRecord",
                            stableHeadID(for: key),
                            try ParentRecordLifecycleDigest.head(head)
                        )
                    )
                }

                let state = ParentRecordLifecycleBackfillState(
                    sourceSchemaVersion: sourceSchemaVersion,
                    labParentCount: samples.count,
                    statusParentCount: observations.count,
                    rootSetDigest:
                        try ParentRecordLifecycleDigest.rootSet(rootEntries),
                    completedAt: now,
                    updatedAt: now
                )
                context.insert(state)
                revisionFacts.append(
                    (
                        "ParentRecordLifecycleBackfillState",
                        CoreTimeRegimenBackfill.stableUUID(
                            for: state.taskKey
                        ),
                        try ParentRecordLifecycleDigest.backfillState(state)
                    )
                )
                try insertSharedRevisions(
                    revisionFacts,
                    in: context,
                    committedAt: now
                )
            }
            try ParentRecordLifecycleValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return ParentRecordLifecycleBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    static func stableHeadID(for parentKey: String) -> UUID {
        CoreTimeRegimenBackfill.stableUUID(
            for: "parent-lifecycle-head:" + parentKey
        )
    }

    static func stableRootEventID(
        type: ParentRecordType,
        parentID: UUID
    ) -> UUID {
        CoreTimeRegimenBackfill.stableUUID(
            for: "parent-lifecycle-root:"
                + type.recordKey(parentID: parentID)
        )
    }

    private static func migrationEvent(
        type: ParentRecordType,
        parentID: UUID,
        factsDigest: String,
        now: Date
    ) -> ParentRecordMutationEventRecord {
        let eventID = stableRootEventID(type: type, parentID: parentID)
        return ParentRecordMutationEventRecord(
            id: eventID,
            parentType: type,
            parentID: parentID,
            kind: .migratedSnapshot,
            previousEventID: nil,
            payloadRecordType: nil,
            payloadID: nil,
            operationID: CoreTimeRegimenBackfill.stableUUID(
                for: "parent-lifecycle-migration-operation:"
                    + type.recordKey(parentID: parentID)
            ),
            commandDigest: factsDigest,
            preFactsDigest: factsDigest,
            postFactsDigest: factsDigest,
            committedAt: now
        )
    }

    private static func insertSharedRevisions(
        _ facts: [(String, UUID, [RecordDigestV1.Field])],
        in context: ModelContext,
        committedAt: Date
    ) throws {
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let records = try context.fetch(metadataDescriptor)
        guard records.count == 1,
              let metadata = records.first,
              metadata.nextLocalRevision > 0,
              metadata.nextLocalRevision < Int64.max - 1 else {
            throw AppDataFailure.migrationFailed
        }
        let revision = metadata.nextLocalRevision
        for (type, id, fields) in facts {
            let key = type + ":" + id.uuidString.lowercased()
            let expectedKey = key
            var descriptor = FetchDescriptor<RecordRevision>(
                predicate: #Predicate {
                    $0.recordKey == expectedKey
                }
            )
            descriptor.fetchLimit = 1
            guard try context.fetch(descriptor).isEmpty else {
                throw AppDataFailure.migrationFailed
            }
            context.insert(
                RecordRevision(
                    recordKey: key,
                    recordType: type,
                    recordID: id,
                    datasetID: metadata.datasetID,
                    localRevision: revision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try RecordDigestV1.sha256Hex(
                        recordType: type,
                        recordID: id,
                        fields: fields
                    ),
                    committedAt: committedAt
                )
            )
        }
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
    }
}
