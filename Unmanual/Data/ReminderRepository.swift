import Foundation
import SwiftData

struct SetReminderPreferenceCommand: Sendable {
    let operationID: UUID
    let scheduleRuleID: UUID
    let expectedRuleRevision: Int
    let isEnabled: Bool
    let defaultSnoozeMinutes: Int
    let committedAt: Date
}

struct ReminderPreferenceResult: Equatable, Sendable {
    let preferenceID: UUID
    let didApply: Bool
}

struct ApplyReminderOverrideCommand: Sendable {
    let operationID: UUID
    let overrideID: UUID
    let occurrence: PlannedOccurrence
    let expectedOverrideID: UUID?
    let fireAt: Date
    let committedAt: Date
    let displayTimeZoneIdentifier: String

    init(
        operationID: UUID,
        overrideID: UUID,
        occurrence: PlannedOccurrence,
        expectedOverrideID: UUID?,
        fireAt: Date,
        committedAt: Date,
        displayTimeZoneIdentifier: String? = nil
    ) {
        self.operationID = operationID
        self.overrideID = overrideID
        self.occurrence = occurrence
        self.expectedOverrideID = expectedOverrideID
        self.fireAt = fireAt
        self.committedAt = committedAt
        self.displayTimeZoneIdentifier = displayTimeZoneIdentifier
            ?? occurrence.timeZoneIdentifier
    }
}

struct ReminderOverrideResult: Equatable, Sendable {
    let overrideID: UUID
    let didCreate: Bool
}

extension AppWriteActor {
    func setReminderPreference(
        _ command: SetReminderPreferenceCommand
    ) throws -> ReminderPreferenceResult {
        try ensureDataControlScheduleRuleIsWritable(
            command.scheduleRuleID
        )
        let digest = try TodayExecutionDigestV1.reminderPreferenceCommand(command)
        if let replay = try reminderPreferenceReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        guard command.expectedRuleRevision > 0,
              (1...1_440).contains(command.defaultSnoozeMinutes),
              command.committedAt.timeIntervalSince1970.isFinite else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let ruleID = command.scheduleRuleID
        var ruleDescriptor = FetchDescriptor<ScheduleRuleRecord>(
            predicate: #Predicate { $0.id == ruleID }
        )
        ruleDescriptor.fetchLimit = 1
        guard let rule = try modelContext.fetch(ruleDescriptor).first,
              rule.revision == command.expectedRuleRevision else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let itemID = rule.regimenItemID
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>(
            predicate: #Predicate { $0.id == itemID }
        )
        itemDescriptor.fetchLimit = 1
        guard let item = try modelContext.fetch(itemDescriptor).first else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let versionID = item.regimenVersionID
        var versionDescriptor = FetchDescriptor<RegimenPlanVersionRecord>(
            predicate: #Predicate { $0.id == versionID }
        )
        versionDescriptor.fetchLimit = 1
        guard let version = try modelContext.fetch(versionDescriptor).first,
              version.editState == .sealed,
              !version.isArchived,
              !version.requiresMigrationReview else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }

        let preferenceKey = ReminderPreferenceRecord.key(
            scheduleRuleID: rule.id,
            revision: rule.revision
        )
        var preferenceDescriptor = FetchDescriptor<ReminderPreferenceRecord>(
            predicate: #Predicate { $0.preferenceKey == preferenceKey }
        )
        preferenceDescriptor.fetchLimit = 1
        let existing = try modelContext.fetch(preferenceDescriptor).first
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: ReminderPreferenceResult?
            try modelContext.transaction {
                try ensureDataControlScheduleRuleIsWritable(
                    command.scheduleRuleID
                )
                if let replay = try reminderPreferenceReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let preference = existing ?? ReminderPreferenceRecord(
                    scheduleRuleID: rule.id,
                    expectedRuleRevision: rule.revision,
                    isEnabled: command.isEnabled,
                    defaultSnoozeMinutes: command.defaultSnoozeMinutes,
                    lastOperationID: command.operationID,
                    updatedAt: command.committedAt
                )
                if existing == nil { modelContext.insert(preference) }
                preference.isEnabled = command.isEnabled
                preference.defaultSnoozeMinutes = command.defaultSnoozeMinutes
                preference.contentVersion = "gentleV1"
                preference.lastOperationID = command.operationID
                preference.updatedAt = command.committedAt
                try upsertRevision(
                    recordType: "ReminderPreferenceRecord",
                    recordID: preference.id,
                    fields: TodayExecutionDigestV1.reminderPreference(preference),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "ReminderPreferenceRecord",
                        resultRecordID: preference.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = ReminderPreferenceResult(
                    preferenceID: preference.id,
                    didApply: true
                )
            }
            guard let result else { throw AppWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func reminderPreferenceReplay(
        operationID: UUID,
        digest: String
    ) throws -> ReminderPreferenceResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 1
        guard let receipt = try modelContext.fetch(descriptor).first else { return nil }
        let resultID = receipt.resultRecordID
        var preferenceDescriptor = FetchDescriptor<ReminderPreferenceRecord>(
            predicate: #Predicate { $0.id == resultID }
        )
        preferenceDescriptor.fetchLimit = 1
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "ReminderPreferenceRecord",
              try modelContext.fetch(preferenceDescriptor).first != nil else {
            throw TodayExecutionWriteFailure.operationConflict
        }
        return ReminderPreferenceResult(preferenceID: resultID, didApply: false)
    }

    func applyReminderOverride(
        _ command: ApplyReminderOverrideCommand
    ) throws -> ReminderOverrideResult {
        try ensureDataControlOccurrenceIsWritable(
            command.occurrence
        )
        let digest = try TodayExecutionDigestV1.reminderOverrideCommand(command)
        if let replay = try reminderOverrideReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        guard command.fireAt > command.committedAt,
              command.fireAt.timeIntervalSince(command.committedAt) <= 86_400,
              command.fireAt.timeIntervalSince1970.isFinite,
              command.committedAt.timeIntervalSince1970.isFinite else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        try validateOccurrenceForTodayExecution(
            command.occurrence,
            committedAt: command.committedAt,
            displayTimeZoneIdentifier: command.displayTimeZoneIdentifier
        )
        let overrides = try reminderOverrides(for: command.occurrence.key)
        let leaf = try effectiveReminderOverride(in: overrides)
        guard leaf?.id == command.expectedOverrideID else {
            throw TodayExecutionWriteFailure.staleLeaf
        }

        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: ReminderOverrideResult?
            try modelContext.transaction {
                try ensureDataControlOccurrenceIsWritable(
                    command.occurrence
                )
                if let replay = try reminderOverrideReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                try validateOccurrenceForTodayExecution(
                    command.occurrence,
                    committedAt: command.committedAt,
                    displayTimeZoneIdentifier: command.displayTimeZoneIdentifier
                )
                let transactionalLeaf = try effectiveReminderOverride(
                    in: reminderOverrides(for: command.occurrence.key)
                )
                guard transactionalLeaf?.id == command.expectedOverrideID else {
                    throw TodayExecutionWriteFailure.staleLeaf
                }
                let record = ReminderOverrideRecord(
                    id: command.overrideID,
                    occurrenceKey: command.occurrence.key,
                    scheduleRuleID: command.occurrence.scheduleRuleID,
                    scheduleRevision: command.occurrence.scheduleRevision,
                    fireAt: command.fireAt,
                    plannedInstant: command.occurrence.instant,
                    supersedesOverrideID: command.expectedOverrideID,
                    operationID: command.operationID,
                    createdAt: command.committedAt
                )
                modelContext.insert(record)
                try upsertRevision(
                    recordType: "ReminderOverrideRecord",
                    recordID: record.id,
                    fields: try TodayExecutionDigestV1.reminderOverride(record),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "ReminderOverrideRecord",
                        resultRecordID: record.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = ReminderOverrideResult(overrideID: record.id, didCreate: true)
            }
            guard let result else { throw AppWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func reminderOverrideReplay(
        operationID: UUID,
        digest: String
    ) throws -> ReminderOverrideResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 1
        guard let receipt = try modelContext.fetch(descriptor).first else { return nil }
        let resultID = receipt.resultRecordID
        var overrideDescriptor = FetchDescriptor<ReminderOverrideRecord>(
            predicate: #Predicate { $0.id == resultID }
        )
        overrideDescriptor.fetchLimit = 1
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "ReminderOverrideRecord",
              try modelContext.fetch(overrideDescriptor).first != nil else {
            throw TodayExecutionWriteFailure.operationConflict
        }
        return ReminderOverrideResult(overrideID: resultID, didCreate: false)
    }

    private func reminderOverrides(
        for occurrenceKey: String
    ) throws -> [ReminderOverrideRecord] {
        let key = occurrenceKey
        return try modelContext.fetch(
            FetchDescriptor<ReminderOverrideRecord>(
                predicate: #Predicate { $0.occurrenceKey == key }
            )
        )
    }

    private func effectiveReminderOverride(
        in records: [ReminderOverrideRecord]
    ) throws -> ReminderOverrideRecord? {
        guard SupersessionChainValidator.formsSingleChain(
            records.map {
                SupersessionLink(id: $0.id, predecessorID: $0.supersedesOverrideID)
            }
        ) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let superseded = Set(records.compactMap(\.supersedesOverrideID))
        return records.first { !superseded.contains($0.id) }
    }
}

extension AppWriteActor {
    func updateNotificationCoverage(
        _ observation: LocalReminderReconciliationObservation
    ) throws {
        guard observation.desiredCount >= 0,
              observation.confirmedPendingCount >= 0,
              observation.confirmedPendingCount <= observation.desiredCount,
              observation.observedAt.timeIntervalSince1970.isFinite,
              observation.scheduledThrough?.timeIntervalSince1970.isFinite != false,
              Self.coverageObservationIsConsistent(observation) else {
            throw AppDataFailure.corruptionSuspected
        }
        var descriptor = FetchDescriptor<NotificationCoverageRecord>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let record = records.first else {
            throw AppDataFailure.corruptionSuspected
        }
        try modelContext.transaction {
            record.statusRawValue = observation.status.rawValue
            record.scheduledThrough = observation.scheduledThrough
            record.desiredCount = observation.desiredCount
            record.confirmedPendingCount = observation.confirmedPendingCount
            record.lastErrorCode = observation.lastErrorCode
            record.observedAt = observation.observedAt
            try modelContext.save()
        }
    }

    func updateCountdownNotificationCoverage(
        _ observation: LocalReminderReconciliationObservation
    ) throws {
        guard observation.countdownDesiredCount >= 0,
              observation.countdownConfirmedPendingCount >= 0,
              observation.countdownConfirmedPendingCount
                <= observation.countdownDesiredCount,
              observation.observedAt.timeIntervalSince1970.isFinite,
              observation.countdownScheduledFireAt?
                .timeIntervalSince1970.isFinite != false,
              Self.countdownCoverageObservationIsConsistent(observation) else {
            throw AppDataFailure.corruptionSuspected
        }
        var descriptor =
            FetchDescriptor<CountdownNotificationCoverageRecord>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1, let countdownRecord = records.first else {
            throw AppDataFailure.corruptionSuspected
        }
        try modelContext.transaction {
            countdownRecord.countdownID = observation.countdownID
            countdownRecord.statusRawValue =
                observation.countdownStatus.rawValue
            countdownRecord.scheduledFireAt =
                observation.countdownScheduledFireAt
            countdownRecord.desiredCount =
                observation.countdownDesiredCount
            countdownRecord.confirmedPendingCount =
                observation.countdownConfirmedPendingCount
            countdownRecord.lastErrorCode =
                observation.countdownStatus == .schedulingFailed
                    ? observation.countdownLastErrorCode
                    : nil
            countdownRecord.observedAt = observation.observedAt
            try modelContext.save()
        }
    }

    func updateUnifiedNotificationCoverage(
        _ observation: LocalReminderReconciliationObservation
    ) throws {
        guard observation.desiredCount >= 0,
              observation.confirmedPendingCount >= 0,
              observation.confirmedPendingCount <= observation.desiredCount,
              observation.countdownDesiredCount >= 0,
              observation.countdownConfirmedPendingCount >= 0,
              observation.countdownConfirmedPendingCount
                <= observation.countdownDesiredCount,
              observation.observedAt.timeIntervalSince1970.isFinite,
              observation.scheduledThrough?
                .timeIntervalSince1970.isFinite != false,
              observation.countdownScheduledFireAt?
                .timeIntervalSince1970.isFinite != false,
              Self.coverageObservationIsConsistent(observation),
              Self.countdownCoverageObservationIsConsistent(observation) else {
            throw AppDataFailure.corruptionSuspected
        }
        var scheduleDescriptor = FetchDescriptor<NotificationCoverageRecord>()
        scheduleDescriptor.fetchLimit = 2
        var countdownDescriptor =
            FetchDescriptor<CountdownNotificationCoverageRecord>()
        countdownDescriptor.fetchLimit = 2
        let scheduleRecords = try modelContext.fetch(scheduleDescriptor)
        let countdownRecords = try modelContext.fetch(countdownDescriptor)
        guard scheduleRecords.count == 1,
              let scheduleRecord = scheduleRecords.first,
              countdownRecords.count == 1,
              let countdownRecord = countdownRecords.first else {
            throw AppDataFailure.corruptionSuspected
        }
        try modelContext.transaction {
            scheduleRecord.statusRawValue = observation.status.rawValue
            scheduleRecord.scheduledThrough = observation.scheduledThrough
            scheduleRecord.desiredCount = observation.desiredCount
            scheduleRecord.confirmedPendingCount =
                observation.confirmedPendingCount
            scheduleRecord.lastErrorCode = observation.lastErrorCode
            scheduleRecord.observedAt = observation.observedAt

            countdownRecord.countdownID = observation.countdownID
            countdownRecord.statusRawValue =
                observation.countdownStatus.rawValue
            countdownRecord.scheduledFireAt =
                observation.countdownScheduledFireAt
            countdownRecord.desiredCount =
                observation.countdownDesiredCount
            countdownRecord.confirmedPendingCount =
                observation.countdownConfirmedPendingCount
            countdownRecord.lastErrorCode =
                observation.countdownStatus == .schedulingFailed
                    ? observation.countdownLastErrorCode
                    : nil
            countdownRecord.observedAt = observation.observedAt
            try modelContext.save()
        }
    }

    private static func coverageObservationIsConsistent(
        _ observation: LocalReminderReconciliationObservation
    ) -> Bool {
        switch observation.status {
        case .disabledByUser, .notDetermined, .blockedByPermission,
             .limitedBySystemSettings, .reconciliationPending, .staleObservation:
            return observation.desiredCount == 0
                && observation.confirmedPendingCount == 0
                && observation.scheduledThrough == nil
                && observation.lastErrorCode == nil
        case .scheduledForWindow:
            return observation.confirmedPendingCount == observation.desiredCount
                && observation.lastErrorCode == nil
                && (observation.desiredCount == 0 || observation.scheduledThrough != nil)
        case .limitedByBudget:
            return observation.confirmedPendingCount == observation.desiredCount
                && observation.scheduledThrough != nil
                && observation.lastErrorCode == nil
        case .schedulingFailed:
            return observation.scheduledThrough == nil
                && observation.lastErrorCode?.isEmpty == false
        }
    }

    private static func countdownCoverageObservationIsConsistent(
        _ observation: LocalReminderReconciliationObservation
    ) -> Bool {
        CountdownNotificationCoverageRecord.isConsistent(
            status: observation.countdownStatus,
            scheduledFireAt: observation.countdownScheduledFireAt,
            desiredCount: observation.countdownDesiredCount,
            confirmedPendingCount:
                observation.countdownConfirmedPendingCount,
            lastErrorCode: observation.countdownLastErrorCode
        )
    }
}

extension TodayExecutionDigestV1 {
    static func reminderPreference(
        _ preference: ReminderPreferenceRecord
    ) -> [RecordDigestV1.Field] {
        [
            .init("contentVersion", .string(preference.contentVersion)),
            .init("defaultSnoozeMinutes", .integer(Int64(preference.defaultSnoozeMinutes))),
            .init("expectedRuleRevision", .integer(Int64(preference.expectedRuleRevision))),
            .init("isEnabled", .bool(preference.isEnabled)),
            .init("lastOperationID", .uuid(preference.lastOperationID)),
            .init("preferenceKey", .string(preference.preferenceKey)),
            .init("scheduleRuleID", .uuid(preference.scheduleRuleID))
        ]
    }

    static func reminderOverride(
        _ override: ReminderOverrideRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("fireAt", try timestampValue(override.fireAt)),
            .init("occurrenceKey", .string(override.occurrenceKey)),
            .init("operationID", .uuid(override.operationID)),
            .init("plannedInstant", try timestampValue(override.plannedInstant)),
            .init("scheduleRevision", .integer(Int64(override.scheduleRevision))),
            .init("scheduleRuleID", .uuid(override.scheduleRuleID)),
            .init("supersedesOverrideID", override.supersedesOverrideID.map(RecordDigestV1.Value.uuid) ?? .null)
        ]
    }

    static func reminderOverrideCommand(
        _ command: ApplyReminderOverrideCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "ApplyReminderOverrideCommand",
            recordID: command.operationID,
            fields: [
                .init("committedAt", try timestampValue(command.committedAt)),
                .init("expectedOverrideID", command.expectedOverrideID.map(RecordDigestV1.Value.uuid) ?? .null),
                .init("displayTimeZoneIdentifier", .string(command.displayTimeZoneIdentifier)),
                .init("fireAt", try timestampValue(command.fireAt)),
                .init("overrideID", .uuid(command.overrideID))
            ] + plannedOccurrenceFields(command.occurrence)
        )
    }

    static func reminderPreferenceCommand(
        _ command: SetReminderPreferenceCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "SetReminderPreferenceCommand",
            recordID: command.operationID,
            fields: [
                .init("committedAt", try timestampValue(command.committedAt)),
                .init("defaultSnoozeMinutes", .integer(Int64(command.defaultSnoozeMinutes))),
                .init("expectedRuleRevision", .integer(Int64(command.expectedRuleRevision))),
                .init("isEnabled", .bool(command.isEnabled)),
                .init("scheduleRuleID", .uuid(command.scheduleRuleID))
            ]
        )
    }

    private static func timestampValue(_ date: Date) throws -> RecordDigestV1.Value {
        try RecordDigestV1.timestampValue(date)
    }
}
