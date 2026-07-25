import Foundation
import SwiftData

enum CountdownLifecycleRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure,
        includesIntegrityFacts: Bool = true
    ) throws {
        let backfills = try context.fetch(
            FetchDescriptor<CountdownLifecycleBackfillState>()
        )
        guard backfills.count == 1,
              backfills[0].taskKey == CountdownLifecycleBackfillState.fixedKey,
              backfills[0].completedAt?.timeIntervalSince1970.isFinite == true,
              backfills[0].updatedAt.timeIntervalSince1970.isFinite,
              TimeZone(identifier: backfills[0].assumedTimeZoneIdentifier) != nil else {
            throw failure
        }

        let coverage = try context.fetch(
            FetchDescriptor<CountdownNotificationCoverageRecord>()
        )
        guard coverage.count == 1,
              coverage[0].coverageKey
                == CountdownNotificationCoverageRecord.fixedKey,
              let coverageStatus = coverage[0].status,
              coverage[0].observedAt.timeIntervalSince1970.isFinite,
              CountdownNotificationCoverageRecord.isConsistent(
                  status: coverageStatus,
                  scheduledFireAt: coverage[0].scheduledFireAt,
                  desiredCount: coverage[0].desiredCount,
                  confirmedPendingCount: coverage[0].confirmedPendingCount,
                  lastErrorCode: coverage[0].lastErrorCode
              ) else {
            throw failure
        }

        let states = try context.fetch(FetchDescriptor<CountdownStateRecord>())
        let stateByID = try AppDataIndex.checkedUniqueMap(
            states,
            keyedBy: \.id,
            failure: failure
        )
        let activeStates = states.filter { $0.lifecycle == .active }
        let coverageCountdownIDIsValid = coverage[0].countdownID.map {
            stateByID[$0] != nil
        } ?? true
        guard activeStates.filter({ !$0.requiresReview }).count <= 1,
              states.filter(\.showInToday).count <= 1,
              states.allSatisfy(validatesState),
              coverageCountdownIDIsValid else {
            throw failure
        }

        let events = try context.fetch(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        let eventByID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: failure
        )
        let eventByOperationID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.operationID,
            failure: failure
        )
        guard eventByID.count == events.count,
              eventByOperationID.count == events.count,
              events.allSatisfy({ event in
                  stateByID[event.countdownID] != nil
                      && event.kind != nil
                      && validatesEventPayload(event)
                      && event.historicalTimestamp != nil
                      && event.occurredAt.timeIntervalSince1970.isFinite
                      && event.previousEventID != event.id
                      && event.previousEventID.map {
                          eventByID[$0]?.countdownID == event.countdownID
                      } ?? true
              }) else {
            throw failure
        }
        try validateEventChains(
            states: states,
            events: events,
            eventByID: eventByID,
            failure: failure
        )
        try validateReplacementLinks(
            statesByID: stateByID,
            events: events,
            failure: failure
        )
        guard states.allSatisfy({
            validatesLatestEvent(
                for: $0,
                event: eventByID[$0.latestEventID],
                eventByID: eventByID
            )
        }) else {
            throw failure
        }

        let reminders = try context.fetch(
            FetchDescriptor<CountdownReminderRuleRecord>()
        )
        let reminderByID = try AppDataIndex.checkedUniqueMap(
            reminders,
            keyedBy: \.id,
            failure: failure
        )
        let reminderByCountdownID = try AppDataIndex.checkedUniqueMap(
            reminders,
            keyedBy: \.countdownID,
            failure: failure
        )
        guard reminderByID.count == reminders.count,
              reminderByCountdownID.count == states.count,
              Set(reminderByCountdownID.keys) == Set(stateByID.keys),
              reminders.allSatisfy({ reminder in
                  guard let state = stateByID[reminder.countdownID],
                        let latestEvent = eventByID[
                            state.latestEventID
                        ] else {
                      return false
                  }
                  return reminder.ruleKey == CountdownReminderRuleRecord.key(
                      countdownID: reminder.countdownID
                  )
                      && (0...365).contains(reminder.leadDays)
                      && (0...23).contains(reminder.localHour)
                      && (0...59).contains(reminder.localMinute)
                      && reminder.timeZoneBehavior == .floatingLocalV1
                      && reminder.contentVersion == "neutralV1"
                      && reminder.updatedAt.timeIntervalSince1970.isFinite
                      && (
                          state.lifecycle == .active
                              || !reminder.isEnabled
                      )
                      && (
                          state.lifecycle != .deleted
                              || (
                                  !reminder.isEnabled
                                      && reminder.leadDays == 0
                                      && reminder.localHour == 9
                                      && reminder.localMinute == 0
                                      && reminder.timeZoneBehavior
                                        == .floatingLocalV1
                                      && reminder.contentVersion
                                        == "neutralV1"
                              )
                      )
                      && latestEvent.operationID
                        == reminder.lastOperationID
                      && state.updatedAt == reminder.updatedAt
              }) else {
            throw failure
        }

        let legacy = try context.fetch(FetchDescriptor<CountdownRecord>())
        let legacyByID = try AppDataIndex.checkedUniqueMap(
            legacy,
            keyedBy: \.id,
            failure: failure
        )
        guard legacy.allSatisfy({ value in
                  guard let state = stateByID[value.id],
                        state.lifecycle != .deleted else {
                      return false
                  }
                  return value.title == state.title
                      && value.gentleTitle == state.gentleTitle
                      && value.createdAt == state.createdAt
                      && value.continuesCountingUp
                        == (state.overdueMode == .countingUp)
                      && value.archivedAt == state.archivedAt
              }),
              states.allSatisfy({ state in
                  if state.lifecycle == .deleted {
                      return legacyByID[state.id] == nil
                  }
                  return legacyByID[state.id] != nil
              }) else {
            throw failure
        }
        try validateLegacyAnchors(
            statesByID: stateByID,
            legacy: legacy,
            eventByID: eventByID,
            failure: failure
        )

        let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
        let receiptByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )
        let countdownReceipts = receipts.filter {
            $0.resultRecordType == "CountdownLifecycleEventRecord"
        }
        guard countdownReceipts.count == events.count,
              countdownReceipts.allSatisfy({ receipt in
                  receipt.commandDigest.count == 64
                      && receipt.commandDigest.allSatisfy(\.isHexDigit)
                      && receipt.committedAt.timeIntervalSince1970.isFinite
                      && eventByOperationID[receipt.operationID]?.id
                        == receipt.resultRecordID
              }) else {
            throw failure
        }
        for event in events {
            guard let receipt = receiptByOperationID[event.operationID],
                  receipt.resultRecordType
                    == "CountdownLifecycleEventRecord",
                  receipt.resultRecordID == event.id else {
                throw failure
            }
        }
        if includesIntegrityFacts {
            try CountdownIntegrityValidator.validate(
                in: context,
                states: states,
                events: events,
                remindersByCountdownID: reminderByCountdownID,
                legacyByID: legacyByID,
                receiptsByOperationID: receiptByOperationID,
                failure: failure
            )
        } else {
            for event in events where event.kind == .migratedSnapshot {
                guard let state = stateByID[event.countdownID] else {
                    throw failure
                }
                guard state.latestEventID == event.id else { continue }
                guard let legacy = legacyByID[event.countdownID],
                      let reminder = reminderByCountdownID[event.countdownID],
                      receiptByOperationID[event.operationID]?
                        .commandDigest == (
                          try CountdownLifecycleBackfill
                            .migrationCommandDigest(
                                source: legacy,
                                state: state,
                                event: event,
                                reminder: reminder
                            )
                      ) else {
                    throw failure
                }
            }
        }
    }

    private static func validateLegacyAnchors(
        statesByID: [UUID: CountdownStateRecord],
        legacy: [CountdownRecord],
        eventByID: [UUID: CountdownLifecycleEventRecord],
        failure: AppDataFailure
    ) throws {
        for legacyRecord in legacy {
            guard let state = statesByID[legacyRecord.id],
                  let canonicalTarget = state.targetDate else {
                throw failure
            }
            var cursor: UUID? = state.latestEventID
            var targetAnchor: CountdownLifecycleEventRecord?
            var root: CountdownLifecycleEventRecord?
            while let eventID = cursor {
                guard let event = eventByID[eventID],
                      event.countdownID == state.id else {
                    throw failure
                }
                if targetAnchor == nil,
                   event.previousEventID == nil
                    || event.oldTargetDate != event.newTargetDate {
                    targetAnchor = event
                }
                if event.previousEventID == nil {
                    root = event
                    break
                }
                cursor = event.previousEventID
            }
            guard let targetAnchor,
                  targetAnchor.newTargetDate == canonicalTarget,
                  let timeZone = TimeZone(
                      identifier: targetAnchor.timeZoneIdentifier
                  ) else {
                throw failure
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: legacyRecord.targetDate
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day,
                  let legacyTarget = try? CivilDateFact(
                      year: year,
                      month: month,
                      day: day
                  ),
                  legacyTarget == canonicalTarget else {
                throw failure
            }
            if root?.kind == .created {
                guard state.createdAt == root?.occurredAt,
                      legacyRecord.createdAt == root?.occurredAt else {
                    throw failure
                }
            }
        }
    }

    private static func validatesState(_ state: CountdownStateRecord) -> Bool {
        guard let lifecycle = state.lifecycle,
              state.overdueMode != nil,
              state.createdAt.timeIntervalSince1970.isFinite,
              state.updatedAt.timeIntervalSince1970.isFinite else {
            return false
        }
        switch lifecycle {
        case .active:
            return state.targetDate != nil
                && !state.title.isEmpty
                && state.completedAt == nil
                && state.archivedAt == nil
                && state.deletedAt == nil
                && hasNoTerminalReminderSnapshot(state)
                && (!state.requiresReview || !state.showInToday)
        case .completed:
            return state.targetDate != nil
                && !state.title.isEmpty
                && state.completedAt?.timeIntervalSince1970.isFinite == true
                && state.archivedAt?.timeIntervalSince1970.isFinite == true
                && state.deletedAt == nil
                && state.overdueMode == .awaitingDecision
                && !state.showInToday
                && !state.requiresReview
                && hasValidTerminalReminderSnapshot(state)
        case .archived:
            return state.targetDate != nil
                && !state.title.isEmpty
                && state.completedAt == nil
                && state.archivedAt?.timeIntervalSince1970.isFinite == true
                && state.deletedAt == nil
                && !state.showInToday
                && (
                    state.requiresReview
                        || state.overdueMode == .awaitingDecision
                )
                && hasValidTerminalReminderSnapshot(state)
        case .deleted:
            return state.targetDate == nil
                && state.title.isEmpty
                && state.gentleTitle == nil
                && state.completedAt == nil
                && state.archivedAt == nil
                && state.deletedAt?.timeIntervalSince1970.isFinite == true
                && state.overdueMode == .awaitingDecision
                && !state.showInToday
                && !state.requiresReview
                && hasNoTerminalReminderSnapshot(state)
        }
    }

    private static func validatesEventPayload(
        _ event: CountdownLifecycleEventRecord
    ) -> Bool {
        guard let kind = event.kind else { return false }
        switch kind {
        case .created:
            return event.previousEventID == nil
                && event.oldTargetDate == nil
                && event.newTargetDate != nil
                && event.replacementCountdownID == nil
        case .migratedSnapshot:
            return event.previousEventID == nil
                && event.oldTargetDate == nil
                && event.newTargetDate != nil
                && event.replacementCountdownID == nil
        case .edited:
            return event.previousEventID != nil
                && event.oldTargetDate != nil
                && event.newTargetDate != nil
                && event.replacementCountdownID == nil
        case .visibilityChanged,
             .reminderChanged,
             .continuedCountingUp:
            return event.previousEventID != nil
                && event.oldTargetDate != nil
                && event.newTargetDate == event.oldTargetDate
                && event.replacementCountdownID == nil
        case .reviewResolved:
            return event.previousEventID != nil
                && event.oldTargetDate != nil
                && event.newTargetDate == event.oldTargetDate
                && event.replacementCountdownID == nil
        case .completed, .archived:
            return event.previousEventID != nil
                && event.oldTargetDate != nil
                && event.newTargetDate == event.oldTargetDate
                && event.replacementCountdownID == nil
        case .deleted:
            return event.previousEventID != nil
                && event.oldTargetDate != nil
                && event.newTargetDate == nil
                && event.replacementCountdownID == nil
        case .replaced:
            return event.previousEventID != nil
                && event.oldTargetDate != nil
                && event.newTargetDate == nil
                && event.replacementCountdownID != nil
        }
    }

    private static func hasNoTerminalReminderSnapshot(
        _ state: CountdownStateRecord
    ) -> Bool {
        state.terminalReminderWasEnabled == nil
            && state.terminalReminderLeadDays == nil
            && state.terminalReminderLocalHour == nil
            && state.terminalReminderLocalMinute == nil
    }

    private static func hasValidTerminalReminderSnapshot(
        _ state: CountdownStateRecord
    ) -> Bool {
        state.terminalReminderWasEnabled != nil
            && state.terminalReminderLeadDays.map {
                (0...365).contains($0)
            } == true
            && state.terminalReminderLocalHour.map {
                (0...23).contains($0)
            } == true
            && state.terminalReminderLocalMinute.map {
                (0...59).contains($0)
            } == true
    }

    private static func validateEventChains(
        states: [CountdownStateRecord],
        events: [CountdownLifecycleEventRecord],
        eventByID: [UUID: CountdownLifecycleEventRecord],
        failure: AppDataFailure
    ) throws {
        let eventsByCountdown = Dictionary(grouping: events, by: \.countdownID)
        for state in states {
            guard let chain = eventsByCountdown[state.id],
                  !chain.isEmpty,
                  eventByID[state.latestEventID]?.countdownID == state.id else {
                throw failure
            }
            let referenced = Set(chain.compactMap(\.previousEventID))
            let leaves = chain.filter { !referenced.contains($0.id) }
            guard leaves.count == 1,
                  leaves[0].id == state.latestEventID,
                  chain.filter({ $0.previousEventID == nil }).count == 1 else {
                throw failure
            }
            var visited: Set<UUID> = []
            var cursor: UUID? = state.latestEventID
            var reverseOrderedChain: [CountdownLifecycleEventRecord] = []
            while let eventID = cursor {
                guard visited.insert(eventID).inserted,
                      let event = eventByID[eventID],
                      event.countdownID == state.id else {
                    throw failure
                }
                reverseOrderedChain.append(event)
                cursor = event.previousEventID
            }
            guard visited.count == chain.count else { throw failure }
            let terminalKinds: Set<CountdownLifecycleEventKind> = [
                .completed,
                .archived,
                .deleted,
                .replaced
            ]
            guard chain.allSatisfy({
                guard let kind = $0.kind,
                      terminalKinds.contains(kind) else {
                    return true
                }
                return $0.id == state.latestEventID
            }) else {
                throw failure
            }

            var replayTarget: CivilDateFact?
            var replayModeIsKnown = false
            var didContinueForCurrentTarget = false
            for event in reverseOrderedChain.reversed() {
                if let previousEventID = event.previousEventID {
                    guard let previous = eventByID[previousEventID],
                          event.oldTargetDate == previous.newTargetDate,
                          event.oldTargetDate == replayTarget else {
                        throw failure
                    }
                } else {
                    guard event.oldTargetDate == nil,
                          event.kind == .created
                            || event.kind == .migratedSnapshot else {
                        throw failure
                    }
                }

                switch event.kind {
                case .created:
                    replayTarget = event.newTargetDate
                    replayModeIsKnown = true
                    didContinueForCurrentTarget = false
                case .migratedSnapshot:
                    replayTarget = event.newTargetDate
                    replayModeIsKnown = false
                    didContinueForCurrentTarget = false
                case .edited:
                    if event.newTargetDate != replayTarget {
                        replayModeIsKnown = true
                        didContinueForCurrentTarget = false
                    }
                    replayTarget = event.newTargetDate
                case .continuedCountingUp:
                    guard let target = event.newTargetDate,
                          let timestamp = event.historicalTimestamp,
                          !didContinueForCurrentTarget,
                          timestamp.localDate >= target else {
                        throw failure
                    }
                    replayModeIsKnown = true
                    didContinueForCurrentTarget = true
                case .completed:
                    guard let target = event.newTargetDate,
                          let timestamp = event.historicalTimestamp,
                          timestamp.localDate >= target else {
                        throw failure
                    }
                    replayModeIsKnown = true
                    didContinueForCurrentTarget = false
                case .archived:
                    replayTarget = event.newTargetDate
                    replayModeIsKnown = true
                    didContinueForCurrentTarget = false
                case .deleted, .replaced:
                    replayTarget = nil
                case .visibilityChanged,
                     .reminderChanged,
                     .reviewResolved:
                    replayTarget = event.newTargetDate
                case nil:
                    throw failure
                }
            }
            if replayModeIsKnown,
               state.lifecycle != .deleted {
                let expectedMode: CountdownOverdueMode =
                    didContinueForCurrentTarget
                        ? .countingUp
                        : .awaitingDecision
                guard state.overdueMode == expectedMode else {
                    throw failure
                }
            }
        }
    }

    private static func validateReplacementLinks(
        statesByID: [UUID: CountdownStateRecord],
        events: [CountdownLifecycleEventRecord],
        failure: AppDataFailure
    ) throws {
        let eventsByCountdown = Dictionary(grouping: events, by: \.countdownID)
        let replacementEvents = events.filter { $0.kind == .replaced }
        let replacementTargets = replacementEvents.compactMap(
            \.replacementCountdownID
        )
        guard Set(replacementTargets).count == replacementTargets.count else {
            throw failure
        }
        for event in replacementEvents {
            guard let replacementCountdownID =
                    event.replacementCountdownID,
                  replacementCountdownID != event.countdownID,
                  let oldState = statesByID[event.countdownID],
                  oldState.lifecycle == .deleted,
                  oldState.latestEventID == event.id,
                  let replacementState =
                    statesByID[replacementCountdownID],
                  let replacementRoot =
                    eventsByCountdown[replacementCountdownID]?.first(
                        where: { $0.previousEventID == nil }
                    ),
                  replacementRoot.kind == .created,
                  replacementRoot.replacementCountdownID == nil,
                  replacementRoot.occurredAt == event.occurredAt,
                  replacementRoot.historicalTimestamp
                    == event.historicalTimestamp,
                  replacementState.createdAt
                    == replacementRoot.occurredAt,
                  event.operationID == CoreTimeRegimenBackfill.stableUUID(
                      for: "countdown-replace-delete-operation:"
                          + replacementRoot.operationID.uuidString
                            .lowercased()
                  ) else {
                throw failure
            }
        }
    }

    private static func validatesLatestEvent(
        for state: CountdownStateRecord,
        event: CountdownLifecycleEventRecord?,
        eventByID: [UUID: CountdownLifecycleEventRecord]
    ) -> Bool {
        guard let lifecycle = state.lifecycle,
              let event,
              let kind = event.kind,
              event.occurredAt == state.updatedAt,
              event.newTargetDate == state.targetDate else {
            return false
        }
        switch lifecycle {
        case .active:
            let kindIsValid = [
                .migratedSnapshot,
                .created,
                .edited,
                .visibilityChanged,
                .reminderChanged,
                .reviewResolved,
                .continuedCountingUp
            ].contains(kind)
            return kindIsValid
                && (!state.requiresReview || kind == .migratedSnapshot)
                && hasNoTerminalReminderSnapshot(state)
        case .completed:
            return kind == .completed
                && state.completedAt == event.occurredAt
                && state.archivedAt == event.occurredAt
                && hasValidTerminalReminderSnapshot(state)
        case .archived:
            let kindIsValid = state.requiresReview
                ? kind == .migratedSnapshot
                : kind == .archived
                    || kind == .migratedSnapshot
                    || kind == .reviewResolved
            guard kindIsValid else { return false }
            let archivalEvent: CountdownLifecycleEventRecord?
            if kind == .reviewResolved,
               let previousEventID = event.previousEventID {
                archivalEvent = eventByID[previousEventID]
            } else {
                archivalEvent = event
            }
            guard let archivalEvent,
                  archivalEvent.kind == .archived
                    || archivalEvent.kind == .migratedSnapshot else {
                return false
            }
            return state.archivedAt == archivalEvent.occurredAt
                && hasValidTerminalReminderSnapshot(state)
        case .deleted:
            return (kind == .deleted || kind == .replaced)
                && state.deletedAt == event.occurredAt
        }
    }
}
