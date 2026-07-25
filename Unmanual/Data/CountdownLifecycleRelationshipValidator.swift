import Foundation
import SwiftData

enum CountdownLifecycleRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
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
              coverage[0].status != nil,
              coverage[0].desiredCount >= 0,
              coverage[0].confirmedPendingCount >= 0,
              coverage[0].confirmedPendingCount <= coverage[0].desiredCount,
              coverage[0].observedAt.timeIntervalSince1970.isFinite,
              coverage[0].scheduledFireAt?.timeIntervalSince1970.isFinite
                != false else {
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
        guard states.allSatisfy({
            validatesLatestEvent(
                for: $0,
                event: eventByID[$0.latestEventID]
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
                  reminder.ruleKey == CountdownReminderRuleRecord.key(
                      countdownID: reminder.countdownID
                  )
                      && stateByID[reminder.countdownID] != nil
                      && (0...365).contains(reminder.leadDays)
                      && (0...23).contains(reminder.localHour)
                      && (0...59).contains(reminder.localMinute)
                      && reminder.timeZoneBehavior == .floatingLocalV1
                      && reminder.contentVersion == "neutralV1"
                      && reminder.updatedAt.timeIntervalSince1970.isFinite
                      && (
                          stateByID[reminder.countdownID]?.lifecycle == .active
                              || !reminder.isEnabled
                      )
              }) else {
            throw failure
        }

        let legacy = try context.fetch(FetchDescriptor<CountdownRecord>())
        let legacyByID = try AppDataIndex.checkedUniqueMap(
            legacy,
            keyedBy: \.id,
            failure: failure
        )
        guard legacy.allSatisfy({ stateByID[$0.id]?.lifecycle != .deleted }),
              states.allSatisfy({ state in
                  if state.lifecycle == .deleted {
                      return legacyByID[state.id] == nil
                  }
                  return legacyByID[state.id] != nil
              }) else {
            throw failure
        }

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
              events.allSatisfy({ event in
                  guard let receipt = receiptByOperationID[event.operationID] else {
                      return false
                  }
                  return receipt.resultRecordType
                      == "CountdownLifecycleEventRecord"
                      && receipt.resultRecordID == event.id
              }),
              countdownReceipts.allSatisfy({ receipt in
                  receipt.commandDigest.count == 64
                      && receipt.commandDigest.allSatisfy(\.isHexDigit)
                      && receipt.committedAt.timeIntervalSince1970.isFinite
                      && eventByOperationID[receipt.operationID]?.id
                        == receipt.resultRecordID
              }) else {
            throw failure
        }
    }

    private static func validatesState(_ state: CountdownStateRecord) -> Bool {
        guard let lifecycle = state.lifecycle,
              state.overdueMode != nil,
              state.createdAt.timeIntervalSince1970.isFinite,
              state.updatedAt.timeIntervalSince1970.isFinite,
              state.createdAt <= state.updatedAt else {
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
                && !state.showInToday
                && hasValidTerminalReminderSnapshot(state)
        case .archived:
            return state.targetDate != nil
                && !state.title.isEmpty
                && state.completedAt == nil
                && state.archivedAt?.timeIntervalSince1970.isFinite == true
                && state.deletedAt == nil
                && !state.showInToday
                && hasValidTerminalReminderSnapshot(state)
        case .deleted:
            return state.targetDate == nil
                && state.title.isEmpty
                && state.gentleTitle == nil
                && state.completedAt == nil
                && state.deletedAt?.timeIntervalSince1970.isFinite == true
                && !state.showInToday
                && !state.requiresReview
                && hasNoTerminalReminderSnapshot(state)
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
            while let eventID = cursor {
                guard visited.insert(eventID).inserted,
                      let event = eventByID[eventID],
                      event.countdownID == state.id else {
                    throw failure
                }
                cursor = event.previousEventID
            }
            guard visited.count == chain.count else { throw failure }
        }
    }

    private static func validatesLatestEvent(
        for state: CountdownStateRecord,
        event: CountdownLifecycleEventRecord?
    ) -> Bool {
        guard let lifecycle = state.lifecycle,
              let kind = event?.kind else {
            return false
        }
        switch lifecycle {
        case .active:
            return [
                .migratedSnapshot,
                .created,
                .edited,
                .visibilityChanged,
                .reminderChanged,
                .reviewResolved,
                .continuedCountingUp
            ].contains(kind)
        case .completed:
            return kind == .completed
        case .archived:
            return kind == .archived
                || kind == .migratedSnapshot
                || kind == .reviewResolved
        case .deleted:
            return kind == .deleted || kind == .replaced
        }
    }
}
