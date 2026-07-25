import Foundation
import SwiftData

struct CountdownLifecycleBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum CountdownLifecycleBackfill {
    static func run(
        in container: ModelContainer,
        now: Date = Date(),
        includeIntegrityFacts: Bool = true
    ) throws -> CountdownLifecycleBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var stateDescriptor = FetchDescriptor<CountdownLifecycleBackfillState>()
        stateDescriptor.fetchLimit = 2
        let states = try context.fetch(stateDescriptor)
        guard states.count <= 1 else { throw AppDataFailure.migrationFailed }
        if let state = states.first, state.completedAt != nil {
            try validateCompletedMarker(in: context, state: state)
            if includeIntegrityFacts {
                _ = try CountdownIntegrityBackfill.run(
                    in: container,
                    now: now
                )
            }
            return CountdownLifecycleBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }

        var coreStateDescriptor = FetchDescriptor<CoreTimeRegimenBackfillState>()
        coreStateDescriptor.fetchLimit = 2
        let coreStates = try context.fetch(coreStateDescriptor)
        guard coreStates.count == 1,
              let coreState = coreStates.first,
              coreState.completedAt != nil,
              TimeZone(identifier: coreState.assumedTimeZoneIdentifier) != nil else {
            throw AppDataFailure.migrationFailed
        }
        let assumedZone = states.first?.assumedTimeZoneIdentifier
            ?? coreState.assumedTimeZoneIdentifier
        guard assumedZone == coreState.assumedTimeZoneIdentifier else {
            throw AppDataFailure.migrationFailed
        }

