import Foundation
import SwiftData

enum ParentRecordLifecycleCapacity {
    static let maximumParents = 8_192
    static let maximumEvents = 65_536
    static let maximumCorrectionsPerParent = 256
    static let maximumAttachments =
        maximumParents * AttachmentFileStore.maximumOwnerFiles
    static let maximumRelevantReceipts =
        maximumEvents + maximumParents + (maximumAttachments * 2)
    static let maximumBaseLabResults =
        maximumParents
            * PersonalTimelineCapacity.maximumLabResultsPerSample
    static let maximumCorrectedLabResults =
        maximumEvents
            * PersonalTimelineCapacity.maximumLabResultsPerSample

    static func canAppendCorrection(toEventCount eventCount: Int) -> Bool {
        eventCount >= 1
            && eventCount <= maximumCorrectionsPerParent
    }

    static func maximumEventCount(
        for lifecycle: ParentRecordLifecycle
    ) -> Int {
        maximumCorrectionsPerParent
            + (lifecycle == .deleted ? 2 : 1)
    }
}

enum ParentRecordLifecycleDigest {
    static func head(
        _ record: ParentRecordLifecycleHeadRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "effectiveInstant",
                try RecordDigestV1.timestampValue(record.effectiveInstant)
            ),
            .init(
                "effectiveLocalDate",
                .string(
                    String(
                        format: "%04d-%02d-%02d",
                        record.effectiveLocalYear,
                        record.effectiveLocalMonth,
                        record.effectiveLocalDay
                    )
                )
            ),
            .init(
                "effectiveLocalHour",
                .integer(Int64(record.effectiveLocalHour))
            ),
            .init(
                "effectiveLocalMinute",
                .integer(Int64(record.effectiveLocalMinute))
            ),
            .init(
                "effectiveLocalSecond",
                .integer(Int64(record.effectiveLocalSecond))
            ),
            .init(
                "effectiveLocalNanosecond",
                .integer(Int64(record.effectiveLocalNanosecond))
            ),
            .init(
                "effectivePrecision",
                .string(record.effectivePrecisionRawValue)
            ),
            .init(
                "effectiveProvenance",
                .string(record.effectiveProvenanceRawValue)
            ),
            .init(
                "effectiveTimeZone",
                .string(record.effectiveTimeZoneIdentifier)
            ),
            .init(
                "effectiveUTCOffset",
                .integer(Int64(record.effectiveUTCOffsetSeconds))
            ),
            .init("eventCount", .integer(Int64(record.eventCount))),
            .init("latestEventID", .uuid(record.latestEventID)),
            .init(
                "latestPayloadID",
                record.latestPayloadID.map(RecordDigestV1.Value.uuid)
                    ?? .null
            ),
            .init("lifecycle", .string(record.lifecycleRawValue)),
            .init("parentID", .uuid(record.parentID)),
            .init("parentKey", .string(record.parentKey)),
            .init("parentType", .string(record.parentTypeRawValue)),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(record.updatedAt)
            )
        ]
    }

    static func event(
        _ record: ParentRecordMutationEventRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("commandDigest", .string(record.commandDigest)),
            .init(
                "committedAt",
                try RecordDigestV1.timestampValue(record.committedAt)
            ),
            .init("kind", .string(record.kindRawValue)),
            .init("operationID", .uuid(record.operationID)),
            .init(
                "expectedHeadEventCount",
                record.expectedHeadEventCount
                    .map { .integer(Int64($0)) } ?? .null
            ),
            .init(
                "expectedHeadLocalRevision",
                record.expectedHeadLocalRevision
                    .map(RecordDigestV1.Value.integer) ?? .null
            ),
            .init("parentID", .uuid(record.parentID)),
            .init("parentType", .string(record.parentTypeRawValue)),
            .init(
                "payloadID",
                record.payloadID.map(RecordDigestV1.Value.uuid) ?? .null
            ),
            .init(
                "payloadRecordType",
                record.payloadRecordType.map(RecordDigestV1.Value.string)
                    ?? .null
            ),
            .init("postFactsDigest", .string(record.postFactsDigest)),
            .init("preFactsDigest", .string(record.preFactsDigest)),
            .init(
                "previousEventID",
                record.previousEventID.map(RecordDigestV1.Value.uuid)
                    ?? .null
            )
        ]
    }

    static func labCorrection(
        _ record: LabSampleCorrectionSnapshotRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("contextNote", .string(record.contextNote)),
            .init(
                "createdAt",
                try RecordDigestV1.timestampValue(record.createdAt)
            ),
            .init("eventID", .uuid(record.eventID)),
            .init(
                "instant",
                try RecordDigestV1.timestampValue(record.instant)
            ),
            .init(
                "localDate",
                .string(
                    String(
                        format: "%04d-%02d-%02d",
                        record.localYear,
                        record.localMonth,
                        record.localDay
                    )
                )
            ),
            .init("localHour", .integer(Int64(record.localHour))),
            .init("localMinute", .integer(Int64(record.localMinute))),
            .init("localNanosecond", .integer(Int64(record.localNanosecond))),
            .init("localSecond", .integer(Int64(record.localSecond))),
            .init("parentID", .uuid(record.parentID)),
            .init("precision", .string(record.precisionRawValue)),
            .init("provenance", .string(record.provenanceRawValue)),
            .init(
                "resolvedRegimenVersionID",
                record.resolvedRegimenVersionID
                    .map(RecordDigestV1.Value.uuid) ?? .null
            ),
            .init(
                "associationState",
                .string(record.associationStateRawValue)
            ),
            .init("specimenOriginal", .string(record.specimenOriginal)),
            .init("timeZone", .string(record.timeZoneIdentifier)),
            .init("utcOffset", .integer(Int64(record.utcOffsetSeconds)))
        ]
    }

    static func labResultCorrection(
        _ record: LabResultCorrectionSnapshotRecord
    ) -> [RecordDigestV1.Field] {
        [
            .init(
                "assayOrVariantOriginal",
                record.assayOrVariantOriginal
                    .map(RecordDigestV1.Value.string) ?? .null
            ),
            .init(
                "canonicalDecimalString",
                .string(record.canonicalDecimalString)
            ),
            .init(
                "comparator",
                record.comparatorRawValue
                    .map(RecordDigestV1.Value.string) ?? .null
            ),
            .init("correctionSnapshotID", .uuid(record.correctionSnapshotID)),
            .init("itemCodeSnapshot", .string(record.itemCodeSnapshot)),
            .init("itemDefinitionID", .uuid(record.itemDefinitionID)),
            .init("itemNameSnapshot", .string(record.itemNameSnapshot)),
            .init("logicalResultID", .uuid(record.logicalResultID)),
            .init("rawValueOriginal", .string(record.rawValueOriginal)),
            .init(
                "referenceRangeOriginal",
                record.referenceRangeOriginal
                    .map(RecordDigestV1.Value.string) ?? .null
            ),
            .init("sortOrder", .integer(Int64(record.sortOrder))),
            .init("unitOriginal", .string(record.unitOriginal))
        ]
    }

    static func statusCorrection(
        _ record: StatusObservationCorrectionSnapshotRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "createdAt",
                try RecordDigestV1.timestampValue(record.createdAt)
            ),
            .init("eventID", .uuid(record.eventID)),
            .init(
                "instant",
                try RecordDigestV1.timestampValue(record.instant)
            ),
            .init(
                "localDate",
                .string(
                    String(
                        format: "%04d-%02d-%02d",
                        record.localYear,
                        record.localMonth,
                        record.localDay
                    )
                )
            ),
            .init("localHour", .integer(Int64(record.localHour))),
            .init("localMinute", .integer(Int64(record.localMinute))),
            .init("localNanosecond", .integer(Int64(record.localNanosecond))),
            .init("localSecond", .integer(Int64(record.localSecond))),
            .init("metricDefinitionID", .uuid(record.metricDefinitionID)),
            .init("metricNameSnapshot", .string(record.metricNameSnapshot)),
            .init("note", .string(record.note)),
            .init("ordinalLevel", .integer(Int64(record.ordinalLevel))),
            .init("parentID", .uuid(record.parentID)),
            .init("precision", .string(record.precisionRawValue)),
            .init("provenance", .string(record.provenanceRawValue)),
            .init(
                "resolvedRegimenVersionID",
                record.resolvedRegimenVersionID
                    .map(RecordDigestV1.Value.uuid) ?? .null
            ),
            .init(
                "associationState",
                .string(record.associationStateRawValue)
            ),
            .init("timeZone", .string(record.timeZoneIdentifier)),
            .init("utcOffset", .integer(Int64(record.utcOffsetSeconds)))
        ]
    }

    static func tombstone(
        _ record: ParentRecordDeletionTombstoneRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "attachmentByteCount",
                .integer(record.attachmentByteCount)
            ),
            .init(
                "attachmentCount",
                .integer(Int64(record.attachmentCount))
            ),
            .init(
                "deletedAt",
                try RecordDigestV1.timestampValue(record.deletedAt)
            ),
            .init("eventID", .uuid(record.eventID)),
            .init(
                "attachmentManifest",
                .string(record.attachmentManifest)
            ),
            .init("impactDigest", .string(record.impactDigest)),
            .init("parentID", .uuid(record.parentID)),
            .init("parentKey", .string(record.parentKey)),
            .init("parentType", .string(record.parentTypeRawValue)),
            .init("priorFactsDigest", .string(record.priorFactsDigest))
        ]
    }

    static func backfillState(
        _ record: ParentRecordLifecycleBackfillState
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "completedAt",
                try optionalTimestamp(record.completedAt)
            ),
            .init(
                "labParentCount",
                .integer(Int64(record.labParentCount))
            ),
            .init("rootSetDigest", .string(record.rootSetDigest)),
            .init(
                "sourceSchemaVersion",
                .string(record.sourceSchemaVersion)
            ),
            .init(
                "statusParentCount",
                .integer(Int64(record.statusParentCount))
            ),
            .init("taskKey", .string(record.taskKey)),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(record.updatedAt)
            )
        ]
    }

    static func labBaseFacts(
        sample: LabSampleRecord,
        results: [LabResultRecord],
        time: HistoricalTimeRecord
    ) throws -> String {
        let resultDigests = try results.sorted {
            $0.sortOrder != $1.sortOrder
                ? $0.sortOrder < $1.sortOrder
                : $0.id.uuidString < $1.id.uuidString
        }.map {
            try RecordDigestV1.sha256Hex(
                recordType: "LabResultRecord",
                recordID: $0.id,
                fields: try PersonalTimelineDigestV1.labResult($0)
            )
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "EffectiveLabSampleFacts",
            recordID: sample.id,
            fields: [
                .init(
                    "historicalTimeDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "HistoricalTimeRecord",
                            recordID: CoreTimeRegimenBackfill.stableUUID(
                                for: time.recordKey
                            ),
                            fields: try CoreFactDigestV1.historicalTime(time)
                        )
                    )
                ),
                .init("resultCount", .integer(Int64(resultDigests.count))),
                .init(
                    "resultDigests",
                    .string(resultDigests.joined(separator: "\n"))
                ),
                .init(
                    "sampleDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "LabSampleRecord",
                            recordID: sample.id,
                            fields:
                                try PersonalTimelineDigestV1.labSample(sample)
                        )
                    )
                )
            ]
        )
    }

    static func labCorrectionFacts(
        snapshot: LabSampleCorrectionSnapshotRecord,
        results: [LabResultCorrectionSnapshotRecord]
    ) throws -> String {
        let resultDigests = try results.sorted {
            $0.sortOrder != $1.sortOrder
                ? $0.sortOrder < $1.sortOrder
                : $0.id.uuidString < $1.id.uuidString
        }.map {
            try RecordDigestV1.sha256Hex(
                recordType: "LabResultCorrectionSnapshotRecord",
                recordID: $0.id,
                fields: labResultCorrection($0)
            )
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "EffectiveLabSampleFacts",
            recordID: snapshot.parentID,
            fields: [
                .init("resultCount", .integer(Int64(resultDigests.count))),
                .init(
                    "resultDigests",
                    .string(resultDigests.joined(separator: "\n"))
                ),
                .init(
                    "snapshotDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "LabSampleCorrectionSnapshotRecord",
                            recordID: snapshot.id,
                            fields: try labCorrection(snapshot)
                        )
                    )
                )
            ]
        )
    }

    static func statusBaseFacts(
        observation: StatusObservationRecord,
        time: HistoricalTimeRecord
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "EffectiveStatusObservationFacts",
            recordID: observation.id,
            fields: [
                .init(
                    "historicalTimeDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "HistoricalTimeRecord",
                            recordID: CoreTimeRegimenBackfill.stableUUID(
                                for: time.recordKey
                            ),
                            fields: try CoreFactDigestV1.historicalTime(time)
                        )
                    )
                ),
                .init(
                    "observationDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "StatusObservationRecord",
                            recordID: observation.id,
                            fields: try StatusDigestV1.observation(observation)
                        )
                    )
                )
            ]
        )
    }

    static func statusCorrectionFacts(
        _ snapshot: StatusObservationCorrectionSnapshotRecord
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "EffectiveStatusObservationFacts",
            recordID: snapshot.parentID,
            fields: [
                .init(
                    "snapshotDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType:
                                "StatusObservationCorrectionSnapshotRecord",
                            recordID: snapshot.id,
                            fields: try statusCorrection(snapshot)
                        )
                    )
                )
            ]
        )
    }

    static func rootSet(
        _ entries: [(String, String)]
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "ParentRecordLifecycleRootSet",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: ParentRecordLifecycleBackfillState.fixedKey
            ),
            fields: entries.sorted { $0.0 < $1.0 }.enumerated().map {
                .init(
                    "root.\($0.offset).key",
                    .string($0.element.0 + ":" + $0.element.1)
                )
            }
        )
    }

    private static func optionalTimestamp(
        _ value: Date?
    ) throws -> RecordDigestV1.Value {
        guard let value else { return .null }
        return try RecordDigestV1.timestampValue(value)
    }
}

