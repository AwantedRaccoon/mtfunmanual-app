import Foundation
import SwiftData

enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static let models: [any PersistentModel.Type] = [
        HRTProfile.self,
        CountdownRecord.self,
        RegimenVersion.self,
        JourneyEntry.self,
        LabRecord.self
    ]
}

enum AppSchemaV2Bridge: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static let models: [any PersistentModel.Type] = AppSchemaV1.models + [
        DatasetMetadata.self,
        MigrationBackfillState.self,
        RecordRevision.self,
        MigrationIssue.self
    ]
}

enum AppSchemaV3Core: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static let models: [any PersistentModel.Type] = AppSchemaV2Bridge.models + [
        UserPreferencesRecord.self,
        HrtJourneyProfileRecord.self,
        HrtPeriodRecord.self,
        RegimenPlanVersionRecord.self,
        RegimenItemRecord.self,
        ScheduleRuleRecord.self,
        HistoricalTimeRecord.self,
        CoreTimeRegimenBackfillState.self
    ]
}

enum AppSchemaV4TodayExecution: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static let models: [any PersistentModel.Type] = AppSchemaV3Core.models + [
        AdministrationEventRecord.self,
        OperationReceiptRecord.self,
        OperationReceiptLedgerRecord.self,
        ReminderOverrideRecord.self,
        ReminderPreferenceRecord.self,
        NotificationCoverageRecord.self,
        TodayExecutionBackfillState.self
    ]
}

enum AppSchemaV5PersonalTimeline: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static let models: [any PersistentModel.Type] = AppSchemaV4TodayExecution.models + [
        LabItemDefinitionRecord.self,
        LabSampleRecord.self,
        LabResultRecord.self,
        StatusMetricDefinitionRecord.self,
        StatusObservationRecord.self,
        AttachmentRecord.self,
        PersonalTimelineBackfillState.self
    ]
}

enum AppSchemaV6CountdownLifecycle: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static let models: [any PersistentModel.Type] = AppSchemaV5PersonalTimeline.models + [
        CountdownStateRecord.self,
        CountdownLifecycleEventRecord.self,
        CountdownReminderRuleRecord.self,
        CountdownNotificationCoverageRecord.self,
        CountdownLifecycleBackfillState.self
    ]
}

enum AppSchemaV7CountdownIntegrity: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static let models: [any PersistentModel.Type] =
        AppSchemaV6CountdownLifecycle.models + [
            CountdownCommandAuditRecord.self,
            CountdownV6AuditCheckpointRecord.self,
            CountdownIntegrityBackfillState.self
        ]
}

enum AppSchemaV8Onboarding: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static let models: [any PersistentModel.Type] =
        AppSchemaV7CountdownIntegrity.models + [
            OnboardingProgressRecord.self,
            OnboardingBackfillState.self
        ]
}

enum AppSchemaV9HrtJourneyLifecycle: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static let models: [any PersistentModel.Type] =
        AppSchemaV8Onboarding.models + [
            HrtJourneyLifecycleEventRecord.self,
            HrtJourneyLifecycleBackfillState.self
        ]
}

enum AppSchemaV10ParentRecordLifecycle: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    static let models: [any PersistentModel.Type] =
        AppSchemaV9HrtJourneyLifecycle.models + [
            ParentRecordLifecycleHeadRecord.self,
            ParentRecordMutationEventRecord.self,
            LabSampleCorrectionSnapshotRecord.self,
            LabResultCorrectionSnapshotRecord.self,
            StatusObservationCorrectionSnapshotRecord.self,
            ParentRecordDeletionTombstoneRecord.self,
            ParentRecordLifecycleBackfillState.self
        ]
}

enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        AppSchemaV1.self,
        AppSchemaV2Bridge.self,
        AppSchemaV3Core.self,
        AppSchemaV4TodayExecution.self,
        AppSchemaV5PersonalTimeline.self,
        AppSchemaV6CountdownLifecycle.self,
        AppSchemaV7CountdownIntegrity.self,
        AppSchemaV8Onboarding.self,
        AppSchemaV9HrtJourneyLifecycle.self,
        AppSchemaV10ParentRecordLifecycle.self
    ]

    static let stages: [MigrationStage] = [
        .lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2Bridge.self),
        .lightweight(fromVersion: AppSchemaV2Bridge.self, toVersion: AppSchemaV3Core.self),
        .lightweight(fromVersion: AppSchemaV3Core.self, toVersion: AppSchemaV4TodayExecution.self),
        .lightweight(
            fromVersion: AppSchemaV4TodayExecution.self,
            toVersion: AppSchemaV5PersonalTimeline.self
        ),
        .lightweight(
            fromVersion: AppSchemaV5PersonalTimeline.self,
            toVersion: AppSchemaV6CountdownLifecycle.self
        ),
        .lightweight(
            fromVersion: AppSchemaV6CountdownLifecycle.self,
            toVersion: AppSchemaV7CountdownIntegrity.self
        ),
        .lightweight(
            fromVersion: AppSchemaV7CountdownIntegrity.self,
            toVersion: AppSchemaV8Onboarding.self
        ),
        .lightweight(
            fromVersion: AppSchemaV8Onboarding.self,
            toVersion: AppSchemaV9HrtJourneyLifecycle.self
        ),
        .lightweight(
            fromVersion: AppSchemaV9HrtJourneyLifecycle.self,
            toVersion: AppSchemaV10ParentRecordLifecycle.self
        )
    ]
}