        do {
            try context.transaction {
                let state = states.first ?? CountdownLifecycleBackfillState(
                    assumedTimeZoneIdentifier: assumedZone,
                    updatedAt: now
                )
                if states.isEmpty { context.insert(state) }
                let facts = try migrateLegacyCountdowns(
                    in: context,
                    assumedTimeZoneIdentifier: assumedZone,
                    includeIntegrityFacts: includeIntegrityFacts
                )
                try ensureRevisions(
                    for: facts,
                    in: context,
                    now: now
                )
                if try context.fetch(
                    FetchDescriptor<CountdownNotificationCoverageRecord>()
                ).isEmpty {
                    context.insert(
                        CountdownNotificationCoverageRecord(
                            status: .disabledByUser,
                            observedAt: now
                        )
                    )
                }
                state.completedAt = now
                state.updatedAt = now
                try context.save()
            }
            try validateFreshMigrationOutcome(
                in: context,
                state: try requiredBackfillState(in: context)
            )
            if includeIntegrityFacts {
                _ = try CountdownIntegrityBackfill.run(
                    in: container,
                    now: now
                )
            }
            return CountdownLifecycleBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    private struct BackfilledFacts {
        var states: [CountdownStateRecord] = []
        var events: [CountdownLifecycleEventRecord] = []
        var reminders: [CountdownReminderRuleRecord] = []
        var receipts: [OperationReceiptRecord] = []
        var audits: [CountdownCommandAuditRecord] = []
    }

    private static func migrateLegacyCountdowns(
        in context: ModelContext,
        assumedTimeZoneIdentifier: String,
        includeIntegrityFacts: Bool
    ) throws -> BackfilledFacts {
        let legacy = try context.fetch(
            FetchDescriptor<CountdownRecord>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
        )
        guard try context.fetch(FetchDescriptor<CountdownStateRecord>()).isEmpty,
              try context.fetch(
                  FetchDescriptor<CountdownLifecycleEventRecord>()
              ).isEmpty,
              try context.fetch(
                  FetchDescriptor<CountdownReminderRuleRecord>()
              ).isEmpty else {
            throw AppDataFailure.migrationFailed
        }
        let activeCount = legacy.count { $0.archivedAt == nil }
        var facts = BackfilledFacts()
        for source in legacy {
            let eventID = stableUUID(
                namespace: "legacy-countdown-event",
                sourceID: source.id
            )
            let operationID = stableUUID(
                namespace: "legacy-countdown-operation",
                sourceID: source.id
            )
            let targetDate = try civilDate(
                from: source.targetDate,
                timeZoneIdentifier: assumedTimeZoneIdentifier
            )
            let lifecycle: CountdownLifecycle = source.archivedAt == nil
                ? .active
                : .archived
            let requiresReview = activeCount > 1
                || (source.archivedAt != nil && source.continuesCountingUp)
            let timestamp = try HistoricalTimestamp.legacyAssumed(
                instant: source.archivedAt ?? source.createdAt,
                assumedTimeZoneIdentifier: assumedTimeZoneIdentifier,
                precision: .subsecond
            )
            let canonical = CountdownStateRecord(
                id: source.id,
                title: source.title,
                gentleTitle: source.gentleTitle,
                targetDate: targetDate,
                lifecycle: lifecycle,
                overdueMode: source.continuesCountingUp
                    ? .countingUp
                    : .awaitingDecision,
                showInToday: lifecycle == .active
                    && activeCount == 1
                    && !requiresReview,
                latestEventID: eventID,
                archivedAt: source.archivedAt,
                terminalReminderWasEnabled:
                    source.archivedAt == nil ? nil : false,
                terminalReminderLeadDays:
                    source.archivedAt == nil ? nil : 0,
                terminalReminderLocalHour:
                    source.archivedAt == nil ? nil : 9,
                terminalReminderLocalMinute:
                    source.archivedAt == nil ? nil : 0,
                requiresReview: requiresReview,
                createdAt: source.createdAt,
                updatedAt: source.archivedAt ?? source.createdAt
            )
            let event = CountdownLifecycleEventRecord(
                id: eventID,
                countdownID: source.id,
                kind: .migratedSnapshot,
                operationID: operationID,
                newTargetDate: targetDate,
                timestamp: timestamp
            )
            let reminder = CountdownReminderRuleRecord(
                countdownID: source.id,
                isEnabled: false,
                lastOperationID: operationID,
                updatedAt: source.archivedAt ?? source.createdAt
            )
            let commandDigest: String
            if includeIntegrityFacts {
                let audit = CountdownCommandAuditRecord(
                    eventID: event.id,
                    operationID: operationID,
                    countdownID: source.id,
                    commandKind: .migratedSnapshot,
                    titleCommitment:
                        try CountdownIntegrityDigest.privateCommitment(
                            source.title,
                            operationID: operationID,
                            label: "title"
                        ),
                    gentleTitleCommitment:
                        try CountdownIntegrityDigest.privateCommitment(
                            source.gentleTitle,
                            operationID: operationID,
                            label: "gentleTitle"
                        ),
                    targetDate: targetDate,
                    showInToday: canonical.showInToday,
                    reminder: .disabled,
                    eventTimestampCommitment:
                        try CountdownIntegrityDigest.timestampCommitment(
                            timestamp,
                            operationID: operationID
                        ),
                    eventSemanticDigest:
                        try CountdownIntegrityDigest.eventSemantic(event),
                    preFactsDigest:
                        try CountdownIntegrityDigest
                            .absentFactsDigest(),
                    postFactsDigest: try CountdownIntegrityDigest.facts(
                        state: canonical,
                        reminder: reminder,
                        legacy: source
                    ),
                    terminalReminderWasEnabled:
                        canonical.terminalReminderWasEnabled,
                    terminalReminderLeadDays:
                        canonical.terminalReminderLeadDays,
                    terminalReminderLocalHour:
                        canonical.terminalReminderLocalHour,
                    terminalReminderLocalMinute:
                        canonical.terminalReminderLocalMinute,
                    committedAt: source.archivedAt ?? source.createdAt
                )
                try audit.seal()
                context.insert(audit)
                facts.audits.append(audit)
                commandDigest = audit.commandDigest
            } else {
                commandDigest = try migrationCommandDigest(
                    source: source,
                    state: canonical,
                    event: event,
                    reminder: reminder
                )
            }
            let receipt = OperationReceiptRecord(
                operationID: operationID,
                commandDigest: commandDigest,
                resultRecordType: "CountdownLifecycleEventRecord",
                resultRecordID: event.id,
                committedAt: source.archivedAt ?? source.createdAt
            )
            context.insert(canonical)
            context.insert(event)
            context.insert(reminder)
            context.insert(receipt)
            facts.states.append(canonical)
            facts.events.append(event)
            facts.reminders.append(reminder)
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
        guard metadataRecords.count == 1,
              let metadata = metadataRecords.first else {
            throw AppDataFailure.migrationFailed
        }
        var revisionFacts: [(String, UUID, [RecordDigestV1.Field], Date)] = []
        revisionFacts += try facts.states.map {
            ("CountdownStateRecord", $0.id, try CountdownDigestV1.state($0), $0.updatedAt)
        }
        revisionFacts += try facts.events.map {
            ("CountdownLifecycleEventRecord", $0.id, try CountdownDigestV1.event($0), $0.occurredAt)
        }
        revisionFacts += try facts.reminders.map {
            ("CountdownReminderRuleRecord", $0.id, try CountdownDigestV1.reminder($0), $0.updatedAt)
        }
        revisionFacts += try facts.receipts.map {
            (
                "OperationReceiptRecord",
                $0.operationID,
                try TodayExecutionDigestV1.operationReceipt($0),
                $0.committedAt
            )
        }
        revisionFacts += try facts.audits.map {
            (
                "CountdownCommandAuditRecord",
                $0.eventID,
                try CountdownIntegrityDigest.revisionFields($0),
                $0.committedAt
            )
        }
        revisionFacts.sort {
            $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.uuidString < $1.1.uuidString
        }
        var existingKeys = Set(
            try context.fetch(FetchDescriptor<RecordRevision>()).map(\.recordKey)
        )
        for (type, id, fields, committedAt) in revisionFacts {
            let key = type + ":" + id.uuidString.lowercased()
            guard existingKeys.insert(key).inserted,
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
                    committedAt: committedAt
                )
            )
            metadata.nextLocalRevision += 1
        }

        if !facts.receipts.isEmpty {
            var ledgerDescriptor = FetchDescriptor<OperationReceiptLedgerRecord>()
            ledgerDescriptor.fetchLimit = 2
            let ledgers = try context.fetch(ledgerDescriptor)
            guard ledgers.count == 1,
                  let ledger = ledgers.first,
                  metadata.nextLocalRevision > 0,
                  metadata.nextLocalRevision < Int64.max else {
                throw AppDataFailure.migrationFailed
            }
            var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>()
            receiptDescriptor.fetchLimit = 65_537
            let receipts = try context.fetch(receiptDescriptor)
            guard receipts.count <= 65_536 else {
                throw AppDataFailure.migrationFailed
            }
            ledger.receiptCount = receipts.count
            ledger.receiptSetDigest = try TodayExecutionDigestV1.receiptSetDigest(receipts)
            ledger.updatedAt = now

            let recordType = "OperationReceiptLedgerRecord"
            let recordID = TodayExecutionDigestV1.receiptLedgerID
            let key = recordType + ":" + recordID.uuidString.lowercased()
            var revisionDescriptor = FetchDescriptor<RecordRevision>(
                predicate: #Predicate { $0.recordKey == key }
            )
            revisionDescriptor.fetchLimit = 2
            let revisions = try context.fetch(revisionDescriptor)
            guard revisions.count == 1,
                  let revision = revisions.first else {
                throw AppDataFailure.migrationFailed
            }
            revision.datasetID = metadata.datasetID
            revision.localRevision = metadata.nextLocalRevision
            revision.digestVersion = RecordDigestV1.version
            revision.digestHex = try RecordDigestV1.sha256Hex(
                recordType: recordType,
                recordID: recordID,
                fields: TodayExecutionDigestV1.operationReceiptLedger(ledger)
            )
            revision.committedAt = now
            metadata.nextLocalRevision += 1
            metadata.lastCommittedAt = now
        }
    }

