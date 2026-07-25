import Foundation
import SwiftData

enum CountdownWriteFailure: Error, Equatable, Sendable {
    case invalidInput
    case operationConflict
    case activeCountdownAlreadyExists
    case staleRecord
    case invalidTransition
}

enum CountdownWriteFailureInjection: Equatable, Sendable {
    case afterOldDeletionBeforeNewCreation
}

struct CountdownReminderInput: Equatable, Sendable {
    static let disabled = CountdownReminderInput(
        isEnabled: false,
        leadDays: 0,
        localHour: 9,
        localMinute: 0
    )

    let isEnabled: Bool
    let leadDays: Int
    let localHour: Int
    let localMinute: Int
}

struct CountdownMutationResult: Equatable, Sendable {
    let countdownID: UUID
    let eventID: UUID
    let didApply: Bool
}

struct CreateCountdownCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let countdownID: UUID
    let title: String
    let gentleTitle: String?
    let targetDate: CivilDateFact
    let showInToday: Bool
    let reminder: CountdownReminderInput
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID = UUID(),
        title: String,
        gentleTitle: String?,
        targetDate: CivilDateFact,
        showInToday: Bool,
        reminder: CountdownReminderInput,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.countdownID = countdownID
        self.title = title
        self.gentleTitle = gentleTitle
        self.targetDate = targetDate
        self.showInToday = showInToday
        self.reminder = reminder
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
    }
}

struct UpdateCountdownCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let countdownID: UUID
    let expectedLatestEventID: UUID
    let title: String
    let gentleTitle: String?
    let targetDate: CivilDateFact
    let showInToday: Bool
    let reminder: CountdownReminderInput
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedLatestEventID: UUID,
        title: String,
        gentleTitle: String?,
        targetDate: CivilDateFact,
        showInToday: Bool,
        reminder: CountdownReminderInput,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.countdownID = countdownID
        self.expectedLatestEventID = expectedLatestEventID
        self.title = title
        self.gentleTitle = gentleTitle
        self.targetDate = targetDate
        self.showInToday = showInToday
        self.reminder = reminder
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
    }
}

enum CountdownReviewResolution: String, Equatable, Sendable {
    case keepAsCurrent
    case archive
    case keepArchived
}

struct ResolveCountdownReviewCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let countdownID: UUID
    let expectedLatestEventID: UUID
    let resolution: CountdownReviewResolution
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedLatestEventID: UUID,
        resolution: CountdownReviewResolution,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.countdownID = countdownID
        self.expectedLatestEventID = expectedLatestEventID
        self.resolution = resolution
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
    }
}

struct ContinueCountdownCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let countdownID: UUID
    let expectedLatestEventID: UUID
    let today: CivilDateFact
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedLatestEventID: UUID,
        today: CivilDateFact,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.countdownID = countdownID
        self.expectedLatestEventID = expectedLatestEventID
        self.today = today
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
    }
}

struct CompleteCountdownCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let countdownID: UUID
    let expectedLatestEventID: UUID
    let today: CivilDateFact
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedLatestEventID: UUID,
        today: CivilDateFact,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.countdownID = countdownID
        self.expectedLatestEventID = expectedLatestEventID
        self.today = today
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
    }
}

struct ArchiveCountdownCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let countdownID: UUID
    let expectedLatestEventID: UUID
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedLatestEventID: UUID,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.countdownID = countdownID
        self.expectedLatestEventID = expectedLatestEventID
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
    }
}

struct DeleteCountdownCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let countdownID: UUID
    let expectedLatestEventID: UUID
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedLatestEventID: UUID,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.countdownID = countdownID
        self.expectedLatestEventID = expectedLatestEventID
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
    }
}

struct ReplaceCountdownCommand: Sendable {
    let operationID: UUID
    let deleteEventID: UUID
    let newEventID: UUID
    let countdownID: UUID
    let expectedLatestEventID: UUID
    let newCountdownID: UUID
    let title: String
    let gentleTitle: String?
    let targetDate: CivilDateFact
    let showInToday: Bool
    let reminder: CountdownReminderInput
    let timestamp: HistoricalTimestamp
    let committedAt: Date
    let failureInjection: CountdownWriteFailureInjection?

    init(
        operationID: UUID,
        deleteEventID: UUID,
        newEventID: UUID,
        countdownID: UUID,
        expectedLatestEventID: UUID,
        newCountdownID: UUID = UUID(),
        title: String,
        gentleTitle: String?,
        targetDate: CivilDateFact,
        showInToday: Bool,
        reminder: CountdownReminderInput,
        timestamp: HistoricalTimestamp,
        committedAt: Date? = nil,
        failureInjection: CountdownWriteFailureInjection? = nil
    ) {
        self.operationID = operationID
        self.deleteEventID = deleteEventID
        self.newEventID = newEventID
        self.countdownID = countdownID
        self.expectedLatestEventID = expectedLatestEventID
        self.newCountdownID = newCountdownID
        self.title = title
        self.gentleTitle = gentleTitle
        self.targetDate = targetDate
        self.showInToday = showInToday
        self.reminder = reminder
        self.timestamp = timestamp
        self.committedAt = committedAt ?? timestamp.instant
        self.failureInjection = failureInjection
    }
}

