import Foundation
import SwiftData

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
        let scheduleByID = Dictionary(uniqueKeysWithValues: schedules.map { ($0.id, $0) })
        let items = try context.fetch(FetchDescriptor<RegimenItemRecord>())
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let versions = try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>())
        let versionIDs = Set(versions.map(\.id))
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
        let eventByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        guard eventByID.count == events.count,
              events.allSatisfy({ event in
                  guard let schedule = scheduleByID[event.scheduleRuleID],
                        schedule.revision == event.scheduleRevision,
                        schedule.regimenItemID == event.regimenItemID,
                        let item = itemByID[event.regimenItemID] else { return false }
                  return item.regimenVersionID == event.regimenVersionID
                      && versionIDs.contains(event.regimenVersionID)
                      && event.status != nil
                      && event.plannedInstant.timeIntervalSince1970.isFinite
                      && event.createdAt.timeIntervalSince1970.isFinite
                      && event.occurrenceKey.hasPrefix(
                        "occ:v1:" + event.scheduleRuleID.uuidString.lowercased()
                            + ":" + String(event.scheduleRevision) + ":"
                      )
              }) else {
            throw failure
        }
        try validateEventChains(events, failure: failure)

        let overrides = try context.fetch(FetchDescriptor<ReminderOverrideRecord>())
        let overrideByID = Dictionary(uniqueKeysWithValues: overrides.map { ($0.id, $0) })
        guard overrideByID.count == overrides.count,
              overrides.allSatisfy({ override in
                  guard let schedule = scheduleByID[override.scheduleRuleID] else { return false }
                  return schedule.revision == override.scheduleRevision
                      && override.fireAt.timeIntervalSince1970.isFinite
                      && override.plannedInstant.timeIntervalSince1970.isFinite
                      && override.createdAt.timeIntervalSince1970.isFinite
                      && override.occurrenceKey.hasPrefix(
                        "occ:v1:" + override.scheduleRuleID.uuidString.lowercased()
                            + ":" + String(override.scheduleRevision) + ":"
                      )
              }) else {
            throw failure
        }
        try validateOverrideChains(overrides, failure: failure)

        let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
        let receiptByOperationID = Dictionary(
            uniqueKeysWithValues: receipts.map { ($0.operationID, $0) }
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
              ledger.receiptSetDigest == TodayExecutionDigestV1.receiptSetDigest(receipts),
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