enum AppSchemaMigrationPlanThroughV8: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        AppSchemaV1.self,
        AppSchemaV2Bridge.self,
        AppSchemaV3Core.self,
        AppSchemaV4TodayExecution.self,
        AppSchemaV5PersonalTimeline.self,
        AppSchemaV6CountdownLifecycle.self,
        AppSchemaV7CountdownIntegrity.self,
        AppSchemaV8Onboarding.self
    ]

    static let stages: [MigrationStage] = [
        .lightweight(
            fromVersion: AppSchemaV1.self,
            toVersion: AppSchemaV2Bridge.self
        ),
        .lightweight(
            fromVersion: AppSchemaV2Bridge.self,
            toVersion: AppSchemaV3Core.self
        ),
        .lightweight(
            fromVersion: AppSchemaV3Core.self,
            toVersion: AppSchemaV4TodayExecution.self
        ),
        .lightweight(
            fromVersion: AppSchemaV4TodayExecution.self,
            toVersion: AppSchemaV5PersonalTimeline.self
        ),
        .lightweight(
            fromVersion: AppSchemaV5PersonalTimeline.self,
            toVersion: AppSchemaV6CountdownLifecycle.self
        ),
        .lightweight(
            fromVersion: AppSchemaV6CountdownLifecycle.self,
            toVersion: AppSchemaV7CountdownIntegrity.self
        ),
        .lightweight(
            fromVersion: AppSchemaV7CountdownIntegrity.self,
            toVersion: AppSchemaV8Onboarding.self
        )
    ]
}

enum AppSchemaMigrationPlanThroughV7: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        AppSchemaV1.self,
        AppSchemaV2Bridge.self,
        AppSchemaV3Core.self,
        AppSchemaV4TodayExecution.self,
        AppSchemaV5PersonalTimeline.self,
        AppSchemaV6CountdownLifecycle.self,
        AppSchemaV7CountdownIntegrity.self
    ]

    static let stages: [MigrationStage] = [
        .lightweight(
            fromVersion: AppSchemaV1.self,
            toVersion: AppSchemaV2Bridge.self
        ),
        .lightweight(
            fromVersion: AppSchemaV2Bridge.self,
            toVersion: AppSchemaV3Core.self
        ),
        .lightweight(
            fromVersion: AppSchemaV3Core.self,
            toVersion: AppSchemaV4TodayExecution.self
        ),
        .lightweight(
            fromVersion: AppSchemaV4TodayExecution.self,
            toVersion: AppSchemaV5PersonalTimeline.self
        ),
        .lightweight(
            fromVersion: AppSchemaV5PersonalTimeline.self,
            toVersion: AppSchemaV6CountdownLifecycle.self
        ),
        .lightweight(
            fromVersion: AppSchemaV6CountdownLifecycle.self,
            toVersion: AppSchemaV7CountdownIntegrity.self
        )
    ]
}

enum AppModelContainerFactory {
    static var bridgeSchema: Schema {
        Schema(versionedSchema: AppSchemaV2Bridge.self)
    }

    static var coreSchema: Schema {
        Schema(versionedSchema: AppSchemaV3Core.self)
    }

    static var todaySchema: Schema {
        Schema(versionedSchema: AppSchemaV4TodayExecution.self)
    }

    static var personalTimelineSchema: Schema {
        Schema(versionedSchema: AppSchemaV5PersonalTimeline.self)
    }

    static var onboardingSchema: Schema {
        Schema(versionedSchema: AppSchemaV8Onboarding.self)
    }

    static var countdownLifecycleSchema: Schema {
        onboardingSchema
    }

    static var hrtJourneyLifecycleSchema: Schema {
        Schema(versionedSchema: AppSchemaV9HrtJourneyLifecycle.self)
    }

    static var parentRecordLifecycleSchema: Schema {
        Schema(versionedSchema: AppSchemaV10ParentRecordLifecycle.self)
    }

    static var frozenV6CountdownLifecycleSchema: Schema {
        Schema(versionedSchema: AppSchemaV6CountdownLifecycle.self)
    }

    static var frozenV7CountdownIntegritySchema: Schema {
        Schema(versionedSchema: AppSchemaV7CountdownIntegrity.self)
    }