extension AppWriteActor {
    func createCountdown(
        _ command: CreateCountdownCommand
    ) throws -> CountdownMutationResult {
        let normalized = try normalizedContent(
            title: command.title,
            gentleTitle: command.gentleTitle,
            reminder: command.reminder
        )
        let digest = try CountdownDigestV1.createCommand(command, normalized: normalized)
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        guard try fetchCountdownState(id: command.countdownID) == nil,
              try fetchCountdownEvent(id: command.eventID) == nil else {
            throw CountdownWriteFailure.staleRecord
        }
        guard try activeCountdownStates().isEmpty else {
            throw CountdownWriteFailure.activeCountdownAlreadyExists
        }
        let legacyTarget = try legacyDisplayDate(
            command.targetDate,
            timeZoneIdentifier: command.timestamp.timeZoneIdentifier
        )
        let reservation = try reserveRevision(committedAt: command.committedAt)
        modelContext.autosaveEnabled = false
        do {
            var result: CountdownMutationResult?
            try modelContext.transaction {
                if let replay = try countdownReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                guard try fetchCountdownState(id: command.countdownID) == nil,
                      try fetchCountdownEvent(id: command.eventID) == nil else {
                    throw CountdownWriteFailure.staleRecord
                }
                guard try activeCountdownStates().isEmpty else {
                    throw CountdownWriteFailure.activeCountdownAlreadyExists
                }

                let event = CountdownLifecycleEventRecord(
                    id: command.eventID,
                    countdownID: command.countdownID,
                    kind: .created,
                    operationID: command.operationID,
                    newTargetDate: command.targetDate,
                    timestamp: command.timestamp
                )
                let state = CountdownStateRecord(
                    id: command.countdownID,
                    title: normalized.title,
                    gentleTitle: normalized.gentleTitle,
                    targetDate: command.targetDate,
                    showInToday: command.showInToday,
                    latestEventID: event.id,
                    createdAt: command.timestamp.instant,
                    updatedAt: command.timestamp.instant
                )
                let reminder = CountdownReminderRuleRecord(
                    countdownID: command.countdownID,
                    isEnabled: normalized.reminder.isEnabled,
                    leadDays: normalized.reminder.leadDays,
                    localHour: normalized.reminder.localHour,
                    localMinute: normalized.reminder.localMinute,
                    lastOperationID: command.operationID,
                    updatedAt: command.timestamp.instant
                )
                let legacy = CountdownRecord(
                    id: command.countdownID,
                    title: normalized.title,
                    gentleTitle: normalized.gentleTitle,
                    targetDate: legacyTarget,
                    createdAt: command.timestamp.instant
                )
                modelContext.insert(event)
                modelContext.insert(state)
                modelContext.insert(reminder)
                modelContext.insert(legacy)
                try persistCountdownFacts(
                    state: state,
                    event: event,
                    reminder: reminder,
                    legacy: legacy,
                    commandDigest: digest,
                    operationID: command.operationID,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                result = CountdownMutationResult(
                    countdownID: state.id,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let result else { throw CountdownWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func updateCountdown(
        _ command: UpdateCountdownCommand
    ) throws -> CountdownMutationResult {
        let normalized = try normalizedContent(
            title: command.title,
            gentleTitle: command.gentleTitle,
            reminder: command.reminder
        )
        let digest = try CountdownDigestV1.updateCommand(command, normalized: normalized)
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        _ = try requiredActiveState(
            id: command.countdownID,
            expectedEventID: command.expectedLatestEventID
        )
        guard try fetchCountdownEvent(id: command.eventID) == nil else {
            throw CountdownWriteFailure.staleRecord
        }
        let legacyTarget = try legacyDisplayDate(
            command.targetDate,
            timeZoneIdentifier: command.timestamp.timeZoneIdentifier
        )
        let reservation = try reserveRevision(committedAt: command.committedAt)
        modelContext.autosaveEnabled = false
        do {
            var result: CountdownMutationResult?
            try modelContext.transaction {
                if let replay = try countdownReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let current = try requiredActiveState(
                    id: command.countdownID,
                    expectedEventID: command.expectedLatestEventID
                )
                guard try fetchCountdownEvent(id: command.eventID) == nil,
                      let legacy = try fetchLegacyCountdown(id: current.id),
                      let reminder = try fetchCountdownReminder(countdownID: current.id),
                      let oldTarget = current.targetDate else {
                    throw CountdownWriteFailure.staleRecord
                }
                let targetChanged = oldTarget != command.targetDate
                let contentChanged = current.title != normalized.title
                    || current.gentleTitle != normalized.gentleTitle
                    || targetChanged
                let visibilityChanged =
                    current.showInToday != command.showInToday
                let reminderChanged =
                    reminder.isEnabled != normalized.reminder.isEnabled
                    || reminder.leadDays != normalized.reminder.leadDays
                    || reminder.localHour != normalized.reminder.localHour
                    || reminder.localMinute
                        != normalized.reminder.localMinute
                let changedCategoryCount = [
                    contentChanged,
                    visibilityChanged,
                    reminderChanged
                ].filter { $0 }.count
                let eventKind: CountdownLifecycleEventKind
                if changedCategoryCount == 1, visibilityChanged {
                    eventKind = .visibilityChanged
                } else if changedCategoryCount == 1, reminderChanged {
                    eventKind = .reminderChanged
                } else {
                    eventKind = .edited
                }
                let event = CountdownLifecycleEventRecord(
                    id: command.eventID,
                    countdownID: current.id,
                    kind: eventKind,
                    previousEventID: current.latestEventID,
                    operationID: command.operationID,
                    oldTargetDate: oldTarget,
                    newTargetDate: command.targetDate,
                    timestamp: command.timestamp
                )
                modelContext.insert(event)
                current.title = normalized.title
                current.gentleTitle = normalized.gentleTitle
                current.setTargetDate(command.targetDate)
                current.showInToday = command.showInToday
                current.latestEventID = event.id
                current.updatedAt = command.timestamp.instant
                if targetChanged {
                    current.overdueModeRawValue =
                        CountdownOverdueMode.awaitingDecision.rawValue
                }
                reminder.isEnabled = normalized.reminder.isEnabled
                reminder.leadDays = normalized.reminder.leadDays
                reminder.localHour = normalized.reminder.localHour
                reminder.localMinute = normalized.reminder.localMinute
                reminder.lastOperationID = command.operationID
                reminder.updatedAt = command.timestamp.instant
                legacy.title = normalized.title
                legacy.gentleTitle = normalized.gentleTitle
                legacy.targetDate = legacyTarget
                if targetChanged {
                    legacy.continuesCountingUp = false
                }
                try persistCountdownFacts(
                    state: current,
                    event: event,
                    reminder: reminder,
                    legacy: legacy,
                    commandDigest: digest,
                    operationID: command.operationID,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                result = CountdownMutationResult(
                    countdownID: current.id,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let result else { throw CountdownWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func resolveCountdownReview(
        _ command: ResolveCountdownReviewCommand
    ) throws -> CountdownMutationResult {
        let digest = try CountdownDigestV1.reviewResolutionCommand(command)
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        let reviewed = try requiredReviewState(
            id: command.countdownID,
            expectedEventID: command.expectedLatestEventID
        )
        try validateReviewResolution(command.resolution, state: reviewed)
        guard try fetchCountdownEvent(id: command.eventID) == nil else {
            throw CountdownWriteFailure.staleRecord
        }
        let reservation = try reserveRevision(
            committedAt: command.committedAt
        )
        modelContext.autosaveEnabled = false
        do {
            var result: CountdownMutationResult?
            try modelContext.transaction {
                if let replay = try countdownReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let state = try requiredReviewState(
                    id: command.countdownID,
                    expectedEventID: command.expectedLatestEventID
                )
                try validateReviewResolution(
                    command.resolution,
                    state: state
                )
                guard try fetchCountdownEvent(id: command.eventID) == nil,
                      let target = state.targetDate,
                      let legacy = try fetchLegacyCountdown(id: state.id),
                      let reminder = try fetchCountdownReminder(
                          countdownID: state.id
                      ) else {
                    throw CountdownWriteFailure.staleRecord
                }
                let kind: CountdownLifecycleEventKind =
                    command.resolution == .archive
                        ? .archived
                        : .reviewResolved
                let event = CountdownLifecycleEventRecord(
                    id: command.eventID,
                    countdownID: state.id,
                    kind: kind,
                    previousEventID: state.latestEventID,
                    operationID: command.operationID,
                    oldTargetDate: target,
                    newTargetDate: target,
                    timestamp: command.timestamp
                )
                modelContext.insert(event)
                switch command.resolution {
                case .keepAsCurrent:
                    state.requiresReview = false
                    state.showInToday = true
                case .archive:
                    state.setTerminalReminderSnapshot(from: reminder)
                    state.lifecycleRawValue =
                        CountdownLifecycle.archived.rawValue
                    state.overdueModeRawValue =
                        CountdownOverdueMode.awaitingDecision.rawValue
                    state.showInToday = false
                    state.archivedAt = command.timestamp.instant
                    state.requiresReview = false
                    legacy.archivedAt = command.timestamp.instant
                    legacy.continuesCountingUp = false
                    reminder.isEnabled = false
                case .keepArchived:
                    state.requiresReview = false
                    state.overdueModeRawValue =
                        CountdownOverdueMode.awaitingDecision.rawValue
                    legacy.continuesCountingUp = false
                }
                state.latestEventID = event.id
                state.updatedAt = command.timestamp.instant
                reminder.lastOperationID = command.operationID
                reminder.updatedAt = command.timestamp.instant
                try persistCountdownFacts(
                    state: state,
                    event: event,
                    reminder: reminder,
                    legacy: legacy,
                    commandDigest: digest,
                    operationID: command.operationID,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                result = CountdownMutationResult(
                    countdownID: state.id,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let result else {
                throw CountdownWriteFailure.invalidInput
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func continueCountdown(
        _ command: ContinueCountdownCommand
    ) throws -> CountdownMutationResult {
        let digest = try CountdownDigestV1.continueCommand(command)
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        let state = try requiredActiveState(
            id: command.countdownID,
            expectedEventID: command.expectedLatestEventID
        )
        guard let target = state.targetDate,
              CountdownLifecycleRules.canContinueCounting(
                  lifecycle: .active,
                  target: target,
                  today: command.today
              ),
              try fetchCountdownEvent(id: command.eventID) == nil else {
            throw CountdownWriteFailure.invalidTransition
        }
        return try transitionCountdown(
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            eventID: command.eventID,
            operationID: command.operationID,
            kind: .continuedCountingUp,
            timestamp: command.timestamp,
            committedAt: command.committedAt,
            commandDigest: digest
        ) { state, legacy, reminder in
            state.overdueModeRawValue = CountdownOverdueMode.countingUp.rawValue
            legacy.continuesCountingUp = true
            reminder.lastOperationID = command.operationID
            reminder.updatedAt = command.timestamp.instant
        }
    }

    func completeCountdown(
        _ command: CompleteCountdownCommand
    ) throws -> CountdownMutationResult {
        let digest = try CountdownDigestV1.completeCommand(command)
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        let state = try requiredActiveState(
            id: command.countdownID,
            expectedEventID: command.expectedLatestEventID
        )
        guard let target = state.targetDate,
              CountdownLifecycleRules.canComplete(
                  lifecycle: .active,
                  target: target,
                  today: command.today
              ),
              try fetchCountdownEvent(id: command.eventID) == nil else {
            throw CountdownWriteFailure.invalidTransition
        }
        return try transitionCountdown(
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            eventID: command.eventID,
            operationID: command.operationID,
            kind: .completed,
            timestamp: command.timestamp,
            committedAt: command.committedAt,
            commandDigest: digest
        ) { state, legacy, reminder in
            state.lifecycleRawValue = CountdownLifecycle.completed.rawValue
            state.showInToday = false
            state.completedAt = command.timestamp.instant
            state.archivedAt = command.timestamp.instant
            legacy.archivedAt = command.timestamp.instant
            legacy.continuesCountingUp = false
            reminder.isEnabled = false
            reminder.lastOperationID = command.operationID
            reminder.updatedAt = command.timestamp.instant
        }
    }

    func archiveCountdown(
        _ command: ArchiveCountdownCommand
    ) throws -> CountdownMutationResult {
        let digest = try CountdownDigestV1.archiveCommand(command)
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        _ = try requiredActiveState(
            id: command.countdownID,
            expectedEventID: command.expectedLatestEventID
        )
        guard try fetchCountdownEvent(id: command.eventID) == nil else {
            throw CountdownWriteFailure.staleRecord
        }
        return try transitionCountdown(
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            eventID: command.eventID,
            operationID: command.operationID,
            kind: .archived,
            timestamp: command.timestamp,
            committedAt: command.committedAt,
            commandDigest: digest
        ) { state, legacy, reminder in
            state.lifecycleRawValue = CountdownLifecycle.archived.rawValue
            state.showInToday = false
            state.archivedAt = command.timestamp.instant
            legacy.archivedAt = command.timestamp.instant
            legacy.continuesCountingUp = false
            reminder.isEnabled = false
            reminder.lastOperationID = command.operationID
            reminder.updatedAt = command.timestamp.instant
        }
    }

    func deleteCountdown(
        _ command: DeleteCountdownCommand
    ) throws -> CountdownMutationResult {
        let digest = try CountdownDigestV1.deleteCommand(command)
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        _ = try requiredActiveState(
            id: command.countdownID,
            expectedEventID: command.expectedLatestEventID
        )
        guard try fetchCountdownEvent(id: command.eventID) == nil else {
            throw CountdownWriteFailure.staleRecord
        }
        let reservation = try reserveRevision(committedAt: command.committedAt)
        modelContext.autosaveEnabled = false
        do {
            var result: CountdownMutationResult?
            try modelContext.transaction {
                if let replay = try countdownReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let state = try requiredActiveState(
                    id: command.countdownID,
                    expectedEventID: command.expectedLatestEventID
                )
                guard try fetchCountdownEvent(id: command.eventID) == nil,
                      let target = state.targetDate,
                      let legacy = try fetchLegacyCountdown(id: state.id),
                      let reminder = try fetchCountdownReminder(
                          countdownID: state.id
                      ) else {
                    throw CountdownWriteFailure.staleRecord
                }
                let event = CountdownLifecycleEventRecord(
                    id: command.eventID,
                    countdownID: state.id,
                    kind: .deleted,
                    previousEventID: state.latestEventID,
                    operationID: command.operationID,
                    oldTargetDate: target,
                    timestamp: command.timestamp
                )
                modelContext.insert(event)
                applyDeletedState(
                    state,
                    reminder: reminder,
                    event: event,
                    operationID: command.operationID,
                    timestamp: command.timestamp.instant
                )
                try deleteCountdownRevision(
                    recordType: "CountdownRecord",
                    recordID: legacy.id
                )
                modelContext.delete(legacy)
                try persistDeletedCountdownFacts(
                    state: state,
                    event: event,
                    reminder: reminder,
                    commandDigest: digest,
                    operationID: command.operationID,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                result = CountdownMutationResult(
                    countdownID: state.id,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let result else { throw CountdownWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func replaceCountdown(
        _ command: ReplaceCountdownCommand
    ) throws -> CountdownMutationResult {
        let normalized = try normalizedContent(
            title: command.title,
            gentleTitle: command.gentleTitle,
            reminder: command.reminder
        )
        let digest = try CountdownDigestV1.replaceCommand(
            command,
            normalized: normalized
        )
        if let replay = try countdownReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        let deletionOperationID = replacementDeletionOperationID(
            command.operationID
        )
        _ = try requiredActiveState(
            id: command.countdownID,
            expectedEventID: command.expectedLatestEventID
        )
        guard command.newCountdownID != command.countdownID,
              command.deleteEventID != command.newEventID,
              try fetchCountdownState(id: command.newCountdownID) == nil,
              try fetchCountdownEvent(id: command.deleteEventID) == nil,
              try fetchCountdownEvent(id: command.newEventID) == nil,
              try fetchOperationReceipt(
                  operationID: deletionOperationID
              ) == nil else {
            throw CountdownWriteFailure.staleRecord
        }
        let legacyTarget = try legacyDisplayDate(
            command.targetDate,
            timeZoneIdentifier: command.timestamp.timeZoneIdentifier
        )
        let deletionDigest = try CountdownDigestV1
            .replacementDeletionCommand(
                operationID: deletionOperationID,
                primaryCommandDigest: digest,
                countdownID: command.countdownID,
                eventID: command.deleteEventID,
                replacementCountdownID: command.newCountdownID,
                committedAt: command.committedAt
            )
        let reservation = try reserveRevision(committedAt: command.committedAt)
        modelContext.autosaveEnabled = false
        do {
            var result: CountdownMutationResult?
            try modelContext.transaction {
                if let replay = try countdownReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let oldState = try requiredActiveState(
                    id: command.countdownID,
                    expectedEventID: command.expectedLatestEventID
                )
                guard let oldTarget = oldState.targetDate,
                      let oldLegacy = try fetchLegacyCountdown(id: oldState.id),
                      let oldReminder = try fetchCountdownReminder(
                          countdownID: oldState.id
                      ),
                      try fetchCountdownState(id: command.newCountdownID) == nil,
                      try fetchCountdownEvent(id: command.deleteEventID) == nil,
                      try fetchCountdownEvent(id: command.newEventID) == nil,
                      try fetchOperationReceipt(
                          operationID: deletionOperationID
                      ) == nil else {
                    throw CountdownWriteFailure.staleRecord
                }

                let deleteEvent = CountdownLifecycleEventRecord(
                    id: command.deleteEventID,
                    countdownID: oldState.id,
                    kind: .replaced,
                    previousEventID: oldState.latestEventID,
                    operationID: deletionOperationID,
                    oldTargetDate: oldTarget,
                    replacementCountdownID: command.newCountdownID,
                    timestamp: command.timestamp
                )
                modelContext.insert(deleteEvent)
                applyDeletedState(
                    oldState,
                    reminder: oldReminder,
                    event: deleteEvent,
                    operationID: deletionOperationID,
                    timestamp: command.timestamp.instant
                )
                try deleteCountdownRevision(
                    recordType: "CountdownRecord",
                    recordID: oldLegacy.id
                )
                modelContext.delete(oldLegacy)
                try persistDeletedCountdownFacts(
                    state: oldState,
                    event: deleteEvent,
                    reminder: oldReminder,
                    commandDigest: deletionDigest,
                    operationID: deletionOperationID,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                if command.failureInjection
                    == .afterOldDeletionBeforeNewCreation {
                    throw AppWriteFailure.injected
                }

                let newEvent = CountdownLifecycleEventRecord(
                    id: command.newEventID,
                    countdownID: command.newCountdownID,
                    kind: .created,
                    operationID: command.operationID,
                    newTargetDate: command.targetDate,
                    timestamp: command.timestamp
                )
                let newState = CountdownStateRecord(
                    id: command.newCountdownID,
                    title: normalized.title,
                    gentleTitle: normalized.gentleTitle,
                    targetDate: command.targetDate,
                    showInToday: command.showInToday,
                    latestEventID: newEvent.id,
                    createdAt: command.timestamp.instant,
                    updatedAt: command.timestamp.instant
                )
                let newReminder = CountdownReminderRuleRecord(
                    countdownID: command.newCountdownID,
                    isEnabled: normalized.reminder.isEnabled,
                    leadDays: normalized.reminder.leadDays,
                    localHour: normalized.reminder.localHour,
                    localMinute: normalized.reminder.localMinute,
                    lastOperationID: command.operationID,
                    updatedAt: command.timestamp.instant
                )
                let newLegacy = CountdownRecord(
                    id: command.newCountdownID,
                    title: normalized.title,
                    gentleTitle: normalized.gentleTitle,
                    targetDate: legacyTarget,
                    createdAt: command.timestamp.instant
                )
                modelContext.insert(newEvent)
                modelContext.insert(newState)
                modelContext.insert(newReminder)
                modelContext.insert(newLegacy)
                try persistCountdownFacts(
                    state: newState,
                    event: newEvent,
                    reminder: newReminder,
                    legacy: newLegacy,
                    commandDigest: digest,
                    operationID: command.operationID,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                result = CountdownMutationResult(
                    countdownID: newState.id,
                    eventID: newEvent.id,
                    didApply: true
                )
            }
            guard let result else { throw CountdownWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func transitionCountdown(
        countdownID: UUID,
        expectedEventID: UUID,
        eventID: UUID,
        operationID: UUID,
        kind: CountdownLifecycleEventKind,
        timestamp: HistoricalTimestamp,
        committedAt: Date,
        commandDigest: String,
        mutate: (CountdownStateRecord, CountdownRecord, CountdownReminderRuleRecord) -> Void
    ) throws -> CountdownMutationResult {
        let reservation = try reserveRevision(committedAt: committedAt)
        modelContext.autosaveEnabled = false
        do {
            var result: CountdownMutationResult?
            try modelContext.transaction {
                if let replay = try countdownReplay(
                    operationID: operationID,
                    digest: commandDigest
                ) {
                    result = replay
                    return
                }
                let state = try requiredActiveState(
                    id: countdownID,
                    expectedEventID: expectedEventID
                )
                guard try fetchCountdownEvent(id: eventID) == nil,
                      let target = state.targetDate,
                      let legacy = try fetchLegacyCountdown(id: state.id),
                      let reminder = try fetchCountdownReminder(countdownID: state.id) else {
                    throw CountdownWriteFailure.staleRecord
                }
                let event = CountdownLifecycleEventRecord(
                    id: eventID,
                    countdownID: state.id,
                    kind: kind,
                    previousEventID: state.latestEventID,
                    operationID: operationID,
                    oldTargetDate: target,
                    newTargetDate: target,
                    timestamp: timestamp
                )
                modelContext.insert(event)
                if kind == .completed || kind == .archived {
                    state.setTerminalReminderSnapshot(from: reminder)
                }
                mutate(state, legacy, reminder)
                state.latestEventID = event.id
                state.updatedAt = timestamp.instant
                try persistCountdownFacts(
                    state: state,
                    event: event,
                    reminder: reminder,
                    legacy: legacy,
                    commandDigest: commandDigest,
                    operationID: operationID,
                    reservation: reservation,
                    committedAt: committedAt
                )
                result = CountdownMutationResult(
                    countdownID: state.id,
                    eventID: event.id,
                    didApply: true
                )
            }
            guard let result else { throw CountdownWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    struct NormalizedCountdownContent {
        let title: String
        let gentleTitle: String?
        let reminder: CountdownReminderInput
    }

    private func normalizedContent(
        title: String,
        gentleTitle: String?,
        reminder: CountdownReminderInput
    ) throws -> NormalizedCountdownContent {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGentle = gentleTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              cleanTitle.count <= 120,
              cleanGentle?.count ?? 0 <= 120,
              (0...365).contains(reminder.leadDays),
              (0...23).contains(reminder.localHour),
              (0...59).contains(reminder.localMinute) else {
            throw CountdownWriteFailure.invalidInput
        }
        return NormalizedCountdownContent(
            title: cleanTitle,
            gentleTitle: cleanGentle?.isEmpty == false ? cleanGentle : nil,
            reminder: reminder
        )
    }

    private func requiredActiveState(
        id: UUID,
        expectedEventID: UUID
    ) throws -> CountdownStateRecord {
        guard let state = try fetchCountdownState(id: id),
              state.lifecycle == .active,
              !state.requiresReview,
              state.latestEventID == expectedEventID,
              state.targetDate != nil else {
            throw CountdownWriteFailure.staleRecord
        }
        return state
    }

    private func requiredReviewState(
        id: UUID,
        expectedEventID: UUID
    ) throws -> CountdownStateRecord {
        guard let state = try fetchCountdownState(id: id),
              state.requiresReview,
              state.lifecycle != .deleted,
              state.latestEventID == expectedEventID,
              state.targetDate != nil else {
            throw CountdownWriteFailure.staleRecord
        }
        return state
    }

    private func validateReviewResolution(
        _ resolution: CountdownReviewResolution,
        state: CountdownStateRecord
    ) throws {
        switch resolution {
        case .keepAsCurrent:
            guard state.lifecycle == .active,
                  try activeCountdownStates().count == 1 else {
                throw CountdownWriteFailure.invalidTransition
            }
        case .archive:
            guard state.lifecycle == .active else {
                throw CountdownWriteFailure.invalidTransition
            }
        case .keepArchived:
            guard state.lifecycle == .archived else {
                throw CountdownWriteFailure.invalidTransition
            }
        }
    }

    private func activeCountdownStates() throws -> [CountdownStateRecord] {
        let active = CountdownLifecycle.active.rawValue
        var descriptor = FetchDescriptor<CountdownStateRecord>(
            predicate: #Predicate {
                $0.lifecycleRawValue == active
            }
        )
        descriptor.fetchLimit = 2
        return try modelContext.fetch(descriptor)
    }

    private func fetchCountdownState(id: UUID) throws -> CountdownStateRecord? {
        var descriptor = FetchDescriptor<CountdownStateRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return records.first
    }

    private func fetchCountdownEvent(
        id: UUID
    ) throws -> CountdownLifecycleEventRecord? {
        var descriptor = FetchDescriptor<CountdownLifecycleEventRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return records.first
    }

    private func fetchCountdownReminder(
        countdownID: UUID
    ) throws -> CountdownReminderRuleRecord? {
        let key = CountdownReminderRuleRecord.key(countdownID: countdownID)
        var descriptor = FetchDescriptor<CountdownReminderRuleRecord>(
            predicate: #Predicate { $0.ruleKey == key }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return records.first
    }

    private func fetchLegacyCountdown(id: UUID) throws -> CountdownRecord? {
        var descriptor = FetchDescriptor<CountdownRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return records.first
    }

    private func fetchOperationReceipt(
        operationID: UUID
    ) throws -> OperationReceiptRecord? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return records.first
    }

    private func countdownReplay(
        operationID: UUID,
        digest: String
    ) throws -> CountdownMutationResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 2
        let receipts = try modelContext.fetch(descriptor)
        guard receipts.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard let receipt = receipts.first else { return nil }
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "CountdownLifecycleEventRecord",
              let event = try fetchCountdownEvent(id: receipt.resultRecordID),
              event.operationID == operationID,
              try fetchCountdownState(id: event.countdownID) != nil else {
            throw CountdownWriteFailure.operationConflict
        }
        return CountdownMutationResult(
            countdownID: event.countdownID,
            eventID: event.id,
            didApply: false
        )
    }

    private func persistCountdownFacts(
        state: CountdownStateRecord,
        event: CountdownLifecycleEventRecord,
        reminder: CountdownReminderRuleRecord,
        legacy: CountdownRecord,
        commandDigest: String,
        operationID: UUID,
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        try upsertRevision(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: try CountdownDigestV1.state(state),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "CountdownLifecycleEventRecord",
            recordID: event.id,
            fields: try CountdownDigestV1.event(event),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "CountdownReminderRuleRecord",
            recordID: reminder.id,
            fields: try CountdownDigestV1.reminder(reminder),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: try FactDigestV1.countdown(legacy),
            reservation: reservation,
            committedAt: committedAt
        )
        try insertOperationReceipt(
            OperationReceiptRecord(
                operationID: operationID,
                commandDigest: commandDigest,
                resultRecordType: "CountdownLifecycleEventRecord",
                resultRecordID: event.id,
                committedAt: committedAt
            ),
            reservation: reservation
        )
        try markCommitted(at: committedAt)
    }

    private func persistDeletedCountdownFacts(
        state: CountdownStateRecord,
        event: CountdownLifecycleEventRecord,
        reminder: CountdownReminderRuleRecord,
        commandDigest: String,
        operationID: UUID,
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        try upsertRevision(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: try CountdownDigestV1.state(state),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "CountdownLifecycleEventRecord",
            recordID: event.id,
            fields: try CountdownDigestV1.event(event),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "CountdownReminderRuleRecord",
            recordID: reminder.id,
            fields: try CountdownDigestV1.reminder(reminder),
            reservation: reservation,
            committedAt: committedAt
        )
        try insertOperationReceipt(
            OperationReceiptRecord(
                operationID: operationID,
                commandDigest: commandDigest,
                resultRecordType: "CountdownLifecycleEventRecord",
                resultRecordID: event.id,
                committedAt: committedAt
            ),
            reservation: reservation
        )
        try markCommitted(at: committedAt)
    }

    private func applyDeletedState(
        _ state: CountdownStateRecord,
        reminder: CountdownReminderRuleRecord,
        event: CountdownLifecycleEventRecord,
        operationID: UUID,
        timestamp: Date
    ) {
        state.title = ""
        state.gentleTitle = nil
        state.setTargetDate(nil)
        state.lifecycleRawValue = CountdownLifecycle.deleted.rawValue
        state.overdueModeRawValue = CountdownOverdueMode.awaitingDecision.rawValue
        state.showInToday = false
        state.latestEventID = event.id
        state.completedAt = nil
        state.archivedAt = nil
        state.deletedAt = timestamp
        state.clearTerminalReminderSnapshot()
        state.requiresReview = false
        state.updatedAt = timestamp
        reminder.isEnabled = false
        reminder.lastOperationID = operationID
        reminder.updatedAt = timestamp
    }

    private func deleteCountdownRevision(
        recordType: String,
        recordID: UUID
    ) throws {
        let key = recordType + ":" + recordID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == key }
        )
        descriptor.fetchLimit = 2
        let revisions = try modelContext.fetch(descriptor)
        guard revisions.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        if let revision = revisions.first {
            modelContext.delete(revision)
        }
    }

    private func replacementDeletionOperationID(_ operationID: UUID) -> UUID {
        CoreTimeRegimenBackfill.stableUUID(
            for: "countdown-replace-delete-operation:"
                + operationID.uuidString.lowercased()
        )
    }

    private func legacyDisplayDate(
        _ date: CivilDateFact,
        timeZoneIdentifier: String
    ) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw CountdownWriteFailure.invalidInput
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let value = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: date.year,
                month: date.month,
                day: date.day,
                hour: 12
            )
        ) else {
            throw CountdownWriteFailure.invalidInput
        }
        return value
    }
}

enum CountdownDigestV1 {
    static func createCommand(
        _ command: CreateCountdownCommand,
        normalized: AppWriteActor.NormalizedCountdownContent
    ) throws -> String {
        try commandDigest(
            type: "CreateCountdownCommand",
            operationID: command.operationID,
            eventID: command.eventID,
            countdownID: command.countdownID,
            expectedEventID: nil,
            title: normalized.title,
            gentleTitle: normalized.gentleTitle,
            targetDate: command.targetDate,
            showInToday: command.showInToday,
            reminder: normalized.reminder,
            today: nil,
            timestamp: command.timestamp,
            committedAt: command.committedAt
        )
    }

    static func updateCommand(
        _ command: UpdateCountdownCommand,
        normalized: AppWriteActor.NormalizedCountdownContent
    ) throws -> String {
        try commandDigest(
            type: "UpdateCountdownCommand",
            operationID: command.operationID,
            eventID: command.eventID,
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            title: normalized.title,
            gentleTitle: normalized.gentleTitle,
            targetDate: command.targetDate,
            showInToday: command.showInToday,
            reminder: normalized.reminder,
            today: nil,
            timestamp: command.timestamp,
            committedAt: command.committedAt
        )
    }

    static func continueCommand(
        _ command: ContinueCountdownCommand
    ) throws -> String {
        try transitionCommandDigest(
            type: "ContinueCountdownCommand",
            operationID: command.operationID,
            eventID: command.eventID,
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            today: command.today,
            timestamp: command.timestamp,
            committedAt: command.committedAt
        )
    }

    static func completeCommand(
        _ command: CompleteCountdownCommand
    ) throws -> String {
        try transitionCommandDigest(
            type: "CompleteCountdownCommand",
            operationID: command.operationID,
            eventID: command.eventID,
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            today: command.today,
            timestamp: command.timestamp,
            committedAt: command.committedAt
        )
    }

    static func archiveCommand(
        _ command: ArchiveCountdownCommand
    ) throws -> String {
        try transitionCommandDigest(
            type: "ArchiveCountdownCommand",
            operationID: command.operationID,
            eventID: command.eventID,
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            today: nil,
            timestamp: command.timestamp,
            committedAt: command.committedAt
        )
    }

    static func reviewResolutionCommand(
        _ command: ResolveCountdownReviewCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "ResolveCountdownReviewCommand",
            recordID: command.operationID,
            fields: [
                .init("committedAt", try timestamp(command.committedAt)),
                .init("countdownID", .uuid(command.countdownID)),
                .init("eventID", .uuid(command.eventID)),
                .init(
                    "expectedEventID",
                    .uuid(command.expectedLatestEventID)
                ),
                .init("resolution", .string(command.resolution.rawValue))
            ] + (try historicalTimestampFields(command.timestamp))
        )
    }

    static func deleteCommand(
        _ command: DeleteCountdownCommand
    ) throws -> String {
        try transitionCommandDigest(
            type: "DeleteCountdownCommand",
            operationID: command.operationID,
            eventID: command.eventID,
            countdownID: command.countdownID,
            expectedEventID: command.expectedLatestEventID,
            today: nil,
            timestamp: command.timestamp,
            committedAt: command.committedAt
        )
    }

    static func replaceCommand(
        _ command: ReplaceCountdownCommand,
        normalized: AppWriteActor.NormalizedCountdownContent
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "ReplaceCountdownCommand",
            recordID: command.operationID,
            fields: [
                .init("committedAt", try timestamp(command.committedAt)),
                .init("countdownID", .uuid(command.countdownID)),
                .init("deleteEventID", .uuid(command.deleteEventID)),
                .init(
                    "expectedEventID",
                    .uuid(command.expectedLatestEventID)
                ),
                .init("gentleTitle", optionalString(normalized.gentleTitle)),
                .init("newCountdownID", .uuid(command.newCountdownID)),
                .init("newEventID", .uuid(command.newEventID)),
                .init(
                    "reminderEnabled",
                    .bool(normalized.reminder.isEnabled)
                ),
                .init(
                    "reminderHour",
                    .integer(Int64(normalized.reminder.localHour))
                ),
                .init(
                    "reminderLeadDays",
                    .integer(Int64(normalized.reminder.leadDays))
                ),
                .init(
                    "reminderMinute",
                    .integer(Int64(normalized.reminder.localMinute))
                ),
                .init("showInToday", .bool(command.showInToday)),
                .init("targetDate", .string(command.targetDate.iso8601)),
                .init("title", .string(normalized.title))
            ] + (try historicalTimestampFields(command.timestamp))
        )
    }

    static func replacementDeletionCommand(
        operationID: UUID,
        primaryCommandDigest: String,
        countdownID: UUID,
        eventID: UUID,
        replacementCountdownID: UUID,
        committedAt: Date
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "ReplaceCountdownDeletionCommand",
            recordID: operationID,
            fields: [
                .init("committedAt", try timestamp(committedAt)),
                .init("countdownID", .uuid(countdownID)),
                .init("eventID", .uuid(eventID)),
                .init(
                    "primaryCommandDigest",
                    .string(primaryCommandDigest)
                ),
                .init(
                    "replacementCountdownID",
                    .uuid(replacementCountdownID)
                )
            ]
        )
    }

    static func state(_ value: CountdownStateRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("archivedAt", try optionalTimestamp(value.archivedAt)),
            .init("completedAt", try optionalTimestamp(value.completedAt)),
            .init("createdAt", try timestamp(value.createdAt)),
            .init("deletedAt", try optionalTimestamp(value.deletedAt)),
            .init("gentleTitle", optionalString(value.gentleTitle)),
            .init("latestEventID", .uuid(value.latestEventID)),
            .init("lifecycle", .string(value.lifecycleRawValue)),
            .init("overdueMode", .string(value.overdueModeRawValue)),
            .init("requiresReview", .bool(value.requiresReview)),
            .init("showInToday", .bool(value.showInToday)),
            .init("target", optionalCivilDate(value.targetDate)),
            .init(
                "terminalReminderWasEnabled",
                optionalBool(value.terminalReminderWasEnabled)
            ),
            .init(
                "terminalReminderLeadDays",
                optionalInteger(value.terminalReminderLeadDays)
            ),
            .init(
                "terminalReminderLocalHour",
                optionalInteger(value.terminalReminderLocalHour)
            ),
            .init(
                "terminalReminderLocalMinute",
                optionalInteger(value.terminalReminderLocalMinute)
            ),
            .init("title", .string(value.title)),
            .init("updatedAt", try timestamp(value.updatedAt))
        ]
    }

    static func event(
        _ value: CountdownLifecycleEventRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("countdownID", .uuid(value.countdownID)),
            .init("kind", .string(value.kindRawValue)),
            .init("newTarget", optionalCivilDate(value.newTargetDate)),
            .init("oldTarget", optionalCivilDate(value.oldTargetDate)),
            .init("operationID", .uuid(value.operationID)),
            .init("previousEventID", optionalUUID(value.previousEventID)),
            .init("replacementCountdownID", optionalUUID(value.replacementCountdownID)),
            .init("occurredAt", try timestamp(value.occurredAt)),
            .init("localDate", .string(try requiredEventTimestamp(value).localDate.iso8601)),
            .init("localHour", .integer(Int64(value.localHour))),
            .init("localMinute", .integer(Int64(value.localMinute))),
            .init("localSecond", .integer(Int64(value.localSecond))),
            .init("localNanosecond", .integer(Int64(value.localNanosecond))),
            .init("timeZoneIdentifier", .string(value.timeZoneIdentifier)),
            .init("utcOffsetSeconds", .integer(Int64(value.utcOffsetSeconds))),
            .init("precision", .string(value.precisionRawValue)),
            .init("provenance", .string(value.provenanceRawValue))
        ]
    }

    static func reminder(
        _ value: CountdownReminderRuleRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("contentVersion", .string(value.contentVersion)),
            .init("countdownID", .uuid(value.countdownID)),
            .init("isEnabled", .bool(value.isEnabled)),
            .init("lastOperationID", .uuid(value.lastOperationID)),
            .init("leadDays", .integer(Int64(value.leadDays))),
            .init("localHour", .integer(Int64(value.localHour))),
            .init("localMinute", .integer(Int64(value.localMinute))),
            .init("ruleKey", .string(value.ruleKey)),
            .init("timeZoneBehavior", .string(value.timeZoneBehaviorRawValue)),
            .init("updatedAt", try timestamp(value.updatedAt))
        ]
    }

    private static func commandDigest(
        type: String,
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedEventID: UUID?,
        title: String,
        gentleTitle: String?,
        targetDate: CivilDateFact,
        showInToday: Bool,
        reminder: CountdownReminderInput,
        today: CivilDateFact?,
        timestamp: HistoricalTimestamp,
        committedAt: Date
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: type,
            recordID: operationID,
            fields: [
                .init("committedAt", try self.timestamp(committedAt)),
                .init("countdownID", .uuid(countdownID)),
                .init("eventID", .uuid(eventID)),
                .init("expectedEventID", optionalUUID(expectedEventID)),
                .init("gentleTitle", optionalString(gentleTitle)),
                .init("reminderEnabled", .bool(reminder.isEnabled)),
                .init("reminderHour", .integer(Int64(reminder.localHour))),
                .init("reminderLeadDays", .integer(Int64(reminder.leadDays))),
                .init("reminderMinute", .integer(Int64(reminder.localMinute))),
                .init("showInToday", .bool(showInToday)),
                .init("targetDate", .string(targetDate.iso8601)),
                .init("title", .string(title)),
                .init("today", optionalCivilDate(today))
            ] + (try historicalTimestampFields(timestamp))
        )
    }

    private static func transitionCommandDigest(
        type: String,
        operationID: UUID,
        eventID: UUID,
        countdownID: UUID,
        expectedEventID: UUID,
        today: CivilDateFact?,
        timestamp: HistoricalTimestamp,
        committedAt: Date
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: type,
            recordID: operationID,
            fields: [
                .init("committedAt", try self.timestamp(committedAt)),
                .init("countdownID", .uuid(countdownID)),
                .init("eventID", .uuid(eventID)),
                .init("expectedEventID", .uuid(expectedEventID)),
                .init("today", optionalCivilDate(today))
            ] + (try historicalTimestampFields(timestamp))
        )
    }

    private static func historicalTimestampFields(
        _ value: HistoricalTimestamp
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("eventInstant", try RecordDigestV1.timestampValue(value.instant)),
            .init("eventLocalDate", .string(value.localDate.iso8601)),
            .init("eventLocalHour", .integer(Int64(value.localTime.hour))),
            .init("eventLocalMinute", .integer(Int64(value.localTime.minute))),
            .init("eventLocalSecond", .integer(Int64(value.localTime.second))),
            .init("eventLocalNanosecond", .integer(Int64(value.localTime.nanosecond))),
            .init("eventTimeZoneIdentifier", .string(value.timeZoneIdentifier)),
            .init("eventUTCOffsetSeconds", .integer(Int64(value.utcOffsetSeconds))),
            .init("eventPrecision", .string(value.precision.rawValue)),
            .init("eventProvenance", .string(value.provenance.rawValue))
        ]
    }

    private static func requiredEventTimestamp(
        _ value: CountdownLifecycleEventRecord
    ) throws -> HistoricalTimestamp {
        guard let timestamp = value.historicalTimestamp else {
            throw CountdownWriteFailure.invalidInput
        }
        return timestamp
    }

    private static func timestamp(_ value: Date) throws -> RecordDigestV1.Value {
        try RecordDigestV1.timestampValue(value)
    }

    private static func optionalTimestamp(
        _ value: Date?
    ) throws -> RecordDigestV1.Value {
        guard let value else { return .null }
        return try timestamp(value)
    }

    private static func optionalString(_ value: String?) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.string) ?? .null
    }

    private static func optionalBool(_ value: Bool?) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.bool) ?? .null
    }

    private static func optionalInteger(_ value: Int?) -> RecordDigestV1.Value {
        value.map { .integer(Int64($0)) } ?? .null
    }

    private static func optionalUUID(_ value: UUID?) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.uuid) ?? .null
    }

    private static func optionalCivilDate(
        _ value: CivilDateFact?
    ) -> RecordDigestV1.Value {
        value.map { .string($0.iso8601) } ?? .null
    }
}
