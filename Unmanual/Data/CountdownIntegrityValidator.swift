import Foundation
import SwiftData

enum CountdownIntegrityValidator {
    static func validate(
        in context: ModelContext,
        states: [CountdownStateRecord],
        events: [CountdownLifecycleEventRecord],
        remindersByCountdownID: [UUID: CountdownReminderRuleRecord],
        legacyByID: [UUID: CountdownRecord],
        receiptsByOperationID: [UUID: OperationReceiptRecord],
        failure: AppDataFailure
    ) throws {
        let markers = try context.fetch(
            FetchDescriptor<CountdownIntegrityBackfillState>()
        )
        guard markers.count == 1, let marker = markers.first,
              validatesMarker(marker) else {
            throw failure
        }
        let audits = try context.fetch(
            FetchDescriptor<CountdownCommandAuditRecord>()
        )
        let checkpoints = try context.fetch(
            FetchDescriptor<CountdownV6AuditCheckpointRecord>()
        )
        let auditByEventID = try AppDataIndex.checkedUniqueMap(
            audits,
            keyedBy: \.eventID,
            failure: failure
        )
        let auditByOperationID = try AppDataIndex.checkedUniqueMap(
            audits,
            keyedBy: \.operationID,
            failure: failure
        )
        let checkpointByCountdownID = try AppDataIndex.checkedUniqueMap(
            checkpoints,
            keyedBy: \.countdownID,
            failure: failure
        )
        let eventByID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: failure
        )
        guard auditByEventID.count == audits.count,
              auditByOperationID.count == audits.count,
              checkpointByCountdownID.count == checkpoints.count,
              audits.allSatisfy({
                  validatesAuditShape($0)
                      && eventByID[$0.eventID]?.operationID == $0.operationID
                      && eventByID[$0.eventID]?.countdownID == $0.countdownID
              }),
              checkpoints.allSatisfy({
                  validatesCheckpointShape($0)
                      && eventByID[$0.boundaryEventID]?.countdownID
                        == $0.countdownID
              }) else {
            throw failure
        }

        for audit in audits {
            guard let event = eventByID[audit.eventID],
                  let timestamp = event.historicalTimestamp,
                  let receipt = receiptsByOperationID[audit.operationID],
                  receipt.resultRecordID == event.id,
                  receipt.commandDigest == audit.commandDigest,
                  audit.commandDigest
                    == (try CountdownIntegrityDigest.command(audit)),
                  audit.eventTimestampCommitment
                    == (try CountdownIntegrityDigest.timestampCommitment(
                        timestamp,
                        operationID: audit.operationID
                    )),
                  audit.eventSemanticDigest
                    == (try CountdownIntegrityDigest.eventSemantic(event)),
                  audit.auditDigest
                    == (try CountdownIntegrityDigest.audit(audit)),
                  commandKindMatchesEvent(audit, event: event),
                  expectedPredecessorMatches(audit, event: event),
                  commandDateMatchesEvent(audit, event: event),
                  replacementAuditMatches(
                    audit,
                    auditByEventID: auditByEventID
                  ) else {
                throw failure
            }
        }

