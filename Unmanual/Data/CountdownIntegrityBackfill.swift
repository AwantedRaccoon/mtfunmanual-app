import Foundation
import SwiftData

struct CountdownIntegrityBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum CountdownIntegrityBackfill {
    static func run(
        in container: ModelContainer,
        now: Date = Date()
    ) throws -> CountdownIntegrityBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var stateDescriptor = FetchDescriptor<CountdownIntegrityBackfillState>()
        stateDescriptor.fetchLimit = 2
        let existingStates = try context.fetch(stateDescriptor)
        guard existingStates.count <= 1 else {
            throw AppDataFailure.migrationFailed
        }
        if let state = existingStates.first, state.completedAt != nil {
            try validateCompletedMarker(state)
            return CountdownIntegrityBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }

        let events = try context.fetch(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        let audits = try context.fetch(
            FetchDescriptor<CountdownCommandAuditRecord>()
        )
        let existingCheckpoints = try context.fetch(
            FetchDescriptor<CountdownV6AuditCheckpointRecord>()
        )
        guard existingCheckpoints.isEmpty,
              audits.isEmpty || audits.count == events.count else {
            throw AppDataFailure.migrationFailed
        }

        do {
            try context.transaction {
                let checkpoints: [CountdownV6AuditCheckpointRecord]
                let sourceSchemaVersion: String
                if audits.isEmpty, !events.isEmpty {
                    sourceSchemaVersion = "6.0.0"
                    checkpoints = try makeObservedV6Checkpoints(
                        in: context,
                        events: events,
                        now: now
                    )
                    checkpoints.forEach(context.insert)
                } else {
                    sourceSchemaVersion = "7.0.0"
                    checkpoints = []
                }
                _ = try markUntrustedReminderCoverage(
                    checkpoints: checkpoints,
                    in: context,
                    now: now
                )
                let integritySetDigest =
                    try CountdownIntegrityDigest.integritySetDigest(
                        audits: audits,
                        checkpoints: checkpoints
                    )
                let state = existingStates.first
                    ?? CountdownIntegrityBackfillState(
                        sourceSchemaVersion: sourceSchemaVersion,
                        initialAuditCount: audits.count,
                        initialCheckpointCount: checkpoints.count,
                        initialIntegritySetDigest: integritySetDigest,
                        completedAt: now,
                        updatedAt: now
                    )
                if existingStates.isEmpty {
                    context.insert(state)
                } else {
                    state.sourceSchemaVersion = sourceSchemaVersion
                    state.initialAuditCount = audits.count
                    state.initialCheckpointCount = checkpoints.count
                    state.initialIntegritySetDigest = integritySetDigest
                    state.completedAt = now
                    state.updatedAt = now
                }
                try insertRevisions(
                    checkpoints: checkpoints,
                    state: state,
                    in: context,
                    committedAt: now
                )
                try context.save()
            }
            try validateCompletedMarker(
                try requiredState(in: context)
            )
            return CountdownIntegrityBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func makeObservedV6Checkpoints(
        in context: ModelContext,
        events: [CountdownLifecycleEventRecord],
        now: Date
    ) throws -> [CountdownV6AuditCheckpointRecord] {
        let states = try context.fetch(FetchDescriptor<CountdownStateRecord>())
        let reminders = try context.fetch(
            FetchDescriptor<CountdownReminderRuleRecord>()
        )
        let legacy = try context.fetch(FetchDescriptor<CountdownRecord>())
        let receipts = try context.fetch(
            FetchDescriptor<OperationReceiptRecord>()
        )
        let eventsByID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: .migrationFailed
        )
        let remindersByCountdownID = try AppDataIndex.checkedUniqueMap(
            reminders,
            keyedBy: \.countdownID,
            failure: .migrationFailed
        )
        let legacyByID = try AppDataIndex.checkedUniqueMap(
            legacy,
            keyedBy: \.id,
            failure: .migrationFailed
        )
        let receiptsByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: .migrationFailed
        )
        return try states.map { state in
            guard let reminder = remindersByCountdownID[state.id] else {
                throw AppDataFailure.migrationFailed
            }
            var reverseChain: [CountdownLifecycleEventRecord] = []
            var cursor: UUID? = state.latestEventID
            var visited = Set<UUID>()
            while let eventID = cursor {
                guard visited.insert(eventID).inserted,
                      let event = eventsByID[eventID],
                      event.countdownID == state.id else {
                    throw AppDataFailure.migrationFailed
                }
                reverseChain.append(event)
                cursor = event.previousEventID
            }
            let chain = reverseChain.reversed()
            guard !chain.isEmpty else {
                throw AppDataFailure.migrationFailed
            }
            let checkpoint = CountdownV6AuditCheckpointRecord(
                countdownID: state.id,
                boundaryEventID: state.latestEventID,
                prefixEventCount: chain.count,
                prefixChainDigest:
                    try CountdownIntegrityDigest.prefixChain(
                        events: Array(chain),
                        receiptsByOperationID: receiptsByOperationID
                    ),
                postFactsDigest: try CountdownIntegrityDigest.facts(
                    state: state,
                    reminder: reminder,
                    legacy: legacyByID[state.id]
                ),
                reminderAdmission: reminder.isEnabled
                    ? .needsUserConfirmation
                    : .disabledAtUpgrade,
                createdAt: now
            )
            try checkpoint.seal()
            return checkpoint
        }
    }