    private static func validateCompletedMarker(
        in context: ModelContext,
        state: CountdownLifecycleBackfillState
    ) throws {
        guard state.taskKey == CountdownLifecycleBackfillState.fixedKey,
              state.completedAt?.timeIntervalSince1970.isFinite == true,
              state.updatedAt.timeIntervalSince1970.isFinite,
              TimeZone(identifier: state.assumedTimeZoneIdentifier) != nil else {
            throw AppDataFailure.migrationFailed
        }
        let coverage = try context.fetch(
            FetchDescriptor<CountdownNotificationCoverageRecord>()
        )
        guard coverage.count == 1,
              coverage.first?.coverageKey
                == CountdownNotificationCoverageRecord.fixedKey,
              coverage.first?.status != nil else {
            throw AppDataFailure.migrationFailed
        }
    }

    private static func validateFreshMigrationOutcome(
        in context: ModelContext,
        state: CountdownLifecycleBackfillState
    ) throws {
        try validateCompletedMarker(in: context, state: state)
        let legacyCount = try context.fetchCount(
            FetchDescriptor<CountdownRecord>()
        )
        guard try context.fetchCount(
                  FetchDescriptor<CountdownStateRecord>()
              ) == legacyCount,
              try context.fetchCount(
                  FetchDescriptor<CountdownLifecycleEventRecord>()
              ) == legacyCount,
              try context.fetchCount(
                  FetchDescriptor<CountdownReminderRuleRecord>()
              ) == legacyCount else {
            throw AppDataFailure.migrationFailed
        }
    }

