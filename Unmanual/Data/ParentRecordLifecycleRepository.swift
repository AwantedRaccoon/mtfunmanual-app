import Foundation
import SwiftData

struct NormalizedCorrectedLabResult {
    let id: UUID
    let itemDefinitionID: UUID
    let itemName: String
    let itemCode: String
    let value: LabDecimalValue
    let unit: String
    let referenceRange: String?
    let variant: String?
}

extension AppReadActor {
    func labSample(id: UUID) throws -> LabSampleSnapshot? {
        guard supportsParentRecordLifecycle else {
            return try baseLabSample(id: id)
        }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        return try parentRecordLabSampleUnchecked(id: id)
    }

    func parentRecordLabSampleUnchecked(
        id: UUID
    ) throws -> LabSampleSnapshot? {
        guard let head = try parentHead(type: .labSample, id: id) else {
            return nil
        }
        guard head.lifecycle == .active else { return nil }
        guard let latest = try parentEvent(id: head.latestEventID) else {
            throw AppDataFailure.corruptionSuspected
        }
        switch latest.kind {
        case .migratedSnapshot, .createdSnapshot:
            return try baseLabSample(id: id)
        case .corrected:
            guard let payloadID = latest.payloadID else {
                throw AppDataFailure.corruptionSuspected
            }
            return try correctedLabSample(
                parentID: id,
                correctionID: payloadID
            )
        case .deleted, .none:
            return nil
        }
    }

    func statusObservation(id: UUID) throws
        -> StatusObservationSnapshot? {
        guard supportsParentRecordLifecycle else {
            return try baseStatusObservation(id: id)
        }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        return try parentRecordStatusObservationUnchecked(id: id)
    }

    func parentRecordStatusObservationUnchecked(
        id: UUID
    ) throws -> StatusObservationSnapshot? {
        guard let head = try parentHead(
            type: .statusObservation,
            id: id
        ) else {
            return nil
        }
        guard head.lifecycle == .active else { return nil }
        guard let latest = try parentEvent(id: head.latestEventID) else {
            throw AppDataFailure.corruptionSuspected
        }
        switch latest.kind {
        case .migratedSnapshot, .createdSnapshot:
            return try baseStatusObservation(id: id)
        case .corrected:
            guard let payloadID = latest.payloadID else {
                throw AppDataFailure.corruptionSuspected
            }
            return try correctedStatusObservation(
                parentID: id,
                correctionID: payloadID
            )
        case .deleted, .none:
            return nil
        }
    }

    func parentRecordHeadToken(
        type: ParentRecordType,
        id: UUID
    ) throws -> ParentRecordHeadToken? {
        guard supportsParentRecordLifecycle else { return nil }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        guard let head = try parentHead(type: type, id: id),
              let event = try parentEvent(id: head.latestEventID) else {
            return nil
        }
        let revisionID =
            ParentRecordLifecycleBackfill.stableHeadID(for: head.parentKey)
        let revisionKey =
            "ParentRecordLifecycleHeadRecord:"
            + revisionID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == revisionKey }
        )
        descriptor.fetchLimit = 2
        let revisions = try modelContext.fetch(descriptor)
        let expectedHeadDigest = try RecordDigestV1.sha256Hex(
            recordType: "ParentRecordLifecycleHeadRecord",
            recordID: revisionID,
            fields: try ParentRecordLifecycleDigest.head(head)
        )
        guard revisions.count == 1,
              let revision = revisions.first,
              revision.digestHex == expectedHeadDigest else {
            throw AppDataFailure.corruptionSuspected
        }
        return ParentRecordHeadToken(
            latestEventID: head.latestEventID,
            eventCount: head.eventCount,
            localRevision: revision.localRevision,
            factsDigest: event.postFactsDigest
        )
    }

    func parentRecordDeletionImpact(
        type: ParentRecordType,
        id: UUID
    ) throws -> ParentRecordDeletionImpact {
        guard let token = try parentRecordHeadToken(type: type, id: id),
              let head = try parentHead(type: type, id: id) else {
            throw AppDataFailure.corruptionSuspected
        }
        guard head.lifecycle == .active else {
            throw AppDataFailure.corruptionSuspected
        }
        let ownerType: AttachmentOwnerType =
            type == .labSample ? .labSample : .statusObservation
        let activeAttachments = try attachments(
            ownerType: ownerType,
            ownerID: id
        ).sorted { $0.id.uuidString < $1.id.uuidString }
        var totalBytes: Int64 = 0
        for attachment in activeAttachments {
            let sum = totalBytes.addingReportingOverflow(
                attachment.byteCount
            )
            guard !sum.overflow else {
                throw AppDataFailure.corruptionSuspected
            }
            totalBytes = sum.partialValue
        }
        let resultCount: Int
        switch type {
        case .labSample:
            resultCount = try labSample(id: id)?.results.count ?? 0
        case .statusObservation:
            resultCount = 0
        }
        let correctionCount = max(0, head.eventCount - 1)
        let digest = try ParentRecordLifecycleCommandDigest.impact(
            type: type,
            parentID: id,
            token: token,
            effectiveResultCount: resultCount,
            correctionCount: correctionCount,
            attachments: activeAttachments
        )
        return ParentRecordDeletionImpact(
            parentType: type,
            parentID: id,
            expectedHead: token,
            effectiveResultCount: resultCount,
            correctionCount: correctionCount,
            attachments: activeAttachments,
            attachmentByteCount: totalBytes,
            impactDigest: digest
        )
    }

    func parentRecordIsDeleted(
        type: ParentRecordType,
        id: UUID
    ) throws -> Bool {
        guard supportsParentRecordLifecycle else { return false }
        guard let head = try parentHead(type: type, id: id) else {
            return false
        }
        guard let lifecycle = head.lifecycle else {
            throw AppDataFailure.corruptionSuspected
        }
        return lifecycle == .deleted
    }

    private var supportsParentRecordLifecycle: Bool {
        modelContext.container.schema.entities.contains {
            $0.name == "ParentRecordLifecycleHeadRecord"
        }
    }

    private func parentHead(
        type: ParentRecordType,
        id: UUID
    ) throws -> ParentRecordLifecycleHeadRecord? {
        let key = type.recordKey(parentID: id)
        var descriptor =
            FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                predicate: #Predicate { $0.parentKey == key }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return records.first
    }

    private func parentEvent(
        id: UUID
    ) throws -> ParentRecordMutationEventRecord? {
        var descriptor =
            FetchDescriptor<ParentRecordMutationEventRecord>(
                predicate: #Predicate { $0.id == id }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return records.first
    }

    private func correctedLabSample(
        parentID: UUID,
        correctionID: UUID
    ) throws -> LabSampleSnapshot {
        var descriptor =
            FetchDescriptor<LabSampleCorrectionSnapshotRecord>(
                predicate: #Predicate { $0.id == correctionID }
            )
        descriptor.fetchLimit = 2
        let snapshots = try modelContext.fetch(descriptor)
        guard snapshots.count == 1,
              let snapshot = snapshots.first,
              snapshot.parentID == parentID,
              let timestamp = snapshot.timestamp,
              let associationState = HistoricalAssociationState(
                  rawValue: snapshot.associationStateRawValue
              ) else {
            throw AppDataFailure.corruptionSuspected
        }
        var resultDescriptor =
            FetchDescriptor<LabResultCorrectionSnapshotRecord>(
                predicate: #Predicate {
                    $0.correctionSnapshotID == correctionID
                },
                sortBy: [
                    SortDescriptor(\.sortOrder),
                    SortDescriptor(\.id)
                ]
            )
        resultDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumLabResultsPerSample + 1
        let results = try modelContext.fetch(resultDescriptor)
        guard results.count
                <= PersonalTimelineCapacity.maximumLabResultsPerSample,
              results.enumerated().allSatisfy({
                  $0.offset == $0.element.sortOrder
              }),
              Set(results.map(\.logicalResultID)).count == results.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let definitionIDs = Array(Set(results.map(\.itemDefinitionID)))
        var definitionDescriptor =
            FetchDescriptor<LabItemDefinitionRecord>(
                predicate: #Predicate {
                    definitionIDs.contains($0.id)
                }
            )
        definitionDescriptor.fetchLimit = definitionIDs.count + 1
        let definitions = try modelContext.fetch(definitionDescriptor)
        let definitionByID = try AppDataIndex.checkedUniqueMap(
            definitions,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        guard definitions.count == definitionIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        return LabSampleSnapshot(
            id: parentID,
            timestamp: timestamp,
            regimenVersionID: snapshot.resolvedRegimenVersionID,
            associationState: associationState,
            specimenOriginal: snapshot.specimenOriginal,
            contextNote: snapshot.contextNote,
            results: try results.map { result in
                guard let definition =
                        definitionByID[result.itemDefinitionID],
                      let kind = LabItemDefinitionKind(
                          rawValue: definition.kindRawValue
                      ) else {
                    throw AppDataFailure.corruptionSuspected
                }
                return LabResultSnapshot(
                    id: result.logicalResultID,
                    itemDefinitionID: result.itemDefinitionID,
                    itemDefinitionKind: kind,
                    bundledStableID: definition.bundledStableID,
                    itemNameSnapshot: result.itemNameSnapshot,
                    itemCodeSnapshot: result.itemCodeSnapshot,
                    rawValueOriginal: result.rawValueOriginal,
                    comparator: result.comparator,
                    canonicalDecimalString:
                        result.canonicalDecimalString,
                    unitOriginal: result.unitOriginal,
                    referenceRangeOriginal:
                        result.referenceRangeOriginal,
                    assayOrVariantOriginal:
                        result.assayOrVariantOriginal
                )
            }
        )
    }

    private func correctedStatusObservation(
        parentID: UUID,
        correctionID: UUID
    ) throws -> StatusObservationSnapshot {
        var descriptor =
            FetchDescriptor<StatusObservationCorrectionSnapshotRecord>(
                predicate: #Predicate { $0.id == correctionID }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let record = records.first,
              record.parentID == parentID,
              let timestamp = record.timestamp,
              let associationState = HistoricalAssociationState(
                  rawValue: record.associationStateRawValue
              ),
              (1...4).contains(record.ordinalLevel) else {
            throw AppDataFailure.corruptionSuspected
        }
        return StatusObservationSnapshot(
            id: parentID,
            metricDefinitionID: record.metricDefinitionID,
            metricNameSnapshot: record.metricNameSnapshot,
            ordinalLevel: record.ordinalLevel,
            note: record.note,
            timestamp: timestamp,
            regimenVersionID: record.resolvedRegimenVersionID,
            associationState: associationState
        )
    }
}