        let eventsByCountdownID = Dictionary(
            grouping: events,
            by: \.countdownID
        )
        for state in states {
            guard let reminder = remindersByCountdownID[state.id],
                  let unorderedEvents = eventsByCountdownID[state.id] else {
                throw failure
            }
            let chain = try orderedChain(
                latestEventID: state.latestEventID,
                events: unorderedEvents,
                eventByID: eventByID,
                failure: failure
            )
            let checkpoint = checkpointByCountdownID[state.id]
            var auditedStartIndex = 0
            var predecessorPost =
                try CountdownIntegrityDigest.absentFactsDigest()
            var predecessorAuditDigest: String?
            if let checkpoint {
                guard let boundaryIndex = chain.firstIndex(
                    where: { $0.id == checkpoint.boundaryEventID }
                ) else {
                    throw failure
                }
                let prefix = Array(chain[...boundaryIndex])
                guard checkpoint.prefixEventCount == prefix.count,
                      checkpoint.prefixChainDigest
                        == (try CountdownIntegrityDigest.prefixChain(
                            events: prefix,
                            receiptsByOperationID: receiptsByOperationID
                        )),
                      checkpoint.checkpointDigest
                        == (try CountdownIntegrityDigest.checkpoint(checkpoint)),
                      prefix.allSatisfy({
                          auditByEventID[$0.id] == nil
                      }) else {
                    throw failure
                }
                auditedStartIndex = boundaryIndex + 1
                predecessorPost = checkpoint.postFactsDigest
            }
            for event in chain.dropFirst(auditedStartIndex) {
                guard let audit = auditByEventID[event.id],
                      audit.preFactsDigest == predecessorPost,
                      audit.previousAuditDigest == predecessorAuditDigest else {
                    throw failure
                }
                predecessorPost = audit.postFactsDigest
                predecessorAuditDigest = audit.auditDigest
            }
            let orderedAudits = chain.compactMap {
                auditByEventID[$0.id]
            }
            guard chain.prefix(auditedStartIndex).allSatisfy({
                      auditByEventID[$0.id] == nil
                  }),
                  chain.dropFirst(auditedStartIndex).allSatisfy({
                      auditByEventID[$0.id] != nil
                  }),
                  predecessorPost
                    == (try CountdownIntegrityDigest.facts(
                        state: state,
                        reminder: reminder,
                        legacy: legacyByID[state.id]
                    )),
                  try currentProjectionMatches(
                    state: state,
                    reminder: reminder,
                    orderedAudits: orderedAudits
                  ) else {
                throw failure
            }
            try validateTerminalSnapshot(
                state: state,
                latestAudit: auditByEventID[state.latestEventID],
                checkpoint: checkpoint,
                failure: failure
            )
        }