    static func migrationCommandDigest(
        source: CountdownRecord,
        state: CountdownStateRecord,
        event: CountdownLifecycleEventRecord,
        reminder: CountdownReminderRuleRecord
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "MigrateLegacyCountdownCommand",
            recordID: event.operationID,
            fields: [
                .init("legacyID", .uuid(source.id)),
                .init("legacyDigest", .string(try FactDigestV1.digest(source))),
                .init(
                    "stateDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "CountdownStateRecord",
                            recordID: state.id,
                            fields: CountdownDigestV1.state(state)
                        )
                    )
                ),
                .init(
                    "eventDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "CountdownLifecycleEventRecord",
                            recordID: event.id,
                            fields: CountdownDigestV1.eventSemantic(event)
                        )
                    )
                ),
                .init(
                    "reminderDigest",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "CountdownReminderRuleRecord",
                            recordID: reminder.id,
                            fields: CountdownDigestV1.reminder(reminder)
                        )
                    )
                )
            ]
        )
    }

    private static func requiredBackfillState(
        in context: ModelContext
    ) throws -> CountdownLifecycleBackfillState {
        var descriptor = FetchDescriptor<CountdownLifecycleBackfillState>()
        descriptor.fetchLimit = 2
        let states = try context.fetch(descriptor)
        guard states.count == 1, let state = states.first else {
            throw AppDataFailure.migrationFailed
        }
        return state
    }

    private static func civilDate(
        from date: Date,
        timeZoneIdentifier: String
    ) throws -> CivilDateFact {
        guard date.timeIntervalSince1970.isFinite,
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw AppDataFailure.migrationFailed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw AppDataFailure.migrationFailed
        }
        return try CivilDateFact(year: year, month: month, day: day)
    }

    private static func stableUUID(namespace: String, sourceID: UUID) -> UUID {
        CoreTimeRegimenBackfill.stableUUID(
            for: namespace + ":" + sourceID.uuidString.lowercased()
        )
    }
}