extension AppWriteActor {
    func insertCreatedLabParentRoot(
        sample: LabSampleRecord,
        results: [LabResultRecord],
        commandDigest: String,
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        guard supportsParentRecordLifecycle else { return }
        let time = try requiredParentBaseTime(
            type: .labSample,
            id: sample.id
        )
        let factsDigest =
            try ParentRecordLifecycleDigest.labBaseFacts(
                sample: sample,
                results: results,
                time: time
            )
        try insertCreatedParentRoot(
            type: .labSample,
            parentID: sample.id,
            operationID: sample.operationID,
            commandDigest: commandDigest,
            factsDigest: factsDigest,
            timestamp: try requiredTimestamp(time),
            reservation: reservation,
            committedAt: committedAt
        )
    }

    func insertCreatedStatusParentRoot(
        observation: StatusObservationRecord,
        commandDigest: String,
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        guard supportsParentRecordLifecycle else { return }
        let time = try requiredParentBaseTime(
            type: .statusObservation,
            id: observation.id
        )
        let factsDigest =
            try ParentRecordLifecycleDigest.statusBaseFacts(
                observation: observation,
                time: time
            )
        try insertCreatedParentRoot(
            type: .statusObservation,
            parentID: observation.id,
            operationID: observation.operationID,
            commandDigest: commandDigest,
            factsDigest: factsDigest,
            timestamp: try requiredTimestamp(time),
            reservation: reservation,
            committedAt: committedAt
        )
    }

    func validateParentRecordLifecycleAfterCreation() throws {
        guard supportsParentRecordLifecycle else { return }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
    }

