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

enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        AppSchemaV1.self,
        AppSchemaV2Bridge.self,
        AppSchemaV3Core.self
    ]

    static let stages: [MigrationStage] = [
        .lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2Bridge.self),
        .lightweight(fromVersion: AppSchemaV2Bridge.self, toVersion: AppSchemaV3Core.self)
    ]
}

enum AppModelContainerFactory {
    static var bridgeSchema: Schema {
        Schema(versionedSchema: AppSchemaV2Bridge.self)
    }

    static var coreSchema: Schema {
        Schema(versionedSchema: AppSchemaV3Core.self)
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
}