        let chainEventIDs = Set(events.map(\.id))
        guard Set(audits.map(\.eventID)).isSubset(of: chainEventIDs),
              Set(checkpoints.map(\.countdownID))
                .isSubset(of: Set(states.map(\.id))),
              validatesInitialSet(
                marker: marker,
                audits: audits,
                checkpoints: checkpoints
              ) else {
            throw failure
        }
    }

    static func reminderIsAdmitted(
        in context: ModelContext,
        countdownID: UUID
    ) throws -> Bool {
        var checkpointDescriptor =
            FetchDescriptor<CountdownV6AuditCheckpointRecord>(
                predicate: #Predicate {
                    $0.countdownID == countdownID
                }
            )
        checkpointDescriptor.fetchLimit = 2
        let checkpoints = try context.fetch(checkpointDescriptor)
        guard checkpoints.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard let checkpoint = checkpoints.first,
              checkpoint.reminderAdmission == .needsUserConfirmation else {
            return true
        }
        let auditDescriptor = FetchDescriptor<CountdownCommandAuditRecord>(
            predicate: #Predicate { $0.countdownID == countdownID }
        )
        let audits = try context.fetch(auditDescriptor)
        return audits.contains {
            $0.commandKind == .update
                || $0.commandKind == .replace
        }
    }

    private static func validatesMarker(
        _ value: CountdownIntegrityBackfillState
    ) -> Bool {
        value.taskKey == CountdownIntegrityBackfillState.fixedKey
            && ["6.0.0", "7.0.0"].contains(value.sourceSchemaVersion)
            && value.initialAuditCount >= 0
            && value.initialCheckpointCount >= 0
            && isDigest(value.initialIntegritySetDigest)
            && value.completedAt?.timeIntervalSince1970.isFinite == true
            && value.updatedAt.timeIntervalSince1970.isFinite
    }

    private static func validatesAuditShape(
        _ value: CountdownCommandAuditRecord
    ) -> Bool {
        guard value.commandKind != nil,
              value.source == .nativeV7,
              value.commandDigestVersion
                == CountdownIntegrityDigest.commandVersion,
              isDigest(value.commandDigest),
              isDigest(value.eventTimestampCommitment),
              isDigest(value.eventSemanticDigest),
              isDigest(value.preFactsDigest),
              isDigest(value.postFactsDigest),
              value.previousAuditDigest.map(isDigest) ?? true,
              isDigest(value.auditDigest),
              value.committedAt.timeIntervalSince1970.isFinite else {
            return false
        }
        let hasContent = value.titleCommitment.map(isDigest) == true
            && value.gentleTitleCommitment.map(isDigest) == true
            && value.targetDate != nil
            && value.showInToday != nil
            && value.reminderIsEnabled != nil
            && value.reminderLeadDays.map { (0...365).contains($0) }
                == true
            && value.reminderLocalHour.map { (0...23).contains($0) }
                == true
            && value.reminderLocalMinute.map { (0...59).contains($0) }
                == true
        let noContent = value.titleCommitment == nil
            && value.gentleTitleCommitment == nil
            && value.targetYear == nil
            && value.targetMonth == nil
            && value.targetDay == nil
            && value.showInToday == nil
            && value.reminderIsEnabled == nil
            && value.reminderLeadDays == nil
            && value.reminderLocalHour == nil
            && value.reminderLocalMinute == nil
        let noToday = value.todayYear == nil
            && value.todayMonth == nil
            && value.todayDay == nil
        let hasTerminalReminder =
            value.terminalReminderWasEnabled != nil
                && value.terminalReminderLeadDays.map {
                    (0...365).contains($0)
                } == true
                && value.terminalReminderLocalHour.map {
                    (0...23).contains($0)
                } == true
                && value.terminalReminderLocalMinute.map {
                    (0...59).contains($0)
                } == true
        let hasNoTerminalReminder =
            value.terminalReminderWasEnabled == nil
                && value.terminalReminderLeadDays == nil
                && value.terminalReminderLocalHour == nil
                && value.terminalReminderLocalMinute == nil
        switch value.commandKind {
        case .migratedSnapshot:
            return value.expectedLatestEventID == nil
                && hasContent
                && noToday
                && value.reviewResolutionRawValue == nil
                && value.replacementCountdownID == nil
                && value.replacementEventID == nil
                && value.primaryCommandDigest == nil
                && (hasNoTerminalReminder || hasTerminalReminder)
        case .create:
            return value.expectedLatestEventID == nil
                && hasContent
                && noToday
                && value.reviewResolutionRawValue == nil
                && value.replacementCountdownID == nil
                && value.replacementEventID == nil
                && value.primaryCommandDigest == nil
                && hasNoTerminalReminder
        case .update:
            return value.expectedLatestEventID != nil
                && hasContent
                && noToday
                && value.reviewResolutionRawValue == nil
                && value.replacementCountdownID == nil
                && value.replacementEventID == nil
                && value.primaryCommandDigest == nil
                && hasNoTerminalReminder
        case .review:
            let resolution = CountdownReviewResolution(
                rawValue: value.reviewResolutionRawValue ?? ""
            )
            return value.expectedLatestEventID != nil
                && noContent
                && noToday
                && resolution != nil
                && value.replacementCountdownID == nil
                && value.replacementEventID == nil
                && value.primaryCommandDigest == nil
                && (
                    resolution == .keepAsCurrent
                        ? hasNoTerminalReminder
                        : hasTerminalReminder
                )
        case .continueCountingUp, .complete:
            let terminalIsValid = value.commandKind == .complete
                ? hasTerminalReminder
                : hasNoTerminalReminder
            return value.expectedLatestEventID != nil
                && noContent
                && value.today != nil
                && value.reviewResolutionRawValue == nil
                && value.replacementCountdownID == nil
                && value.replacementEventID == nil
                && value.primaryCommandDigest == nil
                && terminalIsValid
        case .archive, .delete:
            let terminalIsValid = value.commandKind == .archive
                ? hasTerminalReminder
                : hasNoTerminalReminder
            return value.expectedLatestEventID != nil
                && noContent
                && noToday
                && value.reviewResolutionRawValue == nil
                && value.replacementCountdownID == nil
                && value.replacementEventID == nil
                && value.primaryCommandDigest == nil
                && terminalIsValid
        case .replace:
            return value.expectedLatestEventID != nil
                && hasContent
                && noToday
                && value.reviewResolutionRawValue == nil
                && value.replacementCountdownID != nil
                && value.replacementEventID != nil
                && value.primaryCommandDigest == nil
                && hasNoTerminalReminder
        case .replacementDeletion:
            return value.expectedLatestEventID != nil
                && noContent
                && noToday
                && value.reviewResolutionRawValue == nil
                && value.replacementCountdownID != nil
                && value.replacementEventID != nil
                && value.primaryCommandDigest.map(isDigest) == true
                && hasNoTerminalReminder
        case nil:
            return false
        }
    }

    private static func validatesCheckpointShape(
        _ value: CountdownV6AuditCheckpointRecord
    ) -> Bool {
        value.prefixEventCount > 0
            && isDigest(value.prefixChainDigest)
            && isDigest(value.postFactsDigest)
            && value.reminderAdmission != nil
            && value.createdAt.timeIntervalSince1970.isFinite
            && isDigest(value.checkpointDigest)
    }

    private static func commandKindMatchesEvent(
        _ audit: CountdownCommandAuditRecord,
        event: CountdownLifecycleEventRecord
    ) -> Bool {
        switch audit.commandKind {
        case .migratedSnapshot:
            return event.kind == .migratedSnapshot
        case .create, .replace:
            return event.kind == .created
        case .update:
            return [.edited, .visibilityChanged, .reminderChanged]
                .contains(event.kind)
        case .review:
            return [.reviewResolved, .archived].contains(event.kind)
        case .continueCountingUp:
            return event.kind == .continuedCountingUp
        case .complete:
            return event.kind == .completed
        case .archive:
            return event.kind == .archived
        case .delete:
            return event.kind == .deleted
        case .replacementDeletion:
            return event.kind == .replaced
        case nil:
            return false
        }
    }

    private static func expectedPredecessorMatches(
        _ audit: CountdownCommandAuditRecord,
        event: CountdownLifecycleEventRecord
    ) -> Bool {
        switch audit.commandKind {
        case .migratedSnapshot, .create:
            return audit.expectedLatestEventID == nil
                && event.previousEventID == nil
        case .replace:
            return audit.expectedLatestEventID != nil
                && event.previousEventID == nil
        case .update, .review, .continueCountingUp, .complete,
             .archive, .delete, .replacementDeletion:
            return audit.expectedLatestEventID == event.previousEventID
        case nil:
            return false
        }
    }

    private static func commandDateMatchesEvent(
        _ audit: CountdownCommandAuditRecord,
        event: CountdownLifecycleEventRecord
    ) -> Bool {
        switch audit.commandKind {
        case .migratedSnapshot, .create, .update, .replace:
            return audit.targetDate == event.newTargetDate
        case .continueCountingUp, .complete:
            return audit.today == event.historicalTimestamp?.localDate
        case .review, .archive, .delete, .replacementDeletion:
            return true
        case nil:
            return false
        }
    }

    private static func replacementAuditMatches(
        _ audit: CountdownCommandAuditRecord,
        auditByEventID: [UUID: CountdownCommandAuditRecord]
    ) -> Bool {
        switch audit.commandKind {
        case .replace:
            guard let deletionEventID = audit.replacementEventID,
                  let deletion = auditByEventID[deletionEventID] else {
                return false
            }
            return deletion.commandKind == .replacementDeletion
                && deletion.replacementCountdownID == audit.countdownID
                && deletion.replacementEventID == audit.eventID
                && deletion.countdownID == audit.replacementCountdownID
                && deletion.primaryCommandDigest == audit.commandDigest
        case .replacementDeletion:
            guard let replacementEventID = audit.replacementEventID,
                  let replacement = auditByEventID[replacementEventID] else {
                return false
            }
            return replacement.commandKind == .replace
                && replacement.replacementCountdownID == audit.countdownID
                && replacement.replacementEventID == audit.eventID
                && replacement.countdownID == audit.replacementCountdownID
                && audit.primaryCommandDigest == replacement.commandDigest
        case .migratedSnapshot, .create, .update, .review,
             .continueCountingUp, .complete, .archive, .delete:
            return true
        case nil:
            return false
        }
    }

    private static func currentProjectionMatches(
        state: CountdownStateRecord,
        reminder: CountdownReminderRuleRecord,
        orderedAudits: [CountdownCommandAuditRecord]
    ) throws -> Bool {
        guard state.lifecycle != .deleted else { return true }
        let contentKinds: Set<CountdownCommandAuditKind> = [
            .migratedSnapshot,
            .create,
            .update,
            .replace
        ]
        guard let contentIndex = orderedAudits.lastIndex(where: {
            $0.commandKind.map(contentKinds.contains) == true
        }) else {
            return true
        }
        let content = orderedAudits[contentIndex]
        guard content.titleCommitment
                == (try CountdownIntegrityDigest.privateCommitment(
                    state.title,
                    operationID: content.operationID,
                    label: "title"
                )),
              content.gentleTitleCommitment
                == (try CountdownIntegrityDigest.privateCommitment(
                    state.gentleTitle,
                    operationID: content.operationID,
                    label: "gentleTitle"
                )),
              content.targetDate == state.targetDate else {
            return false
        }

        switch state.lifecycle {
        case .active:
            let laterAudits = orderedAudits.dropFirst(contentIndex + 1)
            let wasKeptCurrent = laterAudits.contains {
                $0.commandKind == .review
                    && $0.reviewResolutionRawValue
                        == CountdownReviewResolution.keepAsCurrent.rawValue
            }
            let expectedShowInToday = wasKeptCurrent
                ? true
                : content.showInToday
            return state.showInToday == expectedShowInToday
                && reminder.isEnabled == content.reminderIsEnabled
                && reminder.leadDays == content.reminderLeadDays
                && reminder.localHour == content.reminderLocalHour
                && reminder.localMinute == content.reminderLocalMinute
        case .completed, .archived:
            return state.terminalReminderWasEnabled
                    == content.reminderIsEnabled
                && state.terminalReminderLeadDays
                    == content.reminderLeadDays
                && state.terminalReminderLocalHour
                    == content.reminderLocalHour
                && state.terminalReminderLocalMinute
                    == content.reminderLocalMinute
        case .deleted:
            return true
        case nil:
            return false
        }
    }

    private static func orderedChain(
        latestEventID: UUID,
        events: [CountdownLifecycleEventRecord],
        eventByID: [UUID: CountdownLifecycleEventRecord],
        failure: AppDataFailure
    ) throws -> [CountdownLifecycleEventRecord] {
        var reverse: [CountdownLifecycleEventRecord] = []
        var cursor: UUID? = latestEventID
        var visited = Set<UUID>()
        while let id = cursor {
            guard visited.insert(id).inserted,
                  let event = eventByID[id] else {
                throw failure
            }
            reverse.append(event)
            cursor = event.previousEventID
        }
        let ordered = reverse.reversed()
        guard ordered.count == events.count else {
            throw failure
        }
        return Array(ordered)
    }

    private static func validateTerminalSnapshot(
        state: CountdownStateRecord,
        latestAudit: CountdownCommandAuditRecord?,
        checkpoint: CountdownV6AuditCheckpointRecord?,
        failure: AppDataFailure
    ) throws {
        let expected = (
            state.terminalReminderWasEnabled,
            state.terminalReminderLeadDays,
            state.terminalReminderLocalHour,
            state.terminalReminderLocalMinute
        )
        if let latestAudit {
            let actual = (
                latestAudit.terminalReminderWasEnabled,
                latestAudit.terminalReminderLeadDays,
                latestAudit.terminalReminderLocalHour,
                latestAudit.terminalReminderLocalMinute
            )
            switch state.lifecycle {
            case .completed, .archived:
                guard expected == actual else { throw failure }
            case .active, .deleted:
                guard actual.0 == nil, actual.1 == nil,
                      actual.2 == nil, actual.3 == nil else {
                    throw failure
                }
            case nil:
                throw failure
            }
        } else if checkpoint == nil {
            throw failure
        }
    }

    private static func validatesInitialSet(
        marker: CountdownIntegrityBackfillState,
        audits: [CountdownCommandAuditRecord],
        checkpoints: [CountdownV6AuditCheckpointRecord]
    ) -> Bool {
        let initialAudits = marker.sourceSchemaVersion == "7.0.0"
            ? audits.filter { $0.commandKind == .migratedSnapshot }
            : []
        guard marker.initialAuditCount == initialAudits.count,
              marker.initialCheckpointCount == checkpoints.count else {
            return false
        }
        return (try? CountdownIntegrityDigest.integritySetDigest(
            audits: initialAudits,
            checkpoints: checkpoints
        )) == marker.initialIntegritySetDigest
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