    private static func insertRevisions(
        checkpoints: [CountdownV6AuditCheckpointRecord],
        state: CountdownIntegrityBackfillState,
        in context: ModelContext,
        committedAt: Date
    ) throws {
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard metadataRecords.count == 1,
              let metadata = metadataRecords.first else {
            throw AppDataFailure.migrationFailed
        }
        var facts: [(String, UUID, [RecordDigestV1.Field])] =
            try checkpoints.map {
                (
                    "CountdownV6AuditCheckpointRecord",
                    $0.countdownID,
                    try CountdownIntegrityDigest.checkpointRevisionFields($0)
                )
            }
        let stateID = CoreTimeRegimenBackfill.stableUUID(
            for: CountdownIntegrityBackfillState.fixedKey
        )
        facts.append(
            (
                "CountdownIntegrityBackfillState",
                stateID,
                try CountdownIntegrityDigest.backfillState(state)
            )
        )
        facts.sort {
            $0.0 != $1.0
                ? $0.0 < $1.0
                : $0.1.uuidString < $1.1.uuidString
        }
        var existingKeys = Set(
            try context.fetch(FetchDescriptor<RecordRevision>()).map(\.recordKey)
        )
        for (recordType, recordID, fields) in facts {
            let key =
                recordType + ":" + recordID.uuidString.lowercased()
            guard existingKeys.insert(key).inserted,
                  metadata.nextLocalRevision > 0,
                  metadata.nextLocalRevision < Int64.max else {
                throw AppDataFailure.migrationFailed
            }
            context.insert(
                RecordRevision(
                    recordKey: key,
                    recordType: recordType,
                    recordID: recordID,
                    datasetID: metadata.datasetID,
                    localRevision: metadata.nextLocalRevision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try RecordDigestV1.sha256Hex(
                        recordType: recordType,
                        recordID: recordID,
                        fields: fields
                    ),
                    committedAt: committedAt
                )
            )
            metadata.nextLocalRevision += 1
        }
        metadata.lastCommittedAt = committedAt
    }

    private static func markUntrustedReminderCoverage(
        checkpoints: [CountdownV6AuditCheckpointRecord],
        in context: ModelContext,
        now: Date
    ) throws -> CountdownNotificationCoverageRecord? {
        let untrustedIDs = Set(
            checkpoints.compactMap {
                $0.reminderAdmission == .needsUserConfirmation
                    ? $0.countdownID
                    : nil
            }
        )
        guard let countdownID = untrustedIDs.sorted(
            by: { $0.uuidString < $1.uuidString }
        ).first else {
            return nil
        }
        var descriptor =
            FetchDescriptor<CountdownNotificationCoverageRecord>()
        descriptor.fetchLimit = 2
        let coverageRecords = try context.fetch(descriptor)
        guard coverageRecords.count == 1,
              let coverage = coverageRecords.first else {
            throw AppDataFailure.migrationFailed
        }
        coverage.countdownID = countdownID
        coverage.statusRawValue =
            NotificationCoverageStatus.schedulingFailed.rawValue
        coverage.scheduledFireAt = nil
        coverage.desiredCount = 1
        coverage.confirmedPendingCount = 0
        coverage.lastErrorCode = "countdown-needs-confirmation"
        coverage.observedAt = now
        return coverage
    }

    private static func validateCompletedMarker(
        _ state: CountdownIntegrityBackfillState
    ) throws {
        guard state.taskKey == CountdownIntegrityBackfillState.fixedKey,
              ["6.0.0", "7.0.0"].contains(state.sourceSchemaVersion),
              state.initialAuditCount >= 0,
              state.initialCheckpointCount >= 0,
              state.initialIntegritySetDigest.count == 64,
              state.initialIntegritySetDigest.allSatisfy(\.isHexDigit),
              state.completedAt?.timeIntervalSince1970.isFinite == true,
              state.updatedAt.timeIntervalSince1970.isFinite else {
            throw AppDataFailure.migrationFailed
        }
    }

    private static func requiredState(
        in context: ModelContext
    ) throws -> CountdownIntegrityBackfillState {
        var descriptor = FetchDescriptor<CountdownIntegrityBackfillState>()
        descriptor.fetchLimit = 2
        let states = try context.fetch(descriptor)
        guard states.count == 1, let state = states.first else {
            throw AppDataFailure.migrationFailed
        }
        return state
    }
}