    static func makeV1Container(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        let configuration = ModelConfiguration(
            "UnmanualV1",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    static func makeBridgeContainer(at storeURL: URL) throws -> ModelContainer {
        try makeBridgeContainer(at: storeURL, allowsSave: true)
    }

    static func makeReadOnlyBridgeContainer(at storeURL: URL) throws -> ModelContainer {
        try makeBridgeContainer(at: storeURL, allowsSave: false)
    }

    private static func makeBridgeContainer(
        at storeURL: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = bridgeSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeInMemoryBridgeContainer() throws -> ModelContainer {
        let schema = bridgeSchema
        let configuration = ModelConfiguration(
            "UnmanualTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeCoreContainer(at storeURL: URL) throws -> ModelContainer {
        try makeCoreContainer(at: storeURL, allowsSave: true)
    }

    static func makeReadOnlyCoreContainer(at storeURL: URL) throws -> ModelContainer {
        try makeCoreContainer(at: storeURL, allowsSave: false)
    }

    private static func makeCoreContainer(
        at storeURL: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = coreSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeInMemoryCoreContainer() throws -> ModelContainer {
        let schema = coreSchema
        let configuration = ModelConfiguration(
            "UnmanualCoreTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeTodayContainer(at storeURL: URL) throws -> ModelContainer {
        try makeTodayContainer(at: storeURL, allowsSave: true)
    }

    static func makeReadOnlyTodayContainer(at storeURL: URL) throws -> ModelContainer {
        try makeTodayContainer(at: storeURL, allowsSave: false)
    }

    private static func makeTodayContainer(
        at storeURL: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = todaySchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeInMemoryTodayContainer() throws -> ModelContainer {
        let schema = todaySchema
        let configuration = ModelConfiguration(
            "UnmanualTodayTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makePersonalTimelineContainer(at storeURL: URL) throws -> ModelContainer {
        try makePersonalTimelineContainer(at: storeURL, allowsSave: true)
    }

    static func makeReadOnlyPersonalTimelineContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        try makePersonalTimelineContainer(at: storeURL, allowsSave: false)
    }

    private static func makePersonalTimelineContainer(
        at storeURL: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = personalTimelineSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeInMemoryPersonalTimelineContainer() throws -> ModelContainer {
        let schema = personalTimelineSchema
        let configuration = ModelConfiguration(
            "UnmanualPersonalTimelineTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeCountdownLifecycleContainer(at storeURL: URL) throws -> ModelContainer {
        try makeCountdownLifecycleContainer(at: storeURL, allowsSave: true)
    }

    static func makeReadOnlyCountdownLifecycleContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        try makeCountdownLifecycleContainer(at: storeURL, allowsSave: false)
    }

    private static func makeCountdownLifecycleContainer(
        at storeURL: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = countdownLifecycleSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeInMemoryCountdownLifecycleContainer() throws -> ModelContainer {
        let schema = countdownLifecycleSchema
        let configuration = ModelConfiguration(
            "UnmanualCountdownLifecycleTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeHrtJourneyLifecycleContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        try makeHrtJourneyLifecycleContainer(
            at: storeURL,
            allowsSave: true
        )
    }

    static func makeReadOnlyHrtJourneyLifecycleContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        try makeHrtJourneyLifecycleContainer(
            at: storeURL,
            allowsSave: false
        )
    }

    private static func makeHrtJourneyLifecycleContainer(
        at storeURL: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = hrtJourneyLifecycleSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeInMemoryHrtJourneyLifecycleContainer()
        throws -> ModelContainer {
        let schema = hrtJourneyLifecycleSchema
        let configuration = ModelConfiguration(
            "UnmanualHrtJourneyLifecycleTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeParentRecordLifecycleContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        try makeParentRecordLifecycleContainer(
            at: storeURL,
            allowsSave: true
        )
    }

    static func makeReadOnlyParentRecordLifecycleContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        try makeParentRecordLifecycleContainer(
            at: storeURL,
            allowsSave: false
        )
    }

    private static func makeParentRecordLifecycleContainer(
        at storeURL: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = parentRecordLifecycleSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeInMemoryParentRecordLifecycleContainer()
        throws -> ModelContainer {
        let schema = parentRecordLifecycleSchema
        let configuration = ModelConfiguration(
            "UnmanualParentRecordLifecycleTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func makeV8OnboardingContainer(
        at storeURL: URL,
        allowsSave: Bool = true
    ) throws -> ModelContainer {
        let schema = onboardingSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlanThroughV8.self,
            configurations: [configuration]
        )
    }

    static func makeV6CountdownLifecycleContainer(
        at storeURL: URL,
        allowsSave: Bool = true
    ) throws -> ModelContainer {
        let schema = frozenV6CountdownLifecycleSchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlanThroughV7.self,
            configurations: [configuration]
        )
    }

    static func makeV7CountdownIntegrityContainer(
        at storeURL: URL,
        allowsSave: Bool = true
    ) throws -> ModelContainer {
        let schema = frozenV7CountdownIntegritySchema
        let configuration = ModelConfiguration(
            "Unmanual",
            schema: schema,
            url: storeURL,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlanThroughV7.self,
            configurations: [configuration]
        )
    }
}