enum ParentRecordLifecycleValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        var stateDescriptor =
            FetchDescriptor<ParentRecordLifecycleBackfillState>()
        stateDescriptor.fetchLimit = 2
        let states = try context.fetch(stateDescriptor)
        guard states.count == 1,
              let state = states.first,
              state.taskKey
                == ParentRecordLifecycleBackfillState.fixedKey,
              state.sourceSchemaVersion == "9.0.0",
              state.completedAt?.timeIntervalSince1970.isFinite == true,
              state.updatedAt.timeIntervalSince1970.isFinite else {
            throw failure
        }

        var headDescriptor =
            FetchDescriptor<ParentRecordLifecycleHeadRecord>()
        headDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumParents + 1
        let heads = try context.fetch(headDescriptor)
        guard heads.count
                <= ParentRecordLifecycleCapacity.maximumParents else {
            throw failure
        }
        let headByKey = try AppDataIndex.checkedUniqueMap(
            heads,
            keyedBy: \.parentKey,
            failure: failure
        )

        var eventDescriptor =
            FetchDescriptor<ParentRecordMutationEventRecord>()
        eventDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumEvents + 1
        let events = try context.fetch(eventDescriptor)
        guard events.count
                <= ParentRecordLifecycleCapacity.maximumEvents else {
            throw failure
        }
        let eventByID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: failure
        )
        guard Set(events.map(\.operationID)).count == events.count,
              events.allSatisfy({
                  $0.committedAt.timeIntervalSince1970.isFinite
                      && isDigest($0.commandDigest)
                      && isDigest($0.preFactsDigest)
                      && isDigest($0.postFactsDigest)
                      && $0.parentType != nil
                      && $0.kind != nil
              }) else {
            throw failure
        }

        var labParentDescriptor = FetchDescriptor<LabSampleRecord>()
        labParentDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumParents + 1
        var statusParentDescriptor =
            FetchDescriptor<StatusObservationRecord>()
        statusParentDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumParents + 1
        let labParents = try context.fetch(labParentDescriptor)
        let statusParents = try context.fetch(statusParentDescriptor)
        guard labParents.count
                <= ParentRecordLifecycleCapacity.maximumParents,
              statusParents.count
                <= ParentRecordLifecycleCapacity.maximumParents,
              labParents.count + statusParents.count
                <= ParentRecordLifecycleCapacity.maximumParents else {
            throw failure
        }
        let labParentByID = try AppDataIndex.checkedUniqueMap(
            labParents,
            keyedBy: \.id,
            failure: failure
        )
        let statusParentByID = try AppDataIndex.checkedUniqueMap(
            statusParents,
            keyedBy: \.id,
            failure: failure
        )
        guard heads.count == labParents.count + statusParents.count else {
            throw failure
        }
        for parent in labParents {
            guard headByKey[
                ParentRecordType.labSample.recordKey(parentID: parent.id)
            ] != nil else {
                throw failure
            }
        }
        for parent in statusParents {
            guard headByKey[
                ParentRecordType.statusObservation.recordKey(
                    parentID: parent.id
                )
            ] != nil else {
                throw failure
            }
        }

        var baseResultDescriptor = FetchDescriptor<LabResultRecord>()
        baseResultDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumBaseLabResults + 1
        let baseResults = try context.fetch(baseResultDescriptor)
        guard baseResults.count
                <= ParentRecordLifecycleCapacity.maximumBaseLabResults
        else {
            throw failure
        }
        let baseResultsBySample = Dictionary(
            grouping: baseResults,
            by: \.sampleID
        )
        let labSourceRecordType = "LabSampleRecord"
        let statusSourceRecordType = "StatusObservationRecord"
        var relevantTimeDescriptor =
            FetchDescriptor<HistoricalTimeRecord>(
                predicate: #Predicate {
                    $0.sourceRecordType == labSourceRecordType
                        || $0.sourceRecordType == statusSourceRecordType
                }
            )
        relevantTimeDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumParents + 1
        let relevantTimes = try context.fetch(relevantTimeDescriptor)
        guard relevantTimes.count
                <= ParentRecordLifecycleCapacity.maximumParents else {
            throw failure
        }
        let timeByKey = try AppDataIndex.checkedUniqueMap(
            relevantTimes,
            keyedBy: \.recordKey,
            failure: failure
        )
        guard relevantTimes.count
                == labParents.count + statusParents.count else {
            throw failure
        }

        var labCorrectionDescriptor =
            FetchDescriptor<LabSampleCorrectionSnapshotRecord>()
        labCorrectionDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumEvents + 1
        let labCorrections = try context.fetch(
            labCorrectionDescriptor
        )
        guard labCorrections.count
                <= ParentRecordLifecycleCapacity.maximumEvents else {
            throw failure
        }
        let labCorrectionByID = try AppDataIndex.checkedUniqueMap(
            labCorrections,
            keyedBy: \.id,
            failure: failure
        )
        var correctedResultDescriptor =
            FetchDescriptor<LabResultCorrectionSnapshotRecord>()
        correctedResultDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumCorrectedLabResults + 1
        let correctedResults = try context.fetch(
            correctedResultDescriptor
        )
        guard correctedResults.count
                <= ParentRecordLifecycleCapacity
                    .maximumCorrectedLabResults else {
            throw failure
        }
        let correctedResultsBySnapshot = Dictionary(
            grouping: correctedResults,
            by: \.correctionSnapshotID
        )
        var activeLabOwnerByLogicalResultID: [UUID: UUID] = [:]
        for head in heads
        where head.parentType == .labSample
            && head.lifecycle == .active {
            let logicalResultIDs: [UUID]
            if let payloadID = head.latestPayloadID {
                guard let correction = labCorrectionByID[payloadID],
                      correction.parentID == head.parentID else {
                    throw failure
                }
                logicalResultIDs =
                    correctedResultsBySnapshot[payloadID, default: []]
                    .map(\.logicalResultID)
            } else {
                logicalResultIDs =
                    baseResultsBySample[head.parentID, default: []]
                    .map(\.id)
            }
            for logicalResultID in logicalResultIDs {
                if let owner =
                        activeLabOwnerByLogicalResultID[logicalResultID],
                   owner != head.parentID {
                    throw failure
                }
                activeLabOwnerByLogicalResultID[logicalResultID] =
                    head.parentID
            }
        }
        var statusCorrectionDescriptor =
            FetchDescriptor<StatusObservationCorrectionSnapshotRecord>()
        statusCorrectionDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumEvents + 1
        let statusCorrections = try context.fetch(
            statusCorrectionDescriptor
        )
        guard statusCorrections.count
                <= ParentRecordLifecycleCapacity.maximumEvents else {
            throw failure
        }
        let statusCorrectionByID = try AppDataIndex.checkedUniqueMap(
            statusCorrections,
            keyedBy: \.id,
            failure: failure
        )
        var tombstoneDescriptor =
            FetchDescriptor<ParentRecordDeletionTombstoneRecord>()
        tombstoneDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumParents + 1
        let tombstones = try context.fetch(tombstoneDescriptor)
        guard tombstones.count
                <= ParentRecordLifecycleCapacity.maximumParents else {
            throw failure
        }
        let tombstoneByID = try AppDataIndex.checkedUniqueMap(
            tombstones,
            keyedBy: \.id,
            failure: failure
        )
        guard Set(labCorrections.map(\.eventID)).count
                == labCorrections.count,
              Set(statusCorrections.map(\.eventID)).count
                == statusCorrections.count,
              Set(tombstones.map(\.eventID)).count
                == tombstones.count,
              correctedResults.count
                <= ParentRecordLifecycleCapacity
                    .maximumCorrectedLabResults else {
            throw failure
        }

        var definitionDescriptor =
            FetchDescriptor<LabItemDefinitionRecord>()
        definitionDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumLabItemDefinitions + 1
        let definitions = try context.fetch(definitionDescriptor)
        guard definitions.count
                <= PersonalTimelineCapacity.maximumLabItemDefinitions
        else {
            throw failure
        }
        let definitionIDs = Set(definitions.map(\.id))
        var metricDescriptor =
            FetchDescriptor<StatusMetricDefinitionRecord>()
        metricDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumStatusMetricDefinitions + 1
        let metrics = try context.fetch(metricDescriptor)
        guard metrics.count
                <= PersonalTimelineCapacity
                    .maximumStatusMetricDefinitions else {
            throw failure
        }
        let metricIDs = Set(metrics.map(\.id))
        for correction in labCorrections {
            guard correction.createdAt.timeIntervalSince1970.isFinite,
                  correction.timestamp != nil else {
                throw failure
            }
            let results =
                correctedResultsBySnapshot[correction.id, default: []]
            let orders = results.map(\.sortOrder).sorted()
            guard results.count
                    <= PersonalTimelineCapacity
                        .maximumLabResultsPerSample,
                  orders == Array(0..<orders.count),
                  Set(results.map(\.logicalResultID)).count
                    == results.count,
                  results.allSatisfy({ result in
                      guard definitionIDs.contains(
                          result.itemDefinitionID
                      ),
                      !result.unitOriginal.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty,
                      let parsed = try? LabDecimalValue.parse(
                          result.rawValueOriginal
                      ) else {
                          return false
                      }
                      return parsed.comparator?.rawValue
                          == result.comparatorRawValue
                          && parsed.canonicalDecimal
                            == result.canonicalDecimalString
                  }) else {
                throw failure
            }
        }
        guard correctedResults.allSatisfy({
            labCorrectionByID[$0.correctionSnapshotID] != nil
        }),
        statusCorrections.allSatisfy({
            $0.createdAt.timeIntervalSince1970.isFinite
                && $0.timestamp != nil
                && metricIDs.contains($0.metricDefinitionID)
                && !$0.metricNameSnapshot.isEmpty
                && (1...4).contains($0.ordinalLevel)
        }),
        tombstones.allSatisfy({
            $0.deletedAt.timeIntervalSince1970.isFinite
                && $0.attachmentCount >= 0
                && $0.attachmentByteCount >= 0
                && isDigest($0.priorFactsDigest)
                && isDigest($0.impactDigest)
                && ParentRecordDeletionAttachmentManifest.decode(
                    $0.attachmentManifest
                )?.count == $0.attachmentCount
                && $0.parentTypeRawValue
                    == ParentRecordType(
                        rawValue: $0.parentTypeRawValue
                    )?.rawValue
                && $0.parentKey
                    == ParentRecordType(
                        rawValue: $0.parentTypeRawValue
                    )?.recordKey(parentID: $0.parentID)
        }) else {
            throw failure
        }

        let mutationReceiptType = "ParentRecordMutationEventRecord"
        let labCreationReceiptType = "LabSampleRecord"
        let statusCreationReceiptType = "StatusObservationRecord"
        let attachmentReceiptType = "AttachmentRecord"
        var receiptDescriptor =
            FetchDescriptor<OperationReceiptRecord>(
                predicate: #Predicate {
                    $0.resultRecordType == mutationReceiptType
                        || $0.resultRecordType
                            == labCreationReceiptType
                        || $0.resultRecordType
                            == statusCreationReceiptType
                        || $0.resultRecordType
                            == attachmentReceiptType
                }
            )
        receiptDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumRelevantReceipts + 1
        let receipts = try context.fetch(receiptDescriptor)
        guard receipts.count
                <= ParentRecordLifecycleCapacity
                    .maximumRelevantReceipts else {
            throw failure
        }
        let receiptByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )
        var attachmentDescriptor = FetchDescriptor<AttachmentRecord>()
        attachmentDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumAttachments + 1
        let attachments = try context.fetch(attachmentDescriptor)
        guard attachments.count
                <= ParentRecordLifecycleCapacity.maximumAttachments else {
            throw failure
        }
        let attachmentByID = try AppDataIndex.checkedUniqueMap(
            attachments,
            keyedBy: \.id,
            failure: failure
        )
        var lifecycleRevisions: [RecordRevision] = []
        let revisionTypes: [(recordType: String, fetchLimit: Int)] = [
            (
                "ParentRecordLifecycleHeadRecord",
                ParentRecordLifecycleCapacity.maximumParents + 1
            ),
            (
                "ParentRecordMutationEventRecord",
                ParentRecordLifecycleCapacity.maximumEvents + 1
            ),
            (
                "LabSampleCorrectionSnapshotRecord",
                ParentRecordLifecycleCapacity.maximumEvents + 1
            ),
            (
                "LabResultCorrectionSnapshotRecord",
                ParentRecordLifecycleCapacity
                    .maximumCorrectedLabResults + 1
            ),
            (
                "StatusObservationCorrectionSnapshotRecord",
                ParentRecordLifecycleCapacity.maximumEvents + 1
            ),
            (
                "ParentRecordDeletionTombstoneRecord",
                ParentRecordLifecycleCapacity.maximumParents + 1
            ),
            (
                "AttachmentRecord",
                ParentRecordLifecycleCapacity.maximumAttachments + 1
            )
        ]
        for revisionType in revisionTypes {
            let records = try revisions(
                recordType: revisionType.recordType,
                fetchLimit: revisionType.fetchLimit,
                in: context
            )
            guard records.count < revisionType.fetchLimit else {
                throw failure
            }
            lifecycleRevisions += records
        }
        for receipt in receipts {
            let records = try revisions(
                recordType: "OperationReceiptRecord",
                recordID: receipt.operationID,
                in: context
            )
            guard records.count == 1 else {
                throw failure
            }
            lifecycleRevisions += records
        }
        let lifecycleRevisionByKey =
            try AppDataIndex.checkedUniqueMap(
                lifecycleRevisions,
                keyedBy: \.recordKey,
                failure: failure
            )
        let mutationEvents = events.filter {
            $0.kind == .corrected || $0.kind == .deleted
        }
        let mutationReceipts = receipts.filter {
            $0.resultRecordType
                == "ParentRecordMutationEventRecord"
        }
        let mutationEventByOperationID =
            try AppDataIndex.checkedUniqueMap(
                mutationEvents,
                keyedBy: \.operationID,
                failure: failure
            )
        guard mutationReceipts.count == mutationEvents.count,
              mutationReceipts.allSatisfy({ receipt in
                  guard let event =
                    mutationEventByOperationID[receipt.operationID]
                  else {
                      return false
                  }
                  return receipt.resultRecordID == event.id
              }) else {
            throw failure
        }
        let eventsByParent = Dictionary(
            grouping: events,
            by: {
                $0.parentTypeRawValue + ":"
                    + $0.parentID.uuidString.lowercased()
            }
        )
        var rootEntries: [(String, String)] = []
        var referencedLabCorrections = Set<UUID>()
        var referencedStatusCorrections = Set<UUID>()
        var referencedTombstones = Set<UUID>()
        var verifiedEventIDs = Set<UUID>()
        for head in heads {
            guard let type = head.parentType,
                  let lifecycle = head.lifecycle,
                  head.parentKey == type.recordKey(parentID: head.parentID),
                  head.eventCount > 0,
                  head.eventCount
                    <= ParentRecordLifecycleCapacity
                        .maximumEventCount(for: lifecycle),
                  head.effectiveTimestamp != nil,
                  let parentEvents = eventsByParent[head.parentKey],
                  parentEvents.count == head.eventCount,
                  let latest = eventByID[head.latestEventID],
                  latest.parentType == type,
                  latest.parentID == head.parentID,
                  head.latestPayloadID == latest.payloadID,
                  head.updatedAt.timeIntervalSince1970.isFinite else {
                throw failure
            }
            let headLocalRevision = try verifiedLocalRevision(
                recordType: "ParentRecordLifecycleHeadRecord",
                recordID:
                    ParentRecordLifecycleBackfill.stableHeadID(
                        for: head.parentKey
                    ),
                fields: try ParentRecordLifecycleDigest.head(head),
                committedAt: head.updatedAt,
                revisionByKey: lifecycleRevisionByKey,
                failure: failure
            )
            let predecessorIDs = parentEvents.compactMap(
                \.previousEventID
            )
            let successorCounts = Dictionary(
                grouping: predecessorIDs,
                by: { $0 }
            ).mapValues(\.count)
            guard successorCounts.values.allSatisfy({ $0 == 1 }) else {
                throw failure
            }
            var visited = Set<UUID>()
            var cursor: ParentRecordMutationEventRecord? = latest
            var successor: ParentRecordMutationEventRecord?
            while let current = cursor {
                guard visited.insert(current.id).inserted,
                      current.postFactsDigest.count == 64,
                      current.preFactsDigest.count == 64 else {
                    throw failure
                }
                guard current.parentType == type,
                      current.parentID == head.parentID else {
                    throw failure
                }
                let currentLocalRevision =
                    try verifiedLocalRevision(
                        recordType:
                            "ParentRecordMutationEventRecord",
                        recordID: current.id,
                        fields:
                            try ParentRecordLifecycleDigest.event(
                                current
                            ),
                        committedAt: current.committedAt,
                        revisionByKey: lifecycleRevisionByKey,
                        failure: failure
                    )
                guard current.id != head.latestEventID
                        || currentLocalRevision
                            == headLocalRevision else {
                    throw failure
                }
                let expectedPostDigest: String
                switch current.kind {
                case .migratedSnapshot, .createdSnapshot:
                    guard current.previousEventID == nil,
                          current.expectedHeadEventCount == nil,
                          current.expectedHeadLocalRevision == nil,
                          current.payloadRecordType == nil,
                          current.payloadID == nil else {
                        throw failure
                    }
                    switch type {
                    case .labSample:
                        let timeKey =
                            type.sourceRecordType + ":"
                            + head.parentID.uuidString.lowercased()
                        guard let sample =
                                labParentByID[head.parentID],
                              let time = timeByKey[timeKey] else {
                            throw failure
                        }
                        expectedPostDigest =
                            try ParentRecordLifecycleDigest
                                .labBaseFacts(
                                    sample: sample,
                                    results:
                                        baseResultsBySample[
                                            sample.id,
                                            default: []
                                        ],
                                    time: time
                                )
                    case .statusObservation:
                        let timeKey =
                            type.sourceRecordType + ":"
                            + head.parentID.uuidString.lowercased()
                        guard let observation =
                                statusParentByID[head.parentID],
                              let time = timeByKey[timeKey] else {
                            throw failure
                        }
                        expectedPostDigest =
                            try ParentRecordLifecycleDigest
                                .statusBaseFacts(
                                    observation: observation,
                                    time: time
                                )
                    }
                    guard current.preFactsDigest
                            == expectedPostDigest else {
                        throw failure
                    }
                    if current.kind == .migratedSnapshot {
                        guard current.commandDigest
                                == expectedPostDigest,
                              receiptByOperationID[
                                  current.operationID
                              ] == nil else {
                            throw failure
                        }
                        rootEntries.append(
                            (head.parentKey, expectedPostDigest)
                        )
                    } else {
                        guard let receipt =
                                receiptByOperationID[
                                    current.operationID
                                ],
                              receipt.commandDigest
                                == current.commandDigest,
                              receipt.resultRecordType
                                == (
                                    type == .labSample
                                        ? "LabSampleRecord"
                                        : "StatusObservationRecord"
                                ),
                              receipt.resultRecordID
                                == head.parentID else {
                            throw failure
                        }
                        let receiptLocalRevision =
                            try verifiedLocalRevision(
                                recordType:
                                    "OperationReceiptRecord",
                                recordID: receipt.operationID,
                                fields:
                                    try TodayExecutionDigestV1
                                        .operationReceipt(receipt),
                                committedAt: receipt.committedAt,
                                revisionByKey:
                                    lifecycleRevisionByKey,
                                failure: failure
                            )
                        guard receiptLocalRevision
                                == currentLocalRevision else {
                            throw failure
                        }
                    }
                case .corrected:
                    guard current.previousEventID != nil,
                          let expectedHeadEventCount =
                            current.expectedHeadEventCount,
                          expectedHeadEventCount
                            == head.eventCount - visited.count,
                          let expectedHeadLocalRevision =
                            current.expectedHeadLocalRevision,
                          expectedHeadLocalRevision > 0,
                          let payloadID = current.payloadID,
                          let receipt =
                            receiptByOperationID[
                                current.operationID
                            ],
                          receipt.resultRecordType
                            == "ParentRecordMutationEventRecord",
                          receipt.resultRecordID == current.id,
                          receipt.commandDigest
                            == current.commandDigest,
                          receipt.committedAt
                            == current.committedAt else {
                        throw failure
                    }
                    let previousEventID =
                        try requiredPreviousEventID(
                            current,
                            failure: failure
                        )
                    guard let previousEvent =
                            eventByID[previousEventID] else {
                        throw failure
                    }
                    let previousLocalRevision =
                        try verifiedLocalRevision(
                            recordType:
                                "ParentRecordMutationEventRecord",
                            recordID: previousEvent.id,
                            fields:
                                try ParentRecordLifecycleDigest.event(
                                    previousEvent
                                ),
                            committedAt: previousEvent.committedAt,
                            revisionByKey:
                                lifecycleRevisionByKey,
                            failure: failure
                        )
                    let receiptLocalRevision =
                        try verifiedLocalRevision(
                            recordType: "OperationReceiptRecord",
                            recordID: receipt.operationID,
                            fields:
                                try TodayExecutionDigestV1
                                    .operationReceipt(receipt),
                            committedAt: receipt.committedAt,
                            revisionByKey:
                                lifecycleRevisionByKey,
                            failure: failure
                        )
                    guard expectedHeadLocalRevision
                            == previousLocalRevision,
                          receiptLocalRevision
                            == currentLocalRevision else {
                        throw failure
                    }
                    let expectedHead = ParentRecordHeadToken(
                        latestEventID: previousEventID,
                        eventCount: expectedHeadEventCount,
                        localRevision: expectedHeadLocalRevision,
                        factsDigest: current.preFactsDigest
                    )
                    let expectedCommandDigest: String
                    switch type {
                    case .labSample:
                        guard current.payloadRecordType
                                == "LabSampleCorrectionSnapshotRecord",
                              let snapshot =
                                labCorrectionByID[payloadID],
                              snapshot.eventID == current.id,
                              snapshot.parentID == head.parentID,
                              referencedLabCorrections.insert(
                                  payloadID
                              ).inserted,
                              snapshot.createdAt == current.committedAt,
                              let timestamp = snapshot.timestamp else {
                            throw failure
                        }
                        let snapshotLocalRevision =
                            try verifiedLocalRevision(
                                recordType:
                                    "LabSampleCorrectionSnapshotRecord",
                                recordID: snapshot.id,
                                fields:
                                    try ParentRecordLifecycleDigest
                                        .labCorrection(snapshot),
                                committedAt: snapshot.createdAt,
                                revisionByKey:
                                    lifecycleRevisionByKey,
                                failure: failure
                            )
                        guard snapshotLocalRevision
                                == currentLocalRevision else {
                            throw failure
                        }
                        let persistedResults =
                            correctedResultsBySnapshot[
                                snapshot.id,
                                default: []
                            ].sorted(by: { $0.sortOrder < $1.sortOrder })
                        let inputs = persistedResults.map {
                            CorrectedLabResultInput(
                                logicalResultID: $0.logicalResultID,
                                itemDefinitionID: $0.itemDefinitionID,
                                rawValueOriginal: $0.rawValueOriginal,
                                unitOriginal: $0.unitOriginal,
                                referenceRangeOriginal:
                                    $0.referenceRangeOriginal,
                                assayOrVariantOriginal:
                                    $0.assayOrVariantOriginal
                            )
                        }
                        let normalized = try persistedResults.map {
                            NormalizedCorrectedLabResult(
                                id: $0.logicalResultID,
                                itemDefinitionID: $0.itemDefinitionID,
                                itemName: $0.itemNameSnapshot,
                                itemCode: $0.itemCodeSnapshot,
                                value: try LabDecimalValue.parse(
                                    $0.rawValueOriginal
                                ),
                                unit: $0.unitOriginal,
                                referenceRange:
                                    $0.referenceRangeOriginal,
                                variant: $0.assayOrVariantOriginal
                            )
                        }
                        for result in persistedResults {
                            let resultLocalRevision =
                                try verifiedLocalRevision(
                                    recordType:
                                        "LabResultCorrectionSnapshotRecord",
                                    recordID: result.id,
                                    fields:
                                        ParentRecordLifecycleDigest
                                            .labResultCorrection(
                                                result
                                            ),
                                    committedAt:
                                        current.committedAt,
                                    revisionByKey:
                                        lifecycleRevisionByKey,
                                    failure: failure
                                )
                            guard resultLocalRevision
                                    == currentLocalRevision else {
                                throw failure
                            }
                        }
                        expectedCommandDigest =
                            try ParentRecordLifecycleCommandDigest
                                .correctLab(
                                    CorrectLabSampleCommand(
                                        operationID: current.operationID,
                                        correctionID: snapshot.id,
                                        eventID: current.id,
                                        parentID: head.parentID,
                                        expectedHead: expectedHead,
                                        timestamp: timestamp,
                                        specimenOriginal:
                                            snapshot.specimenOriginal,
                                        contextNote: snapshot.contextNote,
                                        results: inputs,
                                        committedAt: current.committedAt
                                    ),
                                    normalized: normalized
                                )
                        expectedPostDigest =
                            try ParentRecordLifecycleDigest
                                .labCorrectionFacts(
                                    snapshot: snapshot,
                                    results:
                                        correctedResultsBySnapshot[
                                            snapshot.id,
                                            default: []
                                        ]
                                )
                    case .statusObservation:
                        guard current.payloadRecordType
                                == "StatusObservationCorrectionSnapshotRecord",
                              let snapshot =
                                statusCorrectionByID[payloadID],
                              snapshot.eventID == current.id,
                              snapshot.parentID == head.parentID,
                              referencedStatusCorrections.insert(
                                  payloadID
                              ).inserted,
                              snapshot.createdAt == current.committedAt,
                              let timestamp = snapshot.timestamp else {
                            throw failure
                        }
                        let snapshotLocalRevision =
                            try verifiedLocalRevision(
                                recordType:
                                    "StatusObservationCorrectionSnapshotRecord",
                                recordID: snapshot.id,
                                fields:
                                    try ParentRecordLifecycleDigest
                                        .statusCorrection(snapshot),
                                committedAt: snapshot.createdAt,
                                revisionByKey:
                                    lifecycleRevisionByKey,
                                failure: failure
                            )
                        guard snapshotLocalRevision
                                == currentLocalRevision else {
                            throw failure
                        }
                        expectedCommandDigest =
                            try ParentRecordLifecycleCommandDigest
                                .correctStatus(
                                    CorrectStatusObservationCommand(
                                        operationID: current.operationID,
                                        correctionID: snapshot.id,
                                        eventID: current.id,
                                        parentID: head.parentID,
                                        expectedHead: expectedHead,
                                        metricDefinitionID:
                                            snapshot.metricDefinitionID,
                                        ordinalLevel:
                                            snapshot.ordinalLevel,
                                        note: snapshot.note,
                                        timestamp: timestamp,
                                        committedAt: current.committedAt
                                    )
                                )
                        expectedPostDigest =
                            try ParentRecordLifecycleDigest
                                .statusCorrectionFacts(snapshot)
                    }
                    guard current.commandDigest
                            == expectedCommandDigest else {
                        throw failure
                    }
                case .deleted:
                    guard current.previousEventID != nil,
                          let expectedHeadEventCount =
                            current.expectedHeadEventCount,
                          expectedHeadEventCount
                            == head.eventCount - visited.count,
                          let expectedHeadLocalRevision =
                            current.expectedHeadLocalRevision,
                          expectedHeadLocalRevision > 0,
                          current.payloadRecordType
                            == "ParentRecordDeletionTombstoneRecord",
                          let payloadID = current.payloadID,
                          let tombstone = tombstoneByID[payloadID],
                          tombstone.eventID == current.id,
                          tombstone.parentID == head.parentID,
                          tombstone.parentTypeRawValue == type.rawValue,
                          tombstone.priorFactsDigest
                            == current.preFactsDigest,
                          tombstone.deletedAt == current.committedAt,
                          referencedTombstones.insert(
                              payloadID
                          ).inserted,
                          let receipt =
                            receiptByOperationID[
                                current.operationID
                            ],
                          receipt.resultRecordType
                            == "ParentRecordMutationEventRecord",
                          receipt.resultRecordID == current.id,
                          receipt.commandDigest
                            == current.commandDigest,
                          receipt.committedAt
                            == current.committedAt,
                          let manifestEntries =
                            ParentRecordDeletionAttachmentManifest
                                .decode(tombstone.attachmentManifest) else {
                        throw failure
                    }
                    let previousEventID =
                        try requiredPreviousEventID(
                            current,
                            failure: failure
                        )
                    guard let previousEvent =
                            eventByID[previousEventID] else {
                        throw failure
                    }
                    let previousLocalRevision =
                        try verifiedLocalRevision(
                            recordType:
                                "ParentRecordMutationEventRecord",
                            recordID: previousEvent.id,
                            fields:
                                try ParentRecordLifecycleDigest.event(
                                    previousEvent
                                ),
                            committedAt: previousEvent.committedAt,
                            revisionByKey:
                                lifecycleRevisionByKey,
                            failure: failure
                        )
                    let receiptLocalRevision =
                        try verifiedLocalRevision(
                            recordType: "OperationReceiptRecord",
                            recordID: receipt.operationID,
                            fields:
                                try TodayExecutionDigestV1
                                    .operationReceipt(receipt),
                            committedAt: receipt.committedAt,
                            revisionByKey:
                                lifecycleRevisionByKey,
                            failure: failure
                        )
                    let tombstoneLocalRevision =
                        try verifiedLocalRevision(
                            recordType:
                                "ParentRecordDeletionTombstoneRecord",
                            recordID: tombstone.id,
                            fields:
                                try ParentRecordLifecycleDigest
                                    .tombstone(tombstone),
                            committedAt: tombstone.deletedAt,
                            revisionByKey:
                                lifecycleRevisionByKey,
                            failure: failure
                        )
                    guard expectedHeadLocalRevision
                            == previousLocalRevision,
                          receiptLocalRevision
                            == currentLocalRevision,
                          tombstoneLocalRevision
                            == currentLocalRevision else {
                        throw failure
                    }
                    let expectedHead = ParentRecordHeadToken(
                        latestEventID: previousEventID,
                        eventCount: expectedHeadEventCount,
                        localRevision: expectedHeadLocalRevision,
                        factsDigest: current.preFactsDigest
                    )
                    var commandAttachments:
                        [ParentRecordDeletionAttachment] = []
                    var attachmentByteCount: Int64 = 0
                    let expectedOwnerType: AttachmentOwnerType =
                        type == .labSample
                            ? .labSample : .statusObservation
                    for entry in manifestEntries {
                        guard let attachment =
                                attachmentByID[entry.attachmentID],
                              attachment.ownerType == expectedOwnerType,
                              attachment.ownerID == head.parentID,
                              attachment.sha256Hex == entry.sha256Hex,
                              attachment.deleteOperationID
                                == entry.deletionOperationID,
                              attachment.deletedAt
                                == current.committedAt,
                              let snapshot =
                                AttachmentSnapshot(attachment),
                              let deletionReceipt =
                                receiptByOperationID[
                                    entry.deletionOperationID
                                ],
                              deletionReceipt.resultRecordType
                                == "AttachmentRecord",
                              deletionReceipt.resultRecordID
                                == attachment.id,
                              deletionReceipt.committedAt
                                == current.committedAt,
                              deletionReceipt.commandDigest
                                == (try AttachmentDigestV1.deleteCommand(
                                    DeleteAttachmentCommand(
                                        operationID:
                                            entry.deletionOperationID,
                                        attachmentID: attachment.id,
                                        committedAt:
                                            current.committedAt
                                    )
                                )) else {
                            throw failure
                        }
                        let attachmentLocalRevision =
                            try verifiedLocalRevision(
                                recordType: "AttachmentRecord",
                                recordID: attachment.id,
                                fields:
                                    try AttachmentDigestV1.record(
                                        attachment
                                    ),
                                committedAt:
                                    current.committedAt,
                                revisionByKey:
                                    lifecycleRevisionByKey,
                                failure: failure
                            )
                        let deletionReceiptLocalRevision =
                            try verifiedLocalRevision(
                                recordType:
                                    "OperationReceiptRecord",
                                recordID:
                                    deletionReceipt.operationID,
                                fields:
                                    try TodayExecutionDigestV1
                                        .operationReceipt(
                                            deletionReceipt
                                        ),
                                committedAt:
                                    deletionReceipt.committedAt,
                                revisionByKey:
                                    lifecycleRevisionByKey,
                                failure: failure
                            )
                        guard attachmentLocalRevision
                                == currentLocalRevision,
                              deletionReceiptLocalRevision
                                == currentLocalRevision else {
                            throw failure
                        }
                        let addition =
                            attachmentByteCount.addingReportingOverflow(
                                attachment.byteCount
                            )
                        guard !addition.overflow else { throw failure }
                        attachmentByteCount = addition.partialValue
                        commandAttachments.append(
                            ParentRecordDeletionAttachment(
                                attachment: snapshot,
                                deletionOperationID:
                                    entry.deletionOperationID
                            )
                        )
                    }
                    guard attachmentByteCount
                            == tombstone.attachmentByteCount else {
                        throw failure
                    }
                    let effectiveResultCount: Int
                    switch type {
                    case .labSample:
                        let previousEventID =
                            try requiredPreviousEventID(
                                current,
                                failure: failure
                            )
                        guard let previous = eventByID[previousEventID]
                        else {
                            throw failure
                        }
                        switch previous.kind {
                        case .migratedSnapshot, .createdSnapshot:
                            effectiveResultCount =
                                baseResultsBySample[
                                    head.parentID,
                                    default: []
                                ].count
                        case .corrected:
                            guard let correctionID = previous.payloadID
                            else {
                                throw failure
                            }
                            effectiveResultCount =
                                correctedResultsBySnapshot[
                                    correctionID,
                                    default: []
                                ].count
                        case .deleted, .none:
                            throw failure
                        }
                    case .statusObservation:
                        effectiveResultCount = 0
                    }
                    let expectedImpactDigest =
                        try ParentRecordLifecycleCommandDigest.impact(
                            type: type,
                            parentID: head.parentID,
                            token: expectedHead,
                            effectiveResultCount: effectiveResultCount,
                            correctionCount:
                                expectedHead.eventCount - 1,
                            attachments:
                                commandAttachments.map(\.attachment)
                        )
                    guard expectedImpactDigest
                            == tombstone.impactDigest else {
                        throw failure
                    }
                    let expectedCommandDigest =
                        try ParentRecordLifecycleCommandDigest.delete(
                            DeleteParentRecordCommand(
                                operationID: current.operationID,
                                eventID: current.id,
                                tombstoneID: tombstone.id,
                                parentType: type,
                                parentID: head.parentID,
                                expectedHead: expectedHead,
                                expectedImpactDigest:
                                    expectedImpactDigest,
                                attachments: commandAttachments,
                                committedAt: current.committedAt
                            )
                        )
                    guard current.commandDigest
                            == expectedCommandDigest else {
                        throw failure
                    }
                    expectedPostDigest =
                        try RecordDigestV1.sha256Hex(
                            recordType:
                                "ParentRecordDeletionTombstoneRecord",
                            recordID: tombstone.id,
                            fields:
                                try ParentRecordLifecycleDigest
                                    .tombstone(tombstone)
                        )
                case .none:
                    throw failure
                }
                guard current.postFactsDigest == expectedPostDigest else {
                    throw failure
                }
                if let successor,
                   successor.preFactsDigest != current.postFactsDigest {
                    throw failure
                }
                successor = current
                if let previousID = current.previousEventID {
                    cursor = eventByID[previousID]
                } else {
                    cursor = nil
                    guard current.kind == .migratedSnapshot
                            || current.kind == .createdSnapshot,
                          current.preFactsDigest
                            == current.postFactsDigest else {
                        throw failure
                    }
                }
            }
            let effectiveEvent: ParentRecordMutationEventRecord
            if lifecycle == .deleted {
                guard latest.kind == .deleted,
                      let previousID = latest.previousEventID,
                      let predecessor = eventByID[previousID] else {
                    throw failure
                }
                effectiveEvent = predecessor
                let activeOwnerAttachments = attachments.filter {
                    $0.deletedAt == nil
                        && $0.ownerID == head.parentID
                        && (
                            type == .labSample
                                ? $0.ownerType == .labSample
                                : $0.ownerType
                                    == .statusObservation
                        )
                }
                guard activeOwnerAttachments.isEmpty else {
                    throw failure
                }
            } else {
                guard latest.kind != .deleted else {
                    throw failure
                }
                effectiveEvent = latest
            }
            let expectedTimestamp: HistoricalTimestamp
            switch effectiveEvent.kind {
            case .migratedSnapshot, .createdSnapshot:
                let timeKey =
                    type.sourceRecordType + ":"
                    + head.parentID.uuidString.lowercased()
                guard let timestamp =
                        timeByKey[timeKey]?.historicalTimestamp else {
                    throw failure
                }
                expectedTimestamp = timestamp
            case .corrected:
                guard let payloadID = effectiveEvent.payloadID else {
                    throw failure
                }
                switch type {
                case .labSample:
                    guard let timestamp =
                            labCorrectionByID[payloadID]?.timestamp else {
                        throw failure
                    }
                    expectedTimestamp = timestamp
                case .statusObservation:
                    guard let timestamp =
                            statusCorrectionByID[payloadID]?.timestamp
                    else {
                        throw failure
                    }
                    expectedTimestamp = timestamp
                }
            case .deleted, .none:
                throw failure
            }
            guard visited.count == parentEvents.count,
                  verifiedEventIDs.isDisjoint(with: visited),
                  head.effectiveTimestamp == expectedTimestamp else {
                throw failure
            }
            verifiedEventIDs.formUnion(visited)
        }
        guard Set(eventsByParent.keys) == Set(headByKey.keys),
              verifiedEventIDs == Set(eventByID.keys),
              referencedLabCorrections.count
                == labCorrections.count,
              referencedStatusCorrections.count
                == statusCorrections.count,
              referencedTombstones.count == tombstones.count,
              rootEntries.filter({
                  $0.0.hasPrefix(
                      ParentRecordType.labSample.rawValue + ":"
                  )
              }).count == state.labParentCount,
              rootEntries.filter({
                  $0.0.hasPrefix(
                      ParentRecordType.statusObservation.rawValue
                          + ":"
                  )
              }).count == state.statusParentCount,
              try ParentRecordLifecycleDigest.rootSet(rootEntries)
                == state.rootSetDigest else {
            throw failure
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func verifiedLocalRevision(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        committedAt: Date,
        revisionByKey: [String: RecordRevision],
        failure: Error
    ) throws -> Int64 {
        let recordKey =
            recordType + ":" + recordID.uuidString.lowercased()
        guard let revision = revisionByKey[recordKey],
              revision.recordKey == recordKey,
              revision.recordType == recordType,
              revision.recordID == recordID,
              revision.localRevision > 0,
              revision.digestVersion == RecordDigestV1.version,
              revision.committedAt == committedAt,
              revision.digestHex
                == (try RecordDigestV1.sha256Hex(
                    recordType: recordType,
                    recordID: recordID,
                    fields: fields
                )) else {
            throw failure
        }
        return revision.localRevision
    }

    private static func revisions(
        recordType: String,
        fetchLimit: Int,
        in context: ModelContext
    ) throws -> [RecordRevision] {
        let expectedRecordType = recordType
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordType == expectedRecordType
            }
        )
        descriptor.fetchLimit = fetchLimit
        return try context.fetch(descriptor)
    }

    private static func revisions(
        recordType: String,
        recordID: UUID,
        in context: ModelContext
    ) throws -> [RecordRevision] {
        let expectedRecordType = recordType
        let expectedRecordID = recordID
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordType == expectedRecordType
                    && $0.recordID == expectedRecordID
            }
        )
        descriptor.fetchLimit = 2
        return try context.fetch(descriptor)
    }

    private static func requiredPreviousEventID(
        _ event: ParentRecordMutationEventRecord,
        failure: Error
    ) throws -> UUID {
        guard let previousEventID = event.previousEventID else {
            throw failure
        }
        return previousEventID
    }
}