    func correctLabSample(
        _ command: CorrectLabSampleCommand
    ) throws -> ParentRecordMutationResult {
        guard supportsParentRecordLifecycle,
              command.committedAt.timeIntervalSince1970.isFinite,
              command.results.count
                <= PersonalTimelineCapacity.maximumLabResultsPerSample,
              Set(command.results.map(\.logicalResultID)).count
                == command.results.count else {
            throw ParentRecordMutationFailure.invalidInput
        }
        let normalized = try normalizeCorrectedLabResults(command.results)
        let digest = try ParentRecordLifecycleCommandDigest
            .correctLab(command, normalized: normalized)
        if let replay = try parentMutationReplay(
            operationID: command.operationID,
            digest: digest,
            type: .labSample,
            parentID: command.parentID
        ) {
            return replay
        }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let head = try requiredParentHead(
            type: .labSample,
            id: command.parentID
        )
        try requireHead(head, matches: command.expectedHead)
        guard head.lifecycle == .active else {
            throw ParentRecordMutationFailure.alreadyDeleted
        }
        guard ParentRecordLifecycleCapacity.canAppendCorrection(
            toEventCount: head.eventCount
        ) else {
            throw ParentRecordMutationFailure.correctionLimitReached
        }
        let activeAttachments = try activeAttachmentCount(
            ownerType: .labSample,
            ownerID: command.parentID
        )
        guard !normalized.isEmpty || activeAttachments > 0 else {
            throw ParentRecordMutationFailure.invalidInput
        }
        let current = try effectiveLabFacts(parentID: command.parentID)
        guard !labCommand(command, normalized: normalized, equals: current)
        else {
            throw ParentRecordMutationFailure.noEffectiveChange
        }
        try requireAvailableLogicalResultIdentities(
            Set(normalized.map(\.id)),
            for: command.parentID
        )
        let association = try resolvedAssociationForWrite(
            timestamp: command.timestamp
        )
        let reservation = try reserveRevision(
            committedAt: command.committedAt
        )
        modelContext.autosaveEnabled = false
        do {
            var output: ParentRecordMutationResult?
            try modelContext.transaction {
                if let replay = try parentMutationReplay(
                    operationID: command.operationID,
                    digest: digest,
                    type: .labSample,
                    parentID: command.parentID
                ) {
                    output = replay
                    return
                }
                try requireHead(head, matches: command.expectedHead)
                guard head.lifecycle == .active else {
                    throw ParentRecordMutationFailure.alreadyDeleted
                }
                guard ParentRecordLifecycleCapacity.canAppendCorrection(
                    toEventCount: head.eventCount
                ) else {
                    throw ParentRecordMutationFailure
                        .correctionLimitReached
                }
                let snapshot = LabSampleCorrectionSnapshotRecord(
                    id: command.correctionID,
                    eventID: command.eventID,
                    parentID: command.parentID,
                    specimenOriginal: command.specimenOriginal,
                    contextNote: command.contextNote,
                    timestamp: command.timestamp,
                    resolvedRegimenVersionID: association.id,
                    associationState: association.state,
                    createdAt: command.committedAt
                )
                modelContext.insert(snapshot)
                var persistedResults:
                    [LabResultCorrectionSnapshotRecord] = []
                for (index, result) in normalized.enumerated() {
                    let persisted =
                        LabResultCorrectionSnapshotRecord(
                            correctionSnapshotID:
                                command.correctionID,
                            logicalResultID: result.id,
                            sortOrder: index,
                            itemDefinitionID:
                                result.itemDefinitionID,
                            itemNameSnapshot: result.itemName,
                            itemCodeSnapshot: result.itemCode,
                            rawValueOriginal: result.value.original,
                            comparator: result.value.comparator,
                            canonicalDecimalString:
                                result.value.canonicalDecimal,
                            unitOriginal: result.unit,
                            referenceRangeOriginal:
                                result.referenceRange,
                            assayOrVariantOriginal: result.variant
                        )
                    persistedResults.append(persisted)
                    modelContext.insert(persisted)
                }
                let postDigest =
                    try ParentRecordLifecycleDigest
                        .labCorrectionFacts(
                            snapshot: snapshot,
                            results: persistedResults
                        )
                let event = ParentRecordMutationEventRecord(
                    id: command.eventID,
                    parentType: .labSample,
                    parentID: command.parentID,
                    kind: .corrected,
                    previousEventID: head.latestEventID,
                    payloadRecordType:
                        "LabSampleCorrectionSnapshotRecord",
                    payloadID: snapshot.id,
                    operationID: command.operationID,
                    expectedHeadEventCount:
                        command.expectedHead.eventCount,
                    expectedHeadLocalRevision:
                        command.expectedHead.localRevision,
                    commandDigest: digest,
                    preFactsDigest:
                        command.expectedHead.factsDigest,
                    postFactsDigest: postDigest,
                    committedAt: command.committedAt
                )
                modelContext.insert(event)
                head.latestEventID = event.id
                head.latestPayloadID = snapshot.id
                head.eventCount += 1
                head.lifecycleRawValue =
                    ParentRecordLifecycle.active.rawValue
                head.replaceEffectiveTimestamp(command.timestamp)
                head.updatedAt = command.committedAt
                try upsertRevision(
                    recordType:
                        "LabSampleCorrectionSnapshotRecord",
                    recordID: snapshot.id,
                    fields:
                        try ParentRecordLifecycleDigest
                            .labCorrection(snapshot),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                for result in persistedResults {
                    try upsertRevision(
                        recordType:
                            "LabResultCorrectionSnapshotRecord",
                        recordID: result.id,
                        fields:
                            ParentRecordLifecycleDigest
                                .labResultCorrection(result),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                }
                try persistParentMutation(
                    event: event,
                    head: head,
                    commandDigest: digest,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try ParentRecordLifecycleValidator.validate(
                    in: modelContext,
                    failure: .corruptionSuspected
                )
                output = ParentRecordMutationResult(
                    parentType: .labSample,
                    parentID: command.parentID,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let output else {
                throw ParentRecordMutationFailure.invalidInput
            }
            return output
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func correctStatusObservation(
        _ command: CorrectStatusObservationCommand
    ) throws -> ParentRecordMutationResult {
        guard supportsParentRecordLifecycle,
              command.committedAt.timeIntervalSince1970.isFinite,
              (1...4).contains(command.ordinalLevel) else {
            throw ParentRecordMutationFailure.invalidInput
        }
        let digest =
            try ParentRecordLifecycleCommandDigest.correctStatus(command)
        if let replay = try parentMutationReplay(
            operationID: command.operationID,
            digest: digest,
            type: .statusObservation,
            parentID: command.parentID
        ) {
            return replay
        }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let head = try requiredParentHead(
            type: .statusObservation,
            id: command.parentID
        )
        try requireHead(head, matches: command.expectedHead)
        guard head.lifecycle == .active else {
            throw ParentRecordMutationFailure.alreadyDeleted
        }
        guard ParentRecordLifecycleCapacity.canAppendCorrection(
            toEventCount: head.eventCount
        ) else {
            throw ParentRecordMutationFailure.correctionLimitReached
        }
        let metricID = command.metricDefinitionID
        var metricDescriptor =
            FetchDescriptor<StatusMetricDefinitionRecord>(
                predicate: #Predicate { $0.id == metricID }
            )
        metricDescriptor.fetchLimit = 1
        guard let metric =
                try modelContext.fetch(metricDescriptor).first else {
            throw ParentRecordMutationFailure.invalidInput
        }
        let current = try effectiveStatusFacts(
            parentID: command.parentID
        )
        guard current.metricDefinitionID != metric.id
                || current.ordinalLevel != command.ordinalLevel
                || current.note != command.note
                || current.timestamp != command.timestamp else {
            throw ParentRecordMutationFailure.noEffectiveChange
        }
        let association = try resolvedAssociationForWrite(
            timestamp: command.timestamp
        )
        let reservation = try reserveRevision(
            committedAt: command.committedAt
        )
        modelContext.autosaveEnabled = false
        do {
            var output: ParentRecordMutationResult?
            try modelContext.transaction {
                if let replay = try parentMutationReplay(
                    operationID: command.operationID,
                    digest: digest,
                    type: .statusObservation,
                    parentID: command.parentID
                ) {
                    output = replay
                    return
                }
                try requireHead(head, matches: command.expectedHead)
                guard head.lifecycle == .active else {
                    throw ParentRecordMutationFailure.alreadyDeleted
                }
                guard ParentRecordLifecycleCapacity.canAppendCorrection(
                    toEventCount: head.eventCount
                ) else {
                    throw ParentRecordMutationFailure
                        .correctionLimitReached
                }
                let snapshot =
                    StatusObservationCorrectionSnapshotRecord(
                        id: command.correctionID,
                        eventID: command.eventID,
                        parentID: command.parentID,
                        metricDefinitionID: metric.id,
                        metricNameSnapshot: metric.displayName,
                        ordinalLevel: command.ordinalLevel,
                        note: command.note,
                        timestamp: command.timestamp,
                        resolvedRegimenVersionID: association.id,
                        associationState: association.state,
                        createdAt: command.committedAt
                    )
                modelContext.insert(snapshot)
                let postDigest =
                    try ParentRecordLifecycleDigest
                        .statusCorrectionFacts(snapshot)
                let event = ParentRecordMutationEventRecord(
                    id: command.eventID,
                    parentType: .statusObservation,
                    parentID: command.parentID,
                    kind: .corrected,
                    previousEventID: head.latestEventID,
                    payloadRecordType:
                        "StatusObservationCorrectionSnapshotRecord",
                    payloadID: snapshot.id,
                    operationID: command.operationID,
                    expectedHeadEventCount:
                        command.expectedHead.eventCount,
                    expectedHeadLocalRevision:
                        command.expectedHead.localRevision,
                    commandDigest: digest,
                    preFactsDigest:
                        command.expectedHead.factsDigest,
                    postFactsDigest: postDigest,
                    committedAt: command.committedAt
                )
                modelContext.insert(event)
                head.latestEventID = event.id
                head.latestPayloadID = snapshot.id
                head.eventCount += 1
                head.lifecycleRawValue =
                    ParentRecordLifecycle.active.rawValue
                head.replaceEffectiveTimestamp(command.timestamp)
                head.updatedAt = command.committedAt
                try upsertRevision(
                    recordType:
                        "StatusObservationCorrectionSnapshotRecord",
                    recordID: snapshot.id,
                    fields:
                        try ParentRecordLifecycleDigest
                            .statusCorrection(snapshot),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try persistParentMutation(
                    event: event,
                    head: head,
                    commandDigest: digest,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try ParentRecordLifecycleValidator.validate(
                    in: modelContext,
                    failure: .corruptionSuspected
                )
                output = ParentRecordMutationResult(
                    parentType: .statusObservation,
                    parentID: command.parentID,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let output else {
                throw ParentRecordMutationFailure.invalidInput
            }
            return output
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func deleteParentRecord(
        _ command: DeleteParentRecordCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> ParentRecordMutationResult {
        guard supportsParentRecordLifecycle,
              command.committedAt.timeIntervalSince1970.isFinite,
              Set(command.attachments.map(\.attachment.id)).count
                == command.attachments.count,
              Set(command.attachments.map(\.deletionOperationID)).count
                == command.attachments.count else {
            throw ParentRecordMutationFailure.invalidInput
        }
        let digest =
            try ParentRecordLifecycleCommandDigest.delete(command)
        if let replay = try parentMutationReplay(
            operationID: command.operationID,
            digest: digest,
            type: command.parentType,
            parentID: command.parentID
        ) {
            return replay
        }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let head = try requiredParentHead(
            type: command.parentType,
            id: command.parentID
        )
        try requireHead(head, matches: command.expectedHead)
        guard head.lifecycle == .active else {
            throw ParentRecordMutationFailure.alreadyDeleted
        }
        let currentAttachments = try activeAttachmentRecords(
            type: command.parentType,
            id: command.parentID
        )
        try requireAttachmentCommand(
            command.attachments,
            matches: currentAttachments
        )
        let expectedImpact =
            try parentImpactDigest(
                type: command.parentType,
                id: command.parentID,
                token: command.expectedHead,
                attachments: currentAttachments.compactMap(
                    AttachmentSnapshot.init
                )
            )
        guard expectedImpact == command.expectedImpactDigest else {
            throw ParentRecordMutationFailure.impactChanged
        }
        let reservation = try reserveRevision(
            committedAt: command.committedAt
        )
        modelContext.autosaveEnabled = false
        do {
            var output: ParentRecordMutationResult?
            try modelContext.transaction {
                if let replay = try parentMutationReplay(
                    operationID: command.operationID,
                    digest: digest,
                    type: command.parentType,
                    parentID: command.parentID
                ) {
                    output = replay
                    return
                }
                try requireHead(head, matches: command.expectedHead)
                guard head.lifecycle == .active else {
                    throw ParentRecordMutationFailure.alreadyDeleted
                }
                try requireAttachmentCommand(
                    command.attachments,
                    matches: currentAttachments
                )
                var totalBytes: Int64 = 0
                for pair in command.attachments {
                    guard let record = currentAttachments.first(
                        where: { $0.id == pair.attachment.id }
                    ) else {
                        throw ParentRecordMutationFailure.impactChanged
                    }
                    let sum = totalBytes.addingReportingOverflow(
                        record.byteCount
                    )
                    guard !sum.overflow else {
                        throw ParentRecordMutationFailure.invalidInput
                    }
                    totalBytes = sum.partialValue
                    record.deletedAt = command.committedAt
                    record.deleteOperationID =
                        pair.deletionOperationID
                    try upsertRevision(
                        recordType: "AttachmentRecord",
                        recordID: record.id,
                        fields:
                            try AttachmentDigestV1.record(record),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                    let deleteCommand = DeleteAttachmentCommand(
                        operationID: pair.deletionOperationID,
                        attachmentID: record.id,
                        committedAt: command.committedAt
                    )
                    try insertOperationReceipt(
                        OperationReceiptRecord(
                            operationID:
                                pair.deletionOperationID,
                            commandDigest:
                                try AttachmentDigestV1
                                    .deleteCommand(deleteCommand),
                            resultRecordType: "AttachmentRecord",
                            resultRecordID: record.id,
                            committedAt: command.committedAt
                        ),
                        reservation: reservation
                    )
                }
                let tombstone =
                    ParentRecordDeletionTombstoneRecord(
                        id: command.tombstoneID,
                        eventID: command.eventID,
                        parentType: command.parentType,
                        parentID: command.parentID,
                        priorFactsDigest:
                            command.expectedHead.factsDigest,
                        impactDigest:
                            command.expectedImpactDigest,
                        attachmentManifest:
                            ParentRecordDeletionAttachmentManifest
                                .encode(command.attachments),
                        attachmentCount:
                            command.attachments.count,
                        attachmentByteCount: totalBytes,
                        deletedAt: command.committedAt
                    )
                modelContext.insert(tombstone)
                let postDigest = try RecordDigestV1.sha256Hex(
                    recordType:
                        "ParentRecordDeletionTombstoneRecord",
                    recordID: tombstone.id,
                    fields:
                        try ParentRecordLifecycleDigest
                            .tombstone(tombstone)
                )
                let event = ParentRecordMutationEventRecord(
                    id: command.eventID,
                    parentType: command.parentType,
                    parentID: command.parentID,
                    kind: .deleted,
                    previousEventID: head.latestEventID,
                    payloadRecordType:
                        "ParentRecordDeletionTombstoneRecord",
                    payloadID: tombstone.id,
                    operationID: command.operationID,
                    expectedHeadEventCount:
                        command.expectedHead.eventCount,
                    expectedHeadLocalRevision:
                        command.expectedHead.localRevision,
                    commandDigest: digest,
                    preFactsDigest:
                        command.expectedHead.factsDigest,
                    postFactsDigest: postDigest,
                    committedAt: command.committedAt
                )
                modelContext.insert(event)
                head.latestEventID = event.id
                head.latestPayloadID = tombstone.id
                head.eventCount += 1
                head.lifecycleRawValue =
                    ParentRecordLifecycle.deleted.rawValue
                head.updatedAt = command.committedAt
                try upsertRevision(
                    recordType:
                        "ParentRecordDeletionTombstoneRecord",
                    recordID: tombstone.id,
                    fields:
                        try ParentRecordLifecycleDigest
                            .tombstone(tombstone),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try persistParentMutation(
                    event: event,
                    head: head,
                    commandDigest: digest,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try ParentRecordLifecycleValidator.validate(
                    in: modelContext,
                    failure: .corruptionSuspected
                )
                output = ParentRecordMutationResult(
                    parentType: command.parentType,
                    parentID: command.parentID,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let output else {
                throw ParentRecordMutationFailure.invalidInput
            }
            return output
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func validateParentRecordDeletionImpact(
        _ impact: ParentRecordDeletionImpact
    ) throws {
        guard supportsParentRecordLifecycle else {
            throw ParentRecordMutationFailure.invalidInput
        }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let head = try requiredParentHead(
            type: impact.parentType,
            id: impact.parentID
        )
        try requireHead(head, matches: impact.expectedHead)
        guard head.lifecycle == .active else {
            throw ParentRecordMutationFailure.alreadyDeleted
        }
        let attachments = try activeAttachmentRecords(
            type: impact.parentType,
            id: impact.parentID
        ).compactMap(AttachmentSnapshot.init)
        let currentDigest = try parentImpactDigest(
            type: impact.parentType,
            id: impact.parentID,
            token: impact.expectedHead,
            attachments: attachments
        )
        guard currentDigest == impact.impactDigest,
              attachments.sorted(by: {
                  $0.id.uuidString < $1.id.uuidString
              }) == impact.attachments.sorted(by: {
                  $0.id.uuidString < $1.id.uuidString
              }) else {
            throw ParentRecordMutationFailure.impactChanged
        }
    }

    private var supportsParentRecordLifecycle: Bool {
        modelContext.container.schema.entities.contains {
            $0.name == "ParentRecordLifecycleHeadRecord"
        }
    }

    private func insertCreatedParentRoot(
        type: ParentRecordType,
        parentID: UUID,
        operationID: UUID,
        commandDigest: String,
        factsDigest: String,
        timestamp: HistoricalTimestamp,
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        let key = type.recordKey(parentID: parentID)
        var descriptor =
            FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                predicate: #Predicate { $0.parentKey == key }
            )
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else {
            throw PersonalTimelineWriteFailure.staleRecord
        }
        let eventID = CoreTimeRegimenBackfill.stableUUID(
            for: "parent-lifecycle-created:" + key
        )
        let event = ParentRecordMutationEventRecord(
            id: eventID,
            parentType: type,
            parentID: parentID,
            kind: .createdSnapshot,
            previousEventID: nil,
            payloadRecordType: nil,
            payloadID: nil,
            operationID: operationID,
            commandDigest: commandDigest,
            preFactsDigest: factsDigest,
            postFactsDigest: factsDigest,
            committedAt: committedAt
        )
        let head = ParentRecordLifecycleHeadRecord(
            parentType: type,
            parentID: parentID,
            latestEventID: event.id,
            eventCount: 1,
            effectiveTimestamp: timestamp,
            updatedAt: committedAt
        )
        modelContext.insert(event)
        modelContext.insert(head)
        try upsertRevision(
            recordType: "ParentRecordMutationEventRecord",
            recordID: event.id,
            fields: try ParentRecordLifecycleDigest.event(event),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "ParentRecordLifecycleHeadRecord",
            recordID:
                ParentRecordLifecycleBackfill.stableHeadID(
                    for: key
                ),
            fields: try ParentRecordLifecycleDigest.head(head),
            reservation: reservation,
            committedAt: committedAt
        )
    }

    private func requiredParentBaseTime(
        type: ParentRecordType,
        id: UUID
    ) throws -> HistoricalTimeRecord {
        let sourceType = type.sourceRecordType
        var descriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceType
                    && $0.sourceRecordID == id
            }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1, let record = records.first else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        return record
    }

    private func requiredTimestamp(
        _ time: HistoricalTimeRecord
    ) throws -> HistoricalTimestamp {
        guard let timestamp = time.historicalTimestamp else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        return timestamp
    }

    private func normalizeCorrectedLabResults(
        _ inputs: [CorrectedLabResultInput]
    ) throws -> [NormalizedCorrectedLabResult] {
        let definitionIDs = Set(inputs.map(\.itemDefinitionID))
        var descriptor = FetchDescriptor<LabItemDefinitionRecord>(
            predicate: #Predicate { definitionIDs.contains($0.id) }
        )
        descriptor.fetchLimit = definitionIDs.count + 1
        let definitions = try modelContext.fetch(descriptor)
        let definitionByID = try AppDataIndex.checkedUniqueMap(
            definitions,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        guard definitions.count == definitionIDs.count else {
            throw ParentRecordMutationFailure.invalidInput
        }
        return try inputs.map { input in
            guard let definition =
                    definitionByID[input.itemDefinitionID],
                  !input.unitOriginal.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty else {
                throw ParentRecordMutationFailure.invalidInput
            }
            return NormalizedCorrectedLabResult(
                id: input.logicalResultID,
                itemDefinitionID: input.itemDefinitionID,
                itemName: definition.displayName,
                itemCode: definition.code,
                value: try LabDecimalValue.parse(
                    input.rawValueOriginal
                ),
                unit: input.unitOriginal,
                referenceRange: input.referenceRangeOriginal,
                variant: input.assayOrVariantOriginal
            )
        }
    }

    private func requireAvailableLogicalResultIdentities(
        _ proposedIDs: Set<UUID>,
        for parentID: UUID
    ) throws {
        guard !proposedIDs.isEmpty else { return }

        var headDescriptor =
            FetchDescriptor<ParentRecordLifecycleHeadRecord>()
        headDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumParents + 1
        let heads = try modelContext.fetch(headDescriptor)
        guard heads.count
                <= ParentRecordLifecycleCapacity.maximumParents else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }

        let maximumBaseResultRows =
            ParentRecordLifecycleCapacity.maximumParents
                * PersonalTimelineCapacity.maximumLabResultsPerSample
        var baseResultDescriptor = FetchDescriptor<LabResultRecord>()
        baseResultDescriptor.fetchLimit = maximumBaseResultRows + 1
        let baseResults = try modelContext.fetch(baseResultDescriptor)
        guard baseResults.count <= maximumBaseResultRows else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        let baseResultsBySample = Dictionary(
            grouping: baseResults,
            by: \.sampleID
        )

        var correctionDescriptor =
            FetchDescriptor<LabSampleCorrectionSnapshotRecord>()
        correctionDescriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumEvents + 1
        let corrections = try modelContext.fetch(correctionDescriptor)
        guard corrections.count
                <= ParentRecordLifecycleCapacity.maximumEvents else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        let correctionByID = try AppDataIndex.checkedUniqueMap(
            corrections,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )

        let maximumCorrectedResultRows =
            ParentRecordLifecycleCapacity.maximumEvents
                * PersonalTimelineCapacity.maximumLabResultsPerSample
        var resultDescriptor =
            FetchDescriptor<LabResultCorrectionSnapshotRecord>()
        resultDescriptor.fetchLimit = maximumCorrectedResultRows + 1
        let correctedResults = try modelContext.fetch(resultDescriptor)
        guard correctedResults.count <= maximumCorrectedResultRows else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        let correctedResultsBySnapshot = Dictionary(
            grouping: correctedResults,
            by: \.correctionSnapshotID
        )

        for head in heads
        where head.parentType == .labSample
            && head.lifecycle == .active
            && head.parentID != parentID {
            let ownedIDs: Set<UUID>
            if let payloadID = head.latestPayloadID {
                guard let correction = correctionByID[payloadID],
                      correction.parentID == head.parentID else {
                    throw ParentRecordMutationFailure.corruptionSuspected
                }
                ownedIDs = Set(
                    correctedResultsBySnapshot[payloadID, default: []]
                        .map(\.logicalResultID)
                )
            } else {
                ownedIDs = Set(
                    baseResultsBySample[head.parentID, default: []]
                        .map(\.id)
                )
            }
            guard proposedIDs.isDisjoint(with: ownedIDs) else {
                throw ParentRecordMutationFailure.invalidInput
            }
        }
    }

    private func requiredParentHead(
        type: ParentRecordType,
        id: UUID
    ) throws -> ParentRecordLifecycleHeadRecord {
        let key = type.recordKey(parentID: id)
        var descriptor =
            FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                predicate: #Predicate { $0.parentKey == key }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1, let record = records.first else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        return record
    }

    private func requireHead(
        _ head: ParentRecordLifecycleHeadRecord,
        matches token: ParentRecordHeadToken
    ) throws {
        let headID =
            ParentRecordLifecycleBackfill.stableHeadID(
                for: head.parentKey
            )
        let key =
            "ParentRecordLifecycleHeadRecord:"
            + headID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == key }
        )
        descriptor.fetchLimit = 2
        let revisions = try modelContext.fetch(descriptor)
        let latestEventID = head.latestEventID
        var eventDescriptor =
            FetchDescriptor<ParentRecordMutationEventRecord>(
                predicate: #Predicate {
                    $0.id == latestEventID
                }
            )
        eventDescriptor.fetchLimit = 2
        let events = try modelContext.fetch(eventDescriptor)
        guard revisions.count == 1,
              let revision = revisions.first,
              events.count == 1,
              let event = events.first else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        guard head.latestEventID == token.latestEventID,
              head.eventCount == token.eventCount,
              revision.localRevision == token.localRevision,
              event.postFactsDigest == token.factsDigest else {
            throw ParentRecordMutationFailure.staleHead
        }
    }

    private func activeAttachmentCount(
        ownerType: AttachmentOwnerType,
        ownerID: UUID
    ) throws -> Int {
        let ownerRaw = ownerType.rawValue
        return try modelContext.fetchCount(
            FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate {
                    $0.ownerTypeRawValue == ownerRaw
                        && $0.ownerID == ownerID
                        && $0.deletedAt == nil
                }
            )
        )
    }

    private func effectiveLabFacts(
        parentID: UUID
    ) throws -> LabSampleSnapshot {
        let head = try requiredParentHead(
            type: .labSample,
            id: parentID
        )
        guard head.lifecycle == .active,
              let event = try parentEventForWrite(
                  id: head.latestEventID
              ) else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        switch event.kind {
        case .migratedSnapshot, .createdSnapshot:
            return try baseLabFactsForWrite(parentID: parentID)
        case .corrected:
            guard let payloadID = event.payloadID else {
                throw ParentRecordMutationFailure.corruptionSuspected
            }
            return try correctedLabFactsForWrite(
                parentID: parentID,
                correctionID: payloadID
            )
        case .deleted, .none:
            throw ParentRecordMutationFailure.corruptionSuspected
        }
    }

    private func effectiveStatusFacts(
        parentID: UUID
    ) throws -> StatusObservationSnapshot {
        let head = try requiredParentHead(
            type: .statusObservation,
            id: parentID
        )
        guard head.lifecycle == .active,
              let event = try parentEventForWrite(
                  id: head.latestEventID
              ) else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        switch event.kind {
        case .migratedSnapshot, .createdSnapshot:
            return try baseStatusFactsForWrite(parentID: parentID)
        case .corrected:
            guard let payloadID = event.payloadID else {
                throw ParentRecordMutationFailure.corruptionSuspected
            }
            return try correctedStatusFactsForWrite(
                parentID: parentID,
                correctionID: payloadID
            )
        case .deleted, .none:
            throw ParentRecordMutationFailure.corruptionSuspected
        }
    }

    private func parentEventForWrite(
        id: UUID
    ) throws -> ParentRecordMutationEventRecord? {
        var descriptor =
            FetchDescriptor<ParentRecordMutationEventRecord>(
                predicate: #Predicate { $0.id == id }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        return records.first
    }

    private func baseLabFactsForWrite(
        parentID: UUID
    ) throws -> LabSampleSnapshot {
        var sampleDescriptor = FetchDescriptor<LabSampleRecord>(
            predicate: #Predicate { $0.id == parentID }
        )
        sampleDescriptor.fetchLimit = 2
        let samples = try modelContext.fetch(sampleDescriptor)
        let sourceType = "LabSampleRecord"
        var timeDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceType
                    && $0.sourceRecordID == parentID
            }
        )
        timeDescriptor.fetchLimit = 2
        let times = try modelContext.fetch(timeDescriptor)
        guard samples.count == 1,
              let sample = samples.first,
              times.count == 1,
              let time = times.first,
              let timestamp = time.historicalTimestamp,
              let associationState = HistoricalAssociationState(
                  rawValue: time.associationStateRawValue
              ) else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        var resultDescriptor = FetchDescriptor<LabResultRecord>(
            predicate: #Predicate { $0.sampleID == parentID },
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.id)
            ]
        )
        resultDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumLabResultsPerSample + 1
        let results = try modelContext.fetch(resultDescriptor)
        guard results.count
                <= PersonalTimelineCapacity.maximumLabResultsPerSample else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        let definitionIDs = Array(Set(results.map(\.itemDefinitionID)))
        var definitionDescriptor =
            FetchDescriptor<LabItemDefinitionRecord>(
                predicate: #Predicate {
                    definitionIDs.contains($0.id)
                }
            )
        definitionDescriptor.fetchLimit = definitionIDs.count + 1
        let definitions = try modelContext.fetch(definitionDescriptor)
        let definitionByID = try AppDataIndex.checkedUniqueMap(
            definitions,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        guard definitions.count == definitionIDs.count else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        return LabSampleSnapshot(
            id: sample.id,
            timestamp: timestamp,
            regimenVersionID: time.resolvedRegimenVersionID,
            associationState: associationState,
            specimenOriginal: sample.specimenOriginal,
            contextNote: sample.contextNote,
            results: try results.map { result in
                guard let definition =
                        definitionByID[result.itemDefinitionID],
                      let kind = LabItemDefinitionKind(
                          rawValue: definition.kindRawValue
                      ) else {
                    throw ParentRecordMutationFailure.corruptionSuspected
                }
                return LabResultSnapshot(
                    id: result.id,
                    itemDefinitionID: result.itemDefinitionID,
                    itemDefinitionKind: kind,
                    bundledStableID: definition.bundledStableID,
                    itemNameSnapshot: result.itemNameSnapshot,
                    itemCodeSnapshot: result.itemCodeSnapshot,
                    rawValueOriginal: result.rawValueOriginal,
                    comparator: result.comparator,
                    canonicalDecimalString:
                        result.canonicalDecimalString,
                    unitOriginal: result.unitOriginal,
                    referenceRangeOriginal:
                        result.referenceRangeOriginal,
                    assayOrVariantOriginal:
                        result.assayOrVariantOriginal
                )
            }
        )
    }

    private func correctedLabFactsForWrite(
        parentID: UUID,
        correctionID: UUID
    ) throws -> LabSampleSnapshot {
        var snapshotDescriptor =
            FetchDescriptor<LabSampleCorrectionSnapshotRecord>(
                predicate: #Predicate { $0.id == correctionID }
            )
        snapshotDescriptor.fetchLimit = 2
        let snapshots = try modelContext.fetch(snapshotDescriptor)
        guard snapshots.count == 1,
              let snapshot = snapshots.first,
              snapshot.parentID == parentID,
              let timestamp = snapshot.timestamp,
              let associationState = HistoricalAssociationState(
                  rawValue: snapshot.associationStateRawValue
              ) else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        var resultDescriptor =
            FetchDescriptor<LabResultCorrectionSnapshotRecord>(
                predicate: #Predicate {
                    $0.correctionSnapshotID == correctionID
                },
                sortBy: [
                    SortDescriptor(\.sortOrder),
                    SortDescriptor(\.id)
                ]
            )
        resultDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumLabResultsPerSample + 1
        let results = try modelContext.fetch(resultDescriptor)
        guard results.count
                <= PersonalTimelineCapacity.maximumLabResultsPerSample,
              results.enumerated().allSatisfy({
                  $0.offset == $0.element.sortOrder
              }),
              Set(results.map(\.logicalResultID)).count
                == results.count else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        let definitionIDs = Array(Set(results.map(\.itemDefinitionID)))
        var definitionDescriptor =
            FetchDescriptor<LabItemDefinitionRecord>(
                predicate: #Predicate {
                    definitionIDs.contains($0.id)
                }
            )
        definitionDescriptor.fetchLimit = definitionIDs.count + 1
        let definitions = try modelContext.fetch(definitionDescriptor)
        let definitionByID = try AppDataIndex.checkedUniqueMap(
            definitions,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        guard definitions.count == definitionIDs.count else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        return LabSampleSnapshot(
            id: parentID,
            timestamp: timestamp,
            regimenVersionID: snapshot.resolvedRegimenVersionID,
            associationState: associationState,
            specimenOriginal: snapshot.specimenOriginal,
            contextNote: snapshot.contextNote,
            results: try results.map { result in
                guard let definition =
                        definitionByID[result.itemDefinitionID],
                      let kind = LabItemDefinitionKind(
                          rawValue: definition.kindRawValue
                      ) else {
                    throw ParentRecordMutationFailure.corruptionSuspected
                }
                return LabResultSnapshot(
                    id: result.logicalResultID,
                    itemDefinitionID: result.itemDefinitionID,
                    itemDefinitionKind: kind,
                    bundledStableID: definition.bundledStableID,
                    itemNameSnapshot: result.itemNameSnapshot,
                    itemCodeSnapshot: result.itemCodeSnapshot,
                    rawValueOriginal: result.rawValueOriginal,
                    comparator: result.comparator,
                    canonicalDecimalString:
                        result.canonicalDecimalString,
                    unitOriginal: result.unitOriginal,
                    referenceRangeOriginal:
                        result.referenceRangeOriginal,
                    assayOrVariantOriginal:
                        result.assayOrVariantOriginal
                )
            }
        )
    }

    private func baseStatusFactsForWrite(
        parentID: UUID
    ) throws -> StatusObservationSnapshot {
        var observationDescriptor =
            FetchDescriptor<StatusObservationRecord>(
                predicate: #Predicate { $0.id == parentID }
            )
        observationDescriptor.fetchLimit = 2
        let observations =
            try modelContext.fetch(observationDescriptor)
        let sourceType = "StatusObservationRecord"
        var timeDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceType
                    && $0.sourceRecordID == parentID
            }
        )
        timeDescriptor.fetchLimit = 2
        let times = try modelContext.fetch(timeDescriptor)
        guard observations.count == 1,
              let observation = observations.first,
              times.count == 1,
              let time = times.first,
              let timestamp = time.historicalTimestamp,
              let state = HistoricalAssociationState(
                  rawValue: time.associationStateRawValue
              ) else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        return StatusObservationSnapshot(
            id: observation.id,
            metricDefinitionID: observation.metricDefinitionID,
            metricNameSnapshot: observation.metricNameSnapshot,
            ordinalLevel: observation.ordinalLevel,
            note: observation.note,
            timestamp: timestamp,
            regimenVersionID: time.resolvedRegimenVersionID,
            associationState: state
        )
    }

    private func correctedStatusFactsForWrite(
        parentID: UUID,
        correctionID: UUID
    ) throws -> StatusObservationSnapshot {
        var descriptor =
            FetchDescriptor<StatusObservationCorrectionSnapshotRecord>(
                predicate: #Predicate { $0.id == correctionID }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let record = records.first,
              record.parentID == parentID,
              let timestamp = record.timestamp,
              let state = HistoricalAssociationState(
                  rawValue: record.associationStateRawValue
              ),
              (1...4).contains(record.ordinalLevel) else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        return StatusObservationSnapshot(
            id: parentID,
            metricDefinitionID: record.metricDefinitionID,
            metricNameSnapshot: record.metricNameSnapshot,
            ordinalLevel: record.ordinalLevel,
            note: record.note,
            timestamp: timestamp,
            regimenVersionID: record.resolvedRegimenVersionID,
            associationState: state
        )
    }

    private func labCommand(
        _ command: CorrectLabSampleCommand,
        normalized: [NormalizedCorrectedLabResult],
        equals current: LabSampleSnapshot
    ) -> Bool {
        guard command.timestamp == current.timestamp,
              command.specimenOriginal == current.specimenOriginal,
              command.contextNote == current.contextNote,
              normalized.count == current.results.count else {
            return false
        }
        return zip(normalized, current.results).allSatisfy {
            lhs,
            rhs in
            lhs.id == rhs.id
                && lhs.itemDefinitionID == rhs.itemDefinitionID
                && lhs.value.original == rhs.rawValueOriginal
                && lhs.unit == rhs.unitOriginal
                && lhs.referenceRange == rhs.referenceRangeOriginal
                && lhs.variant == rhs.assayOrVariantOriginal
        }
    }

    private func persistParentMutation(
        event: ParentRecordMutationEventRecord,
        head: ParentRecordLifecycleHeadRecord,
        commandDigest: String,
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        try upsertRevision(
            recordType: "ParentRecordMutationEventRecord",
            recordID: event.id,
            fields: try ParentRecordLifecycleDigest.event(event),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "ParentRecordLifecycleHeadRecord",
            recordID:
                ParentRecordLifecycleBackfill.stableHeadID(
                    for: head.parentKey
                ),
            fields: try ParentRecordLifecycleDigest.head(head),
            reservation: reservation,
            committedAt: committedAt
        )
        try insertOperationReceipt(
            OperationReceiptRecord(
                operationID: event.operationID,
                commandDigest: commandDigest,
                resultRecordType:
                    "ParentRecordMutationEventRecord",
                resultRecordID: event.id,
                committedAt: committedAt
            ),
            reservation: reservation
        )
        try markCommitted(at: committedAt)
    }

    private func parentMutationReplay(
        operationID: UUID,
        digest: String,
        type: ParentRecordType,
        parentID: UUID
    ) throws -> ParentRecordMutationResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 2
        let receipts = try modelContext.fetch(descriptor)
        guard receipts.count <= 1 else {
            throw ParentRecordMutationFailure.corruptionSuspected
        }
        guard let receipt = receipts.first else { return nil }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let eventID = receipt.resultRecordID
        var eventDescriptor =
            FetchDescriptor<ParentRecordMutationEventRecord>(
                predicate: #Predicate { $0.id == eventID }
            )
        eventDescriptor.fetchLimit = 2
        let events = try modelContext.fetch(eventDescriptor)
        guard receipt.commandDigest == digest,
              receipt.resultRecordType
                == "ParentRecordMutationEventRecord",
              events.count == 1,
              let event = events.first,
              event.operationID == operationID,
              event.commandDigest == digest,
              event.parentType == type,
              event.parentID == parentID else {
            throw ParentRecordMutationFailure.operationConflict
        }
        return ParentRecordMutationResult(
            parentType: type,
            parentID: parentID,
            eventID: event.id,
            didApply: false
        )
    }

    private func activeAttachmentRecords(
        type: ParentRecordType,
        id: UUID
    ) throws -> [AttachmentRecord] {
        let owner =
            type == .labSample
            ? AttachmentOwnerType.labSample.rawValue
            : AttachmentOwnerType.statusObservation.rawValue
        return try modelContext.fetch(
            FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate {
                    $0.ownerTypeRawValue == owner
                        && $0.ownerID == id
                        && $0.deletedAt == nil
                },
                sortBy: [SortDescriptor(\.id)]
            )
        )
    }

    private func requireAttachmentCommand(
        _ command: [ParentRecordDeletionAttachment],
        matches records: [AttachmentRecord]
    ) throws {
        let snapshots = records.compactMap(AttachmentSnapshot.init)
        guard snapshots.count == records.count,
              command.map(\.attachment).sorted(
                  by: { $0.id.uuidString < $1.id.uuidString }
              ) == snapshots.sorted(
                  by: { $0.id.uuidString < $1.id.uuidString }
              ) else {
            throw ParentRecordMutationFailure.impactChanged
        }
    }

    private func parentImpactDigest(
        type: ParentRecordType,
        id: UUID,
        token: ParentRecordHeadToken,
        attachments: [AttachmentSnapshot]
    ) throws -> String {
        let correctionCount = max(0, token.eventCount - 1)
        let resultCount: Int
        switch type {
        case .labSample:
            resultCount =
                try effectiveLabFacts(parentID: id).results.count
        case .statusObservation:
            resultCount = 0
        }
        return try ParentRecordLifecycleCommandDigest.impact(
            type: type,
            parentID: id,
            token: token,
            effectiveResultCount: resultCount,
            correctionCount: correctionCount,
            attachments: attachments
        )
    }
}

struct ParentRecordDeletionAttachmentManifestEntry: Equatable {
    let attachmentID: UUID
    let sha256Hex: String
    let deletionOperationID: UUID
}

enum ParentRecordDeletionAttachmentManifest {
    private static let version = "v1"

    static func encode(
        _ attachments: [ParentRecordDeletionAttachment]
    ) -> String {
        encode(
            attachments.map {
                ParentRecordDeletionAttachmentManifestEntry(
                    attachmentID: $0.attachment.id,
                    sha256Hex: $0.attachment.sha256Hex.lowercased(),
                    deletionOperationID: $0.deletionOperationID
                )
            }
        )
    }

    static func encode(
        _ entries: [ParentRecordDeletionAttachmentManifestEntry]
    ) -> String {
        let rows = entries.sorted {
            $0.attachmentID.uuidString < $1.attachmentID.uuidString
        }.map {
            [
                $0.attachmentID.uuidString.lowercased(),
                $0.sha256Hex.lowercased(),
                $0.deletionOperationID.uuidString.lowercased()
            ].joined(separator: ":")
        }
        return ([version] + rows).joined(separator: "\n")
    }

    static func decode(
        _ manifest: String
    ) -> [ParentRecordDeletionAttachmentManifestEntry]? {
        let lines = manifest.components(separatedBy: "\n")
        guard lines.first == version else { return nil }
        var entries: [ParentRecordDeletionAttachmentManifestEntry] = []
        for line in lines.dropFirst() {
            let fields = line.split(
                separator: ":",
                omittingEmptySubsequences: false
            )
            guard fields.count == 3,
                  let attachmentID = UUID(uuidString: String(fields[0])),
                  String(fields[1]).count == 64,
                  String(fields[1]).allSatisfy({
                      $0.isHexDigit && !$0.isUppercase
                  }),
                  let deletionOperationID = UUID(
                      uuidString: String(fields[2])
                  ) else {
                return nil
            }
            entries.append(
                ParentRecordDeletionAttachmentManifestEntry(
                    attachmentID: attachmentID,
                    sha256Hex: String(fields[1]),
                    deletionOperationID: deletionOperationID
                )
            )
        }
        guard Set(entries.map(\.attachmentID)).count == entries.count,
              Set(entries.map(\.deletionOperationID)).count
                == entries.count,
              encode(entries) == manifest else {
            return nil
        }
        return entries
    }
}

enum ParentRecordLifecycleCommandDigest {
    static func correctLab(
        _ command: CorrectLabSampleCommand,
        normalized: [NormalizedCorrectedLabResult]
    ) throws -> String {
        var fields = try tokenFields(command.expectedHead)
        fields += [
            .init(
                "committedAt",
                try RecordDigestV1.timestampValue(command.committedAt)
            ),
            .init("contextNote", .string(command.contextNote)),
            .init("correctionID", .uuid(command.correctionID)),
            .init("eventID", .uuid(command.eventID)),
            .init("parentID", .uuid(command.parentID)),
            .init("resultCount", .integer(Int64(normalized.count))),
            .init("specimenOriginal", .string(command.specimenOriginal))
        ]
        fields += try timestampFields(command.timestamp)
        for (index, result) in normalized.enumerated() {
            let prefix = "result.\(index)."
            fields += [
                .init(
                    prefix + "assayOrVariantOriginal",
                    result.variant.map(RecordDigestV1.Value.string)
                        ?? .null
                ),
                .init(
                    prefix + "itemDefinitionID",
                    .uuid(result.itemDefinitionID)
                ),
                .init(prefix + "logicalResultID", .uuid(result.id)),
                .init(
                    prefix + "rawValueOriginal",
                    .string(result.value.original)
                ),
                .init(
                    prefix + "referenceRangeOriginal",
                    result.referenceRange
                        .map(RecordDigestV1.Value.string) ?? .null
                ),
                .init(prefix + "unitOriginal", .string(result.unit))
            ]
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "CorrectLabSampleCommand",
            recordID: command.operationID,
            fields: fields
        )
    }

    static func correctStatus(
        _ command: CorrectStatusObservationCommand
    ) throws -> String {
        var fields = try tokenFields(command.expectedHead)
        fields += [
            .init(
                "committedAt",
                try RecordDigestV1.timestampValue(command.committedAt)
            ),
            .init("correctionID", .uuid(command.correctionID)),
            .init("eventID", .uuid(command.eventID)),
            .init(
                "metricDefinitionID",
                .uuid(command.metricDefinitionID)
            ),
            .init("note", .string(command.note)),
            .init("ordinalLevel", .integer(Int64(command.ordinalLevel))),
            .init("parentID", .uuid(command.parentID))
        ]
        fields += try timestampFields(command.timestamp)
        return try RecordDigestV1.sha256Hex(
            recordType: "CorrectStatusObservationCommand",
            recordID: command.operationID,
            fields: fields
        )
    }

    static func delete(
        _ command: DeleteParentRecordCommand
    ) throws -> String {
        var fields = try tokenFields(command.expectedHead)
        fields += [
            .init(
                "committedAt",
                try RecordDigestV1.timestampValue(command.committedAt)
            ),
            .init("eventID", .uuid(command.eventID)),
            .init("impactDigest", .string(command.expectedImpactDigest)),
            .init("parentID", .uuid(command.parentID)),
            .init("parentType", .string(command.parentType.rawValue)),
            .init("tombstoneID", .uuid(command.tombstoneID))
        ]
        for (index, attachment) in command.attachments.sorted(
            by: { $0.attachment.id.uuidString
                < $1.attachment.id.uuidString }
        ).enumerated() {
            let prefix = "attachment.\(index)."
            fields += [
                .init(
                    prefix + "byteCount",
                    .integer(attachment.attachment.byteCount)
                ),
                .init(
                    prefix + "createdAt",
                    try RecordDigestV1.timestampValue(
                        attachment.attachment.createdAt
                    )
                ),
                .init(
                    prefix + "deletionOperationID",
                    .uuid(attachment.deletionOperationID)
                ),
                .init(prefix + "id", .uuid(attachment.attachment.id)),
                .init(
                    prefix + "originalFilename",
                    .string(
                        attachment.attachment.originalFilename
                    )
                ),
                .init(
                    prefix + "ownerID",
                    .uuid(attachment.attachment.ownerID)
                ),
                .init(
                    prefix + "ownerType",
                    .string(
                        attachment.attachment.ownerType.rawValue
                    )
                ),
                .init(
                    prefix + "relativePath",
                    .string(attachment.attachment.relativePath)
                ),
                .init(
                    prefix + "sha256Hex",
                    .string(attachment.attachment.sha256Hex)
                ),
                .init(
                    prefix + "typeIdentifier",
                    .string(attachment.attachment.typeIdentifier)
                )
            ]
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "DeleteParentRecordCommand",
            recordID: command.operationID,
            fields: fields
        )
    }

    static func impact(
        type: ParentRecordType,
        parentID: UUID,
        token: ParentRecordHeadToken,
        effectiveResultCount: Int,
        correctionCount: Int,
        attachments: [AttachmentSnapshot]
    ) throws -> String {
        var fields = try tokenFields(token)
        fields += [
            .init(
                "correctionCount",
                .integer(Int64(correctionCount))
            ),
            .init(
                "effectiveResultCount",
                .integer(Int64(effectiveResultCount))
            ),
            .init("parentID", .uuid(parentID)),
            .init("parentType", .string(type.rawValue))
        ]
        for (index, attachment) in attachments.sorted(
            by: { $0.id.uuidString < $1.id.uuidString }
        ).enumerated() {
            let prefix = "attachment.\(index)."
            fields += [
                .init(
                    prefix + "byteCount",
                    .integer(attachment.byteCount)
                ),
                .init(
                    prefix + "createdAt",
                    try RecordDigestV1.timestampValue(
                        attachment.createdAt
                    )
                ),
                .init(prefix + "id", .uuid(attachment.id)),
                .init(
                    prefix + "originalFilename",
                    .string(attachment.originalFilename)
                ),
                .init(prefix + "ownerID", .uuid(attachment.ownerID)),
                .init(
                    prefix + "ownerType",
                    .string(attachment.ownerType.rawValue)
                ),
                .init(
                    prefix + "relativePath",
                    .string(attachment.relativePath)
                ),
                .init(
                    prefix + "sha256Hex",
                    .string(attachment.sha256Hex)
                ),
                .init(
                    prefix + "typeIdentifier",
                    .string(attachment.typeIdentifier)
                )
            ]
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "ParentRecordDeletionImpact",
            recordID: parentID,
            fields: fields
        )
    }

    private static func tokenFields(
        _ token: ParentRecordHeadToken
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("expectedEventCount", .integer(Int64(token.eventCount))),
            .init(
                "expectedFactsDigest",
                .string(token.factsDigest)
            ),
            .init(
                "expectedLatestEventID",
                .uuid(token.latestEventID)
            ),
            .init(
                "expectedLocalRevision",
                .integer(token.localRevision)
            )
        ]
    }

    private static func timestampFields(
        _ timestamp: HistoricalTimestamp
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "instant",
                try RecordDigestV1.timestampValue(timestamp.instant)
            ),
            .init("localDate", .string(timestamp.localDate.iso8601)),
            .init(
                "localHour",
                .integer(Int64(timestamp.localTime.hour))
            ),
            .init(
                "localMinute",
                .integer(Int64(timestamp.localTime.minute))
            ),
            .init(
                "localNanosecond",
                .integer(Int64(timestamp.localTime.nanosecond))
            ),
            .init(
                "localSecond",
                .integer(Int64(timestamp.localTime.second))
            ),
            .init("precision", .string(timestamp.precision.rawValue)),
            .init("provenance", .string(timestamp.provenance.rawValue)),
            .init("timeZone", .string(timestamp.timeZoneIdentifier)),
            .init(
                "utcOffset",
                .integer(Int64(timestamp.utcOffsetSeconds))
            )
        ]
    }
}
