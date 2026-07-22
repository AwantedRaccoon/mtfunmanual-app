import Foundation
import SwiftData

enum AppDataIndex {
    static func checkedUniqueMap<Values: Sequence, Key: Hashable>(
        _ values: Values,
        keyedBy key: (Values.Element) -> Key,
        failure: AppDataFailure
    ) throws -> [Key: Values.Element] {
        var result: [Key: Values.Element] = [:]
        for value in values {
            guard result.updateValue(value, forKey: key(value)) == nil else {
                throw failure
            }
        }
        return result
    }
}

enum TodayExecutionRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        let states = try context.fetch(FetchDescriptor<TodayExecutionBackfillState>())
        guard states.count == 1,
              states[0].taskKey == TodayExecutionBackfillState.fixedKey,
              states[0].completedAt?.timeIntervalSince1970.isFinite == true,
              states[0].updatedAt.timeIntervalSince1970.isFinite else {
            throw failure
        }

        let coverage = try context.fetch(FetchDescriptor<NotificationCoverageRecord>())
        guard coverage.count == 1,
              coverage[0].coverageKey == NotificationCoverageRecord.fixedKey,
              coverage[0].status != nil,
              coverage[0].desiredCount >= 0,
              coverage[0].confirmedPendingCount >= 0,
              coverage[0].confirmedPendingCount <= coverage[0].desiredCount,
              coverage[0].observedAt.timeIntervalSince1970.isFinite,
              coverage[0].scheduledThrough?.timeIntervalSince1970.isFinite != false,
              coverageIsConsistent(coverage[0]) else {
            throw failure
        }

        let schedules = try context.fetch(FetchDescriptor<ScheduleRuleRecord>())
        let scheduleByID = try AppDataIndex.checkedUniqueMap(
            schedules,
            keyedBy: \.id,
            failure: failure
        )
        let items = try context.fetch(FetchDescriptor<RegimenItemRecord>())
        let itemByID = try AppDataIndex.checkedUniqueMap(
            items,
            keyedBy: \.id,
            failure: failure
        )
        let versions = try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>())
        let versionByID = try AppDataIndex.checkedUniqueMap(
            versions,
            keyedBy: \.id,
            failure: failure
        )
        let regimenTimeline = versions
            .filter { !$0.isArchived }
            .compactMap { version -> RegimenTimelineVersion? in
                guard let start = version.effectiveStartDate else { return nil }
                return RegimenTimelineVersion(
                    id: version.id,
                    start: start,
                    end: version.effectiveEndDate,
                    editState: version.editState,
                    requiresReview: version.requiresMigrationReview
                )
            }
        guard let normalizedTimeline = RegimenTimelineResolver.normalizedEligibleTimeline(
            regimenTimeline
        ) else {
            throw failure
        }
        let normalizedTimelineByID = try AppDataIndex.checkedUniqueMap(
            normalizedTimeline,
            keyedBy: \.id,
            failure: failure
        )

        let preferences = try context.fetch(FetchDescriptor<ReminderPreferenceRecord>())
        guard Set(preferences.map(\.preferenceKey)).count == preferences.count,
              Set(preferences.map(\.id)).count == preferences.count,
              preferences.allSatisfy({ preference in
                  guard let schedule = scheduleByID[preference.scheduleRuleID] else { return false }
                  return preference.preferenceKey == ReminderPreferenceRecord.key(
                      scheduleRuleID: preference.scheduleRuleID,
                      revision: preference.expectedRuleRevision
                  )
                      && preference.expectedRuleRevision == schedule.revision
                      && (1...1_440).contains(preference.defaultSnoozeMinutes)
                      && preference.contentVersion == "gentleV1"
                      && preference.updatedAt.timeIntervalSince1970.isFinite
              }) else {
            throw failure
        }

        let events = try context.fetch(FetchDescriptor<AdministrationEventRecord>())
        let eventByID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: failure
        )
        guard eventByID.count == events.count,
              events.allSatisfy({ event in
                  guard let schedule = scheduleByID[event.scheduleRuleID],
                        schedule.revision == event.scheduleRevision,
                        schedule.regimenItemID == event.regimenItemID,
                        let item = itemByID[event.regimenItemID],
                        let timelineVersion = normalizedTimelineByID[item.regimenVersionID],
                        let spec = scheduleSpec(
                            schedule,
                            item: item,
                            timelineVersion: timelineVersion
                        ) else { return false }
                  return item.regimenVersionID == event.regimenVersionID
                      && versionByID[event.regimenVersionID] != nil
                      && event.status != nil
                      && event.createdAt.timeIntervalSince1970.isFinite
                      && ScheduleOccurrenceResolver.validatesStoredOccurrence(
                        key: event.occurrenceKey,
                        plannedInstant: event.plannedInstant,
                        rule: spec
                      )
              }) else {
            throw failure
        }
        try validateEventChains(events, failure: failure)

        let overrides = try context.fetch(FetchDescriptor<ReminderOverrideRecord>())
        let overrideByID = try AppDataIndex.checkedUniqueMap(
            overrides,
            keyedBy: \.id,
            failure: failure
        )
        guard overrideByID.count == overrides.count,
              overrides.allSatisfy({ override in
                  guard let schedule = scheduleByID[override.scheduleRuleID],
                        let item = itemByID[schedule.regimenItemID],
                        let timelineVersion = normalizedTimelineByID[item.regimenVersionID],
                        let spec = scheduleSpec(
                            schedule,
                            item: item,
                            timelineVersion: timelineVersion
                        ) else { return false }
                  return schedule.revision == override.scheduleRevision
                      && override.fireAt.timeIntervalSince1970.isFinite
                      && override.createdAt.timeIntervalSince1970.isFinite
                      && override.fireAt > override.createdAt
                      && override.fireAt.timeIntervalSince(override.createdAt) <= 86_400
                      && ScheduleOccurrenceResolver.validatesStoredOccurrence(
                        key: override.occurrenceKey,
                        plannedInstant: override.plannedInstant,
                        rule: spec
                      )
              }) else {
            throw failure
        }
        try validateOverrideChains(overrides, failure: failure)

        let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
        let receiptByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )
        let administrationReceipts = receipts.filter {
            $0.resultRecordType == "AdministrationEventRecord"
        }
        let overrideReceipts = receipts.filter {
            $0.resultRecordType == "ReminderOverrideRecord"
        }
        guard Set(receipts.map(\.operationID)).count == receipts.count,
              receipts.allSatisfy({ receipt in
                  guard receipt.commandDigest.count == 64,
                        receipt.commandDigest.allSatisfy(\.isHexDigit),
                        receipt.committedAt.timeIntervalSince1970.isFinite else {
                      return false
                  }
                  switch receipt.resultRecordType {
                  case "AdministrationEventRecord":
                      return eventByID[receipt.resultRecordID]?.operationID
                          == receipt.operationID
                  case "ReminderOverrideRecord":
                      return overrideByID[receipt.resultRecordID]?.operationID
                          == receipt.operationID
                  case "ReminderPreferenceRecord":
                      return preferences.contains { $0.id == receipt.resultRecordID }
                  default:
                      return false
                  }
              }) else {
            throw failure
        }
        guard Set(events.map(\.operationID)).count == events.count,
              administrationReceipts.count == events.count,
              events.allSatisfy({ event in
                  guard let receipt = receiptByOperationID[event.operationID] else { return false }
                  return receipt.resultRecordType == "AdministrationEventRecord"
                      && receipt.resultRecordID == event.id
              }),
              Set(overrides.map(\.operationID)).count == overrides.count,
              overrideReceipts.count == overrides.count,
              overrides.allSatisfy({ override in
                  guard let receipt = receiptByOperationID[override.operationID] else { return false }
                  return receipt.resultRecordType == "ReminderOverrideRecord"
                      && receipt.resultRecordID == override.id
              }),
              preferences.allSatisfy({ preference in
                  guard let receipt = receiptByOperationID[preference.lastOperationID] else {
                      return false
                  }
                  return receipt.resultRecordType == "ReminderPreferenceRecord"
                      && receipt.resultRecordID == preference.id
              }) else {
            throw failure
        }

        var ledgerDescriptor = FetchDescriptor<OperationReceiptLedgerRecord>()
        ledgerDescriptor.fetchLimit = 2
        let ledgers = try context.fetch(ledgerDescriptor)
        guard ledgers.count == 1,
              let ledger = ledgers.first,
              ledger.ledgerKey == OperationReceiptLedgerRecord.fixedKey,
              ledger.receiptCount == receipts.count,
              ledger.receiptSetDigest == (try TodayExecutionDigestV1.receiptSetDigest(receipts)),
              ledger.updatedAt.timeIntervalSince1970.isFinite else {
            throw failure
        }

        let adminHistoricalKeys = Set(events.map {
            "AdministrationEventRecord:" + $0.id.uuidString.lowercased()
        })
        let allHistorical = try context.fetch(FetchDescriptor<HistoricalTimeRecord>())
        let actualHistorical = allHistorical.filter {
            $0.sourceRecordType == "AdministrationEventRecord"
        }
        let migrationIssueKeys = Set(
            try context.fetch(FetchDescriptor<MigrationIssue>()).map(\.issueKey)
        )
        guard Set(actualHistorical.map(\.recordKey)) == adminHistoricalKeys,
              actualHistorical.count == events.count,
              actualHistorical.allSatisfy({ historical in
                  guard eventByID[historical.sourceRecordID] != nil,
                        let timestamp = historical.historicalTimestamp else { return false }
                  let projection = RegimenTimelineResolver.project(
                      regimenTimeline,
                      asOf: timestamp.localDate
                  )
                  let expectedState: HistoricalAssociationState
                  let expectedID: UUID?
                  if let current = projection.current {
                      expectedState = .resolved
                      expectedID = current.id
                  } else if projection.isAmbiguous {
                      expectedState = .ambiguous
                      expectedID = nil
                  } else {
                      expectedState = .missing
                      expectedID = nil
                  }
                  let missingKey = [
                      MigrationIssueKind.missingCanonicalRegimenAssociation.rawValue,
                      historical.sourceRecordType,
                      historical.sourceRecordID.uuidString.lowercased()
                  ].joined(separator: ":")
                  let ambiguousKey = [
                      MigrationIssueKind.ambiguousCanonicalRegimenAssociation.rawValue,
                      historical.sourceRecordType,
                      historical.sourceRecordID.uuidString.lowercased()
                  ].joined(separator: ":")
                  let issueIsConsistent: Bool = switch expectedState {
                  case .resolved:
                      !migrationIssueKeys.contains(missingKey)
                          && !migrationIssueKeys.contains(ambiguousKey)
                  case .missing:
                      migrationIssueKeys.contains(missingKey)
                          && !migrationIssueKeys.contains(ambiguousKey)
                  case .ambiguous:
                      !migrationIssueKeys.contains(missingKey)
                          && migrationIssueKeys.contains(ambiguousKey)
                  }
                  return historical.resolvedRegimenVersionID == expectedID
                      && historical.associationStateRawValue == expectedState.rawValue
                      && issueIsConsistent
              }) else {
            throw failure
        }
    }

    private static func coverageIsConsistent(
        _ coverage: NotificationCoverageRecord
    ) -> Bool {
        guard let status = coverage.status else { return false }
        switch status {
        case .disabledByUser, .notDetermined, .blockedByPermission,
             .limitedBySystemSettings, .reconciliationPending, .staleObservation:
            return coverage.desiredCount == 0
                && coverage.confirmedPendingCount == 0
                && coverage.scheduledThrough == nil
                && coverage.lastErrorCode == nil
        case .scheduledForWindow:
            return coverage.confirmedPendingCount == coverage.desiredCount
                && coverage.lastErrorCode == nil
                && (coverage.desiredCount == 0 || coverage.scheduledThrough != nil)
        case .limitedByBudget:
            return coverage.confirmedPendingCount == coverage.desiredCount
                && coverage.scheduledThrough != nil
                && coverage.lastErrorCode == nil
        case .schedulingFailed:
            return coverage.scheduledThrough == nil
                && coverage.lastErrorCode?.isEmpty == false
        }
    }

    private static func scheduleSpec(
        _ schedule: ScheduleRuleRecord,
        item: RegimenItemRecord,
        timelineVersion: RegimenTimelineVersion
    ) -> ScheduleRuleSpec? {
        guard let kind = ScheduleRuleKind(rawValue: schedule.kindRawValue),
              let behavior = ScheduleTimeZoneBehavior(
                rawValue: schedule.timeZoneBehaviorRawValue
              ),
              let anchor = try? CivilDateFact(
                year: schedule.anchorYear,
                month: schedule.anchorMonth,
                day: schedule.anchorDay
              ) else { return nil }

        let endDate: CivilDateFact?
        if let year = schedule.endYear,
           let month = schedule.endMonth,
           let day = schedule.endDay {
            guard let parsed = try? CivilDateFact(year: year, month: month, day: day) else {
                return nil
            }
            endDate = parsed
        } else {
            guard schedule.endYear == nil,
                  schedule.endMonth == nil,
                  schedule.endDay == nil else { return nil }
            endDate = nil
        }

        guard endDate.map({ anchor < $0 }) ?? true else { return nil }
        let activeStartDate = max(anchor, timelineVersion.start)
        let activeEndDate: CivilDateFact?
        switch (endDate, timelineVersion.end) {
        case let (ruleEnd?, versionEnd?): activeEndDate = min(ruleEnd, versionEnd)
        case let (ruleEnd?, nil): activeEndDate = ruleEnd
        case let (nil, versionEnd?): activeEndDate = versionEnd
        case (nil, nil): activeEndDate = nil
        }
        guard activeEndDate.map({ activeStartDate < $0 }) ?? true else { return nil }

        return ScheduleRuleSpec(
            id: schedule.id,
            regimenVersionID: item.regimenVersionID,
            regimenItemID: item.id,
            displayName: item.displayName,
            kind: kind,
            anchorDate: anchor,
            activeStartDate: activeStartDate,
            endDate: activeEndDate,
            localTimes: schedule.localTimes,
            weekdays: schedule.weekdays,
            intervalDays: schedule.intervalDays,
            timeZoneBehavior: behavior,
            fixedTimeZoneIdentifier: schedule.fixedTimeZoneIdentifier,
            revision: schedule.revision
        )
    }

    private static func validateEventChains(
        _ events: [AdministrationEventRecord],
        failure: AppDataFailure
    ) throws {
        for group in Dictionary(grouping: events, by: \.occurrenceKey).values {
            guard SupersessionChainValidator.formsSingleChain(
                group.map {
                    SupersessionLink(id: $0.id, predecessorID: $0.supersedesEventID)
                }
            ) else {
                throw failure
            }
        }
    }

    private static func validateOverrideChains(
        _ overrides: [ReminderOverrideRecord],
        failure: AppDataFailure
    ) throws {
        for group in Dictionary(grouping: overrides, by: \.occurrenceKey).values {
            guard SupersessionChainValidator.formsSingleChain(
                group.map {
                    SupersessionLink(id: $0.id, predecessorID: $0.supersedesOverrideID)
                }
            ) else {
                throw failure
            }
        }
    }
}
