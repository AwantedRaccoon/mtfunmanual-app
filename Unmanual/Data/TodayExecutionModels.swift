import Foundation
import SwiftData

enum AdministrationStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case taken
    case skipped
}

@Model
final class AdministrationEventRecord {
    @Attribute(.unique) var id: UUID
    var occurrenceKey: String
    var scheduleRuleID: UUID
    var scheduleRevision: Int
    var regimenVersionID: UUID
    var regimenItemID: UUID
    var statusRawValue: String
    var plannedInstant: Date
    var supersedesEventID: UUID?
    var note: String
    var createdAt: Date
    var operationID: UUID

    var status: AdministrationStatus? {
        AdministrationStatus(rawValue: statusRawValue)
    }

    init(
        id: UUID = UUID(),
        occurrenceKey: String,
        scheduleRuleID: UUID,
        scheduleRevision: Int,
        regimenVersionID: UUID,
        regimenItemID: UUID,
        status: AdministrationStatus,
        plannedInstant: Date,
        supersedesEventID: UUID? = nil,
        note: String = "",
        operationID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.occurrenceKey = occurrenceKey
        self.scheduleRuleID = scheduleRuleID
        self.scheduleRevision = scheduleRevision
        self.regimenVersionID = regimenVersionID
        self.regimenItemID = regimenItemID
        self.statusRawValue = status.rawValue
        self.plannedInstant = plannedInstant
        self.supersedesEventID = supersedesEventID
        self.note = note
        self.operationID = operationID
        self.createdAt = createdAt
    }
}

@Model
final class OperationReceiptRecord {
    @Attribute(.unique) var operationID: UUID
    var commandDigest: String
    var resultRecordType: String
    var resultRecordID: UUID
    var committedAt: Date

    init(
        operationID: UUID,
        commandDigest: String,
        resultRecordType: String,
        resultRecordID: UUID,
        committedAt: Date
    ) {
        self.operationID = operationID
        self.commandDigest = commandDigest
        self.resultRecordType = resultRecordType
        self.resultRecordID = resultRecordID
        self.committedAt = committedAt
    }
}

@Model
final class ReminderOverrideRecord {
    @Attribute(.unique) var id: UUID
    var occurrenceKey: String
    var scheduleRuleID: UUID
    var scheduleRevision: Int
    var fireAt: Date
    var plannedInstant: Date
    var supersedesOverrideID: UUID?
    var operationID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        occurrenceKey: String,
        scheduleRuleID: UUID,
        scheduleRevision: Int,
        fireAt: Date,
        plannedInstant: Date,
        supersedesOverrideID: UUID? = nil,
        operationID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.occurrenceKey = occurrenceKey
        self.scheduleRuleID = scheduleRuleID
        self.scheduleRevision = scheduleRevision
        self.fireAt = fireAt
        self.plannedInstant = plannedInstant
        self.supersedesOverrideID = supersedesOverrideID
        self.operationID = operationID
        self.createdAt = createdAt
    }
}

@Model
final class ReminderPreferenceRecord {
    @Attribute(.unique) var preferenceKey: String
    var id: UUID
    var scheduleRuleID: UUID
    var expectedRuleRevision: Int
    var isEnabled: Bool
    var defaultSnoozeMinutes: Int
    var contentVersion: String
    var lastOperationID: UUID
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        scheduleRuleID: UUID,
        expectedRuleRevision: Int,
        isEnabled: Bool,
        defaultSnoozeMinutes: Int = 10,
        contentVersion: String = "gentleV1",
        lastOperationID: UUID,
        updatedAt: Date = Date()
    ) {
        self.preferenceKey = Self.key(
            scheduleRuleID: scheduleRuleID,
            revision: expectedRuleRevision
        )
        self.id = id
        self.scheduleRuleID = scheduleRuleID
        self.expectedRuleRevision = expectedRuleRevision
        self.isEnabled = isEnabled
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.contentVersion = contentVersion
        self.lastOperationID = lastOperationID
        self.updatedAt = updatedAt
    }

    static func key(scheduleRuleID: UUID, revision: Int) -> String {
        scheduleRuleID.uuidString.lowercased() + ":" + String(revision)
    }
}

enum NotificationCoverageStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case disabledByUser
    case notDetermined
    case blockedByPermission
    case limitedBySystemSettings
    case reconciliationPending
    case scheduledForWindow
    case limitedByBudget
    case schedulingFailed
    case staleObservation
}

@Model
final class OperationReceiptLedgerRecord {
    static let fixedKey = "operation-receipt-ledger-v1"

    @Attribute(.unique) var ledgerKey: String
    var receiptCount: Int
    var receiptSetDigest: String
    var updatedAt: Date

    init(
        ledgerKey: String = OperationReceiptLedgerRecord.fixedKey,
        receiptCount: Int = 0,
        receiptSetDigest: String,
        updatedAt: Date = Date()
    ) {
        self.ledgerKey = ledgerKey
        self.receiptCount = receiptCount
        self.receiptSetDigest = receiptSetDigest
        self.updatedAt = updatedAt
    }
}

@Model
final class NotificationCoverageRecord {
    static let fixedKey = "local-execution-reminders"

    @Attribute(.unique) var coverageKey: String
    var statusRawValue: String
    var scheduledThrough: Date?
    var desiredCount: Int
    var confirmedPendingCount: Int
    var lastErrorCode: String?
    var observedAt: Date

    var status: NotificationCoverageStatus? {
        NotificationCoverageStatus(rawValue: statusRawValue)
    }

    init(
        coverageKey: String = NotificationCoverageRecord.fixedKey,
        status: NotificationCoverageStatus,
        scheduledThrough: Date? = nil,
        desiredCount: Int = 0,
        confirmedPendingCount: Int = 0,
        lastErrorCode: String? = nil,
        observedAt: Date = Date()
    ) {
        self.coverageKey = coverageKey
        self.statusRawValue = status.rawValue
        self.scheduledThrough = scheduledThrough
        self.desiredCount = desiredCount
        self.confirmedPendingCount = confirmedPendingCount
        self.lastErrorCode = lastErrorCode
        self.observedAt = observedAt
    }
}

@Model
final class TodayExecutionBackfillState {
    static let fixedKey = "v3-to-v4-today-execution"

    @Attribute(.unique) var taskKey: String
    var completedAt: Date?
    var updatedAt: Date

    init(
        taskKey: String = TodayExecutionBackfillState.fixedKey,
        completedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.taskKey = taskKey
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}
