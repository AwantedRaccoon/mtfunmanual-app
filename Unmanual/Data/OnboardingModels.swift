import Foundation
import SwiftData

enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case privacy
    case startDate
    case regimen
    case reminder
    case countdown
    case ready
    case completed

    var order: Int {
        switch self {
        case .privacy: 0
        case .startDate: 1
        case .regimen: 2
        case .reminder: 3
        case .countdown: 4
        case .ready: 5
        case .completed: 6
        }
    }
}

enum OnboardingBackfillSource: String, Codable, Sendable {
    case newInstallV8
    case legacyAdoption
    case schemaUpgradeV7

    var treatsUserAsAlreadyOnboarded: Bool {
        self != .newInstallV8
    }
}

@Model
final class OnboardingProgressRecord {
    static let fixedKey = "primary-onboarding-progress"
    static let contractVersion = 1

    @Attribute(.unique) var singletonKey: String
    var contractVersion: Int
    var stepRawValue: String
    var skippedStartDate: Bool
    var skippedReminder: Bool
    var skippedCountdown: Bool
    var completedAt: Date?
    var updatedAt: Date

    var step: OnboardingStep? {
        OnboardingStep(rawValue: stepRawValue)
    }

    init(
        singletonKey: String = OnboardingProgressRecord.fixedKey,
        contractVersion: Int = OnboardingProgressRecord.contractVersion,
        step: OnboardingStep,
        skippedStartDate: Bool = false,
        skippedReminder: Bool = false,
        skippedCountdown: Bool = false,
        completedAt: Date? = nil,
        updatedAt: Date
    ) {
        self.singletonKey = singletonKey
        self.contractVersion = contractVersion
        self.stepRawValue = step.rawValue
        self.skippedStartDate = skippedStartDate
        self.skippedReminder = skippedReminder
        self.skippedCountdown = skippedCountdown
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

@Model
final class OnboardingBackfillState {
    static let fixedKey = "v7-to-v8-onboarding"

    @Attribute(.unique) var taskKey: String
    var sourceRawValue: String
    var completedAt: Date?
    var updatedAt: Date

    var source: OnboardingBackfillSource? {
        OnboardingBackfillSource(rawValue: sourceRawValue)
    }

    init(
        taskKey: String = OnboardingBackfillState.fixedKey,
        source: OnboardingBackfillSource,
        completedAt: Date?,
        updatedAt: Date
    ) {
        self.taskKey = taskKey
        self.sourceRawValue = source.rawValue
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

enum OnboardingDigestV1 {
    static func progress(
        _ value: OnboardingProgressRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("completedAt", try optionalTimestamp(value.completedAt)),
            .init(
                "contractVersion",
                .integer(Int64(value.contractVersion))
            ),
            .init("singletonKey", .string(value.singletonKey)),
            .init("skippedCountdown", .bool(value.skippedCountdown)),
            .init("skippedReminder", .bool(value.skippedReminder)),
            .init("skippedStartDate", .bool(value.skippedStartDate)),
            .init("step", .string(value.stepRawValue)),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(value.updatedAt)
            )
        ]
    }

    static func backfillState(
        _ value: OnboardingBackfillState
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("completedAt", try optionalTimestamp(value.completedAt)),
            .init("source", .string(value.sourceRawValue)),
            .init("taskKey", .string(value.taskKey)),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(value.updatedAt)
            )
        ]
    }

    private static func optionalTimestamp(
        _ value: Date?
    ) throws -> RecordDigestV1.Value {
        try value.map(RecordDigestV1.timestampValue) ?? .null
    }
}

enum OnboardingRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        var preferenceDescriptor = FetchDescriptor<UserPreferencesRecord>()
        preferenceDescriptor.fetchLimit = 2
        var progressDescriptor = FetchDescriptor<OnboardingProgressRecord>()
        progressDescriptor.fetchLimit = 2
        var stateDescriptor = FetchDescriptor<OnboardingBackfillState>()
        stateDescriptor.fetchLimit = 2

        let preferences = try context.fetch(preferenceDescriptor)
        let progressRecords = try context.fetch(progressDescriptor)
        let states = try context.fetch(stateDescriptor)
        guard preferences.count == 1,
              progressRecords.count == 1,
              states.count == 1,
              let preference = preferences.first,
              let progress = progressRecords.first,
              let state = states.first,
              validates(progress),
              validates(state),
              preference.onboardingCompleted
                == (progress.step == .completed),
              (progress.step == .completed)
                == (progress.completedAt != nil) else {
            throw failure
        }
    }

    static func validates(_ value: OnboardingProgressRecord) -> Bool {
        guard value.singletonKey == OnboardingProgressRecord.fixedKey,
              value.contractVersion
                == OnboardingProgressRecord.contractVersion,
              let step = value.step,
              value.updatedAt.timeIntervalSince1970.isFinite,
              value.completedAt?.timeIntervalSince1970.isFinite != false else {
            return false
        }
        return step == .completed
            ? value.completedAt != nil
            : value.completedAt == nil
    }

    static func validates(_ value: OnboardingBackfillState) -> Bool {
        value.taskKey == OnboardingBackfillState.fixedKey
            && value.source != nil
            && value.completedAt?.timeIntervalSince1970.isFinite == true
            && value.updatedAt.timeIntervalSince1970.isFinite
    }
}
