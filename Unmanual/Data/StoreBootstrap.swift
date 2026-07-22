import Foundation
import SwiftData

struct AppDataStoreLayout: Equatable, Sendable {
    let rootURL: URL
    let legacyStoreURL: URL

    var generationsURL: URL {
        rootURL.appending(path: "Generations", directoryHint: .isDirectory)
    }

    var pointerDirectoryURL: URL {
        rootURL.appending(path: "GenerationPointer", directoryHint: .isDirectory)
    }

    var pointerURL: URL {
        pointerDirectoryURL.appending(path: "active.json")
    }

    var recoveryURL: URL {
        rootURL.appending(path: "Recovery", directoryHint: .isDirectory)
    }

    var journalURL: URL {
        recoveryURL.appending(path: "migration-journal.json")
    }

    func generationDirectoryURL(for id: UUID) -> URL {
        generationsURL.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    func storeDirectoryURL(for id: UUID) -> URL {
        generationDirectoryURL(for: id).appending(path: "Store", directoryHint: .isDirectory)
    }

    func storeURL(for id: UUID) -> URL {
        storeDirectoryURL(for: id).appending(path: "user.sqlite")
    }

    func protectionResources(for generationID: UUID) -> [StoreFileProtectionResource] {
        [
            StoreFileProtectionResource(role: .rootDirectory, url: rootURL),
            StoreFileProtectionResource(role: .generationsDirectory, url: generationsURL),
            StoreFileProtectionResource(role: .pointerDirectory, url: pointerDirectoryURL),
            StoreFileProtectionResource(role: .recoveryDirectory, url: recoveryURL),
            StoreFileProtectionResource(
                role: .generationDirectory,
                url: generationDirectoryURL(for: generationID)
            ),
            StoreFileProtectionResource(
                role: .storeDirectory,
                url: storeDirectoryURL(for: generationID)
            ),
            StoreFileProtectionResource(role: .pointer, url: pointerURL),
            StoreFileProtectionResource(role: .journal, url: journalURL)
        ]
    }

    static func production(fileManager: FileManager = .default) throws -> AppDataStoreLayout {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport.appending(path: "Unmanual", directoryHint: .isDirectory)
        let legacySchema = Schema(versionedSchema: AppSchemaV1.self)
        let legacyConfiguration = ModelConfiguration(
            schema: legacySchema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return AppDataStoreLayout(rootURL: root, legacyStoreURL: legacyConfiguration.url)
    }
}

enum CoreRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure,
        administrationEventIDs: Set<UUID> = []
    ) throws {
        let preferences = try context.fetch(FetchDescriptor<UserPreferencesRecord>())
        guard preferences.count == 1,
              preferences[0].singletonKey == UserPreferencesRecord.fixedKey else {
            throw failure
        }

        let versions = try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>())
        let versionGroups = Dictionary(grouping: versions, by: \.id)
        guard versionGroups.values.allSatisfy({ $0.count == 1 }),
              versions.allSatisfy({ version in
                  guard RegimenEditState(rawValue: version.editStateRawValue) != nil,
                        let start = version.effectiveStartDate,
                        (version.effectiveEndYear == nil
                            && version.effectiveEndMonth == nil
                            && version.effectiveEndDay == nil)
                            || version.effectiveEndDate != nil else {
                      return false
                  }
                  return version.effectiveEndDate.map { start < $0 } ?? true
              }) else {
            throw failure
        }
        let versionsByID = versionGroups.compactMapValues(\.first)
        guard versions.allSatisfy({ version in
            guard let previousID = version.previousVersionID else { return true }
            return previousID != version.id && versionsByID[previousID] != nil
        }) else {
            throw failure
        }
        for version in versions {
            var visited: Set<UUID> = [version.id]
            var cursor = version.previousVersionID
            while let id = cursor {
                guard visited.insert(id).inserted,
                      let predecessor = versionsByID[id] else {
                    throw failure
                }
                cursor = predecessor.previousVersionID
            }
        }
        let eligibleSealed = versions.filter {
            $0.editState == .sealed && !$0.isArchived && !$0.requiresMigrationReview
        }
        for version in versions where !version.isArchived && !version.requiresMigrationReview {
            guard let start = version.effectiveStartDate else { throw failure }
            let expectedPreviousID = eligibleSealed
                .filter {
                    $0.id != version.id
                        && ($0.effectiveStartDate.map { $0 < start } ?? false)
                }
                .sorted(by: stableVersionOrder)
                .last?
                .id
            guard version.previousVersionID == expectedPreviousID else {
                throw failure
            }
        }

        let versionIDs = Set(versions.map(\.id))
        let items = try context.fetch(FetchDescriptor<RegimenItemRecord>())
        let itemGroups = Dictionary(grouping: items, by: \.id)
        guard itemGroups.values.allSatisfy({ $0.count == 1 }),
              items.allSatisfy({ versionIDs.contains($0.regimenVersionID) }) else {
            throw failure
        }
        let itemIDs = Set(items.map(\.id))
        let rules = try context.fetch(FetchDescriptor<ScheduleRuleRecord>())
        guard rules.allSatisfy({ itemIDs.contains($0.regimenItemID) }),
              Dictionary(grouping: rules, by: \.regimenItemID)
                  .values
                  .allSatisfy({ $0.count <= 1 }) else {
            throw failure
        }

        let journeyIDs = Set(try context.fetch(FetchDescriptor<JourneyEntry>()).map(\.id))
        let labIDs = Set(try context.fetch(FetchDescriptor<LabRecord>()).map(\.id))
        let times = try context.fetch(FetchDescriptor<HistoricalTimeRecord>())
        guard times.allSatisfy({ time in
            guard time.recordKey
                    == time.sourceRecordType + ":" + time.sourceRecordID.uuidString.lowercased(),
                  time.historicalTimestamp != nil,
                  let state = HistoricalAssociationState(rawValue: time.associationStateRawValue)
            else {
                return false
            }
            let sourceExists: Bool
            switch time.sourceRecordType {
            case "JourneyEntry":
                sourceExists = journeyIDs.contains(time.sourceRecordID)
            case "LabRecord":
                sourceExists = labIDs.contains(time.sourceRecordID)
            case "AdministrationEventRecord":
                sourceExists = administrationEventIDs.contains(time.sourceRecordID)
            default:
                sourceExists = false
            }
            guard sourceExists else { return false }
            switch state {
            case .resolved:
                guard let resolvedID = time.resolvedRegimenVersionID else { return false }
                return versionIDs.contains(resolvedID)
            case .missing, .ambiguous:
                return time.resolvedRegimenVersionID == nil
            }
        }) else {
            throw failure
        }
    }

    private static func stableVersionOrder(
        _ lhs: RegimenPlanVersionRecord,
        _ rhs: RegimenPlanVersionRecord
    ) -> Bool {
        guard let lhsStart = lhs.effectiveStartDate,
              let rhsStart = rhs.effectiveStartDate else {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhsStart != rhsStart
            ? lhsStart < rhsStart
            : lhs.id.uuidString < rhs.id.uuidString
    }
}

enum SystemBackupPolicy: String, Codable, Equatable, Sendable {
    case systemManaged
    case excluded

    /// App 1.0 keeps records in the app-private container and lets iOS apply
    /// the user's system backup settings. This does not enable CloudKit or
    /// app-initiated synchronization.
    static let production: Self = .systemManaged
}

enum SystemBackupDisclosure {
    static let statusLabel = "本地保存"
    static let summary = "记录保存在 App 私有存储中，不要求账号。"
    static let networkBoundary = "App 不使用 CloudKit，不主动上传，也不实时同步到其他设备。"
    static let systemBackupBoundary = "iOS 可能按你的设置将 App 数据纳入 iCloud 或电脑的系统备份；App 不保证每次备份或恢复成功。"
    static let compact = "App 不主动上传或同步；iOS 可能按系统设置将 App 数据纳入系统备份。通知只在当前设备安排。"
    static let quickRecord = "这条记录保存在 App 私有存储中；iOS 可能纳入系统备份"
    static let todayAccessibility = "今天页，记录保存在 App 私有存储中；App 不主动上传，iOS 可能纳入系统备份"
}

enum AppDataStoreOrigin: String, Codable, Equatable, Sendable {
    case newInstall
    case legacyAdoption
    case existingGeneration
    case schemaUpgrade
}

struct GenerationPointer: Codable, Equatable, Sendable {
    static let formatVersion = 2

    let formatVersion: Int
    let generationID: UUID
    let schemaVersion: String
    let origin: AppDataStoreOrigin
    let datasetID: UUID
    let minimumFactCount: Int
    let minimumRevisionCount: Int
    let activatedAt: Date

    init(
        generationID: UUID,
        schemaVersion: String = "4.0.0",
        origin: AppDataStoreOrigin,
        datasetID: UUID,
        minimumFactCount: Int,
        minimumRevisionCount: Int,
        activatedAt: Date = Date()
    ) {
        self.formatVersion = Self.formatVersion
        self.generationID = generationID
        self.schemaVersion = schemaVersion
        self.origin = origin
        self.datasetID = datasetID
        self.minimumFactCount = minimumFactCount
        self.minimumRevisionCount = minimumRevisionCount
        self.activatedAt = activatedAt
    }
}

enum MigrationJournalPhase: String, Codable, Equatable, Sendable {
    case preparing
    case prepared
    case validated
    case activated
}

struct MigrationJournal: Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let operationID: UUID
    var targetGenerationID: UUID
    let origin: AppDataStoreOrigin
    let sourceGenerationID: UUID?
    let sourceSchemaVersion: String?
    let targetSchemaVersion: String?
    var phase: MigrationJournalPhase
    var updatedAt: Date

    init(
        operationID: UUID = UUID(),
        targetGenerationID: UUID,
        origin: AppDataStoreOrigin,
        sourceGenerationID: UUID? = nil,
        sourceSchemaVersion: String? = nil,
        targetSchemaVersion: String? = nil,
        phase: MigrationJournalPhase = .preparing,
        updatedAt: Date = Date()
    ) {
        self.formatVersion = Self.formatVersion
        self.operationID = operationID
        self.targetGenerationID = targetGenerationID
        self.origin = origin
        self.sourceGenerationID = sourceGenerationID
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

struct GenerationPointerStore: Sendable {
    let layout: AppDataStoreLayout
    let backupPolicy: SystemBackupPolicy

    init(layout: AppDataStoreLayout, backupPolicy: SystemBackupPolicy = .production) {
        self.layout = layout
        self.backupPolicy = backupPolicy
    }

    func read() throws -> GenerationPointer {
        guard FileManager.default.fileExists(atPath: layout.pointerURL.path) else {
            throw AppDataFailure.invalidGenerationPointer
        }
        do {
            let pointer = try JSONDecoder.unmanualFoundation.decode(
                GenerationPointer.self,
                from: Data(contentsOf: layout.pointerURL)
            )
            guard pointer.formatVersion == GenerationPointer.formatVersion,
                  ["2.0.0", "3.0.0", "4.0.0"].contains(pointer.schemaVersion),
                  pointer.minimumFactCount >= 0,
                  pointer.minimumRevisionCount >= 0,
                  pointer.minimumFactCount == pointer.minimumRevisionCount,
                  pointer.activatedAt.timeIntervalSince1970.isFinite else {
                throw AppDataFailure.invalidGenerationPointer
            }
            return pointer
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .invalidGenerationPointer)
        }
    }

    func write(_ pointer: GenerationPointer) throws {
        try ProtectedAtomicJSONWriter(backupPolicy: backupPolicy)
            .write(pointer, to: layout.pointerURL)
    }
}

struct MigrationJournalStore: Sendable {
    let layout: AppDataStoreLayout
    let backupPolicy: SystemBackupPolicy

    init(layout: AppDataStoreLayout, backupPolicy: SystemBackupPolicy = .production) {
        self.layout = layout
        self.backupPolicy = backupPolicy
    }

    func read() throws -> MigrationJournal {
        guard FileManager.default.fileExists(atPath: layout.journalURL.path) else {
            throw AppDataFailure.migrationFailed
        }
        do {
            let journal = try JSONDecoder.unmanualFoundation.decode(
                MigrationJournal.self,
                from: Data(contentsOf: layout.journalURL)
            )
            guard journal.formatVersion == MigrationJournal.formatVersion,
                  journal.origin != .existingGeneration,
                  (journal.origin != .schemaUpgrade
                      || (journal.sourceGenerationID != nil
                          && ((journal.sourceSchemaVersion == "2.0.0"
                                && journal.targetSchemaVersion == "3.0.0")
                            || (journal.sourceSchemaVersion == "3.0.0"
                                && journal.targetSchemaVersion == "4.0.0")))),
                  journal.updatedAt.timeIntervalSince1970.isFinite else {
                throw AppDataFailure.migrationFailed
            }
            return journal
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .migrationFailed)
        }
    }

    func readIfPresent() throws -> MigrationJournal? {
        guard FileManager.default.fileExists(atPath: layout.journalURL.path) else { return nil }
        return try read()
    }

    func write(_ journal: MigrationJournal) throws {
        try ProtectedAtomicJSONWriter(backupPolicy: backupPolicy)
            .write(journal, to: layout.journalURL)
    }
}

enum StoreBootstrapFailpoint: Equatable, Sendable {
    case duringLegacyBundleCopyAfterMain
    case afterGenerationPrepared
    case afterValidationBeforePointer
    case duringValidationWithNestedProtectedDataError
}

enum StoreBootstrapInterruption: Error, Equatable {
    case injected
}

struct BootstrappedAppDataStore {
    let container: ModelContainer
    let generationID: UUID
    let storeURL: URL
    let origin: AppDataStoreOrigin
    let protectionReport: StoreFileProtectionReport
    let protectionPlan: StoreFileProtectionPlan?

    init(
        container: ModelContainer,
        generationID: UUID,
        storeURL: URL,
        origin: AppDataStoreOrigin,
        protectionReport: StoreFileProtectionReport,
        protectionPlan: StoreFileProtectionPlan? = nil
    ) {
        self.container = container
        self.generationID = generationID
        self.storeURL = storeURL
        self.origin = origin
        self.protectionReport = protectionReport
        self.protectionPlan = protectionPlan
    }
}

struct AppDataStoreBootstrapper {
    let layout: AppDataStoreLayout
    let backupPolicy: SystemBackupPolicy
    private let fileManager: FileManager
    private let fileProtectionVerificationMode: StoreFileProtectionVerificationMode

    init(
        layout: AppDataStoreLayout,
        backupPolicy: SystemBackupPolicy = .production,
        fileManager: FileManager = .default,
        fileProtectionVerificationMode: StoreFileProtectionVerificationMode = .live
    ) {
        self.layout = layout
        self.backupPolicy = backupPolicy
        self.fileManager = fileManager
        self.fileProtectionVerificationMode = fileProtectionVerificationMode
    }

    func open(failAt failpoint: StoreBootstrapFailpoint? = nil) throws -> BootstrappedAppDataStore {
        try prepareDirectories()
        let pointerStore = GenerationPointerStore(layout: layout, backupPolicy: backupPolicy)
        let journalStore = MigrationJournalStore(layout: layout, backupPolicy: backupPolicy)

        if fileManager.fileExists(atPath: layout.pointerURL.path) {
            let pointer = try pointerStore.read()
            let targetURL = layout.storeURL(for: pointer.generationID)
            guard fileManager.fileExists(atPath: targetURL.path) else {
                throw AppDataFailure.invalidGenerationPointer
            }
            if pointer.origin == .legacyAdoption {
                // A validated pointer proves the preserved legacy bundle was
                // copied before activation. Reconcile its metadata on every
                // later open so a policy change cannot leave that recovery
                // source under the previous backup policy.
                try hardenPreservedLegacyBundle(at: layout.legacyStoreURL)
            }
            if pointer.schemaVersion == "2.0.0" {
                return try upgradeV2Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "3.0.0" {
                return try upgradeV3Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            return try openActive(pointer: pointer, reportedOrigin: .existingGeneration)
        }

        if var journal = try journalStore.readIfPresent() {
            if journal.phase == .preparing {
                journal.targetGenerationID = UUID()
                journal.updatedAt = Date()
                try journalStore.write(journal)
                try prepareGeneration(journal.targetGenerationID)
                if journal.origin == .legacyAdoption {
                    guard fileManager.fileExists(atPath: layout.legacyStoreURL.path) else {
                        throw AppDataFailure.migrationFailed
                    }
                    try copyStoreBundle(
                        from: layout.legacyStoreURL,
                        to: layout.storeURL(for: journal.targetGenerationID),
                        failAt: failpoint,
                        hardenSourceAfterCopy: true
                    )
                }
                journal.phase = .prepared
                journal.updatedAt = Date()
                try journalStore.write(journal)
                if failpoint == .afterGenerationPrepared {
                    throw StoreBootstrapInterruption.injected
                }
            }
            let targetURL = layout.storeURL(for: journal.targetGenerationID)
            if !fileManager.fileExists(atPath: targetURL.path) {
                guard journal.origin == .newInstall,
                      journal.phase == .prepared else {
                    throw AppDataFailure.migrationFailed
                }
            }
            let identity = try validateAndBackfillToday(storeURL: targetURL, failAt: failpoint)
            journal.phase = .validated
            journal.updatedAt = Date()
            try journalStore.write(journal)
            if failpoint == .afterValidationBeforePointer {
                throw StoreBootstrapInterruption.injected
            }
            try pointerStore.write(
                GenerationPointer(
                    generationID: journal.targetGenerationID,
                    origin: journal.origin,
                    datasetID: identity.datasetID,
                    minimumFactCount: identity.factCount,
                    minimumRevisionCount: identity.revisionCount
                )
            )
            journal.phase = .activated
            journal.updatedAt = Date()
            try journalStore.write(journal)
            return try openActive(
                pointer: GenerationPointer(
                    generationID: journal.targetGenerationID,
                    origin: journal.origin,
                    datasetID: identity.datasetID,
                    minimumFactCount: identity.factCount,
                    minimumRevisionCount: identity.revisionCount
                ),
                reportedOrigin: journal.origin
            )
        }

        if try containsUnresolvedGenerationEvidence() {
            throw AppDataFailure.invalidGenerationPointer
        }
        let legacyBundlePresence = existingStoreBundleParts(at: layout.legacyStoreURL)
        if !legacyBundlePresence.main,
           legacyBundlePresence.wal || legacyBundlePresence.shm {
            throw AppDataFailure.corruptionSuspected
        }

        let generationID = UUID()
        let hasLegacyStore = legacyBundlePresence.main
        let origin: AppDataStoreOrigin = hasLegacyStore ? .legacyAdoption : .newInstall
        var journal = MigrationJournal(
            targetGenerationID: generationID,
            origin: origin
        )
        try journalStore.write(journal)
        try prepareGeneration(generationID)

        if hasLegacyStore {
            try copyStoreBundle(
                from: layout.legacyStoreURL,
                to: layout.storeURL(for: generationID),
                failAt: failpoint,
                hardenSourceAfterCopy: true
            )
        }
        journal.phase = .prepared
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterGenerationPrepared {
            throw StoreBootstrapInterruption.injected
        }

        let identity = try validateAndBackfillToday(
            storeURL: layout.storeURL(for: generationID),
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        try pointerStore.write(
            GenerationPointer(
                generationID: generationID,
                origin: origin,
                datasetID: identity.datasetID,
                minimumFactCount: identity.factCount,
                minimumRevisionCount: identity.revisionCount
            )
        )
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try openActive(
            pointer: GenerationPointer(
                generationID: generationID,
                origin: origin,
                datasetID: identity.datasetID,
                minimumFactCount: identity.factCount,
                minimumRevisionCount: identity.revisionCount
            ),
            reportedOrigin: origin
        )
    }

    private func upgradeV2Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateV2StoreBeforeUpgrade(at: sourceURL)
        guard sourceIdentity.datasetID == pointer.datasetID,
              sourceIdentity.factCount >= pointer.minimumFactCount,
              sourceIdentity.revisionCount >= pointer.minimumRevisionCount else {
            throw AppDataFailure.corruptionSuspected
        }

        var journal: MigrationJournal
        if let existing = try journalStore.readIfPresent(),
           existing.origin == .schemaUpgrade,
           existing.sourceGenerationID == pointer.generationID {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "2.0.0",
                targetSchemaVersion: "3.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal || targetPresence.shm {
                journal.targetGenerationID = UUID()
                journal.updatedAt = Date()
                try journalStore.write(journal)
            }
            try prepareGeneration(journal.targetGenerationID)
            try copyStoreBundle(
                from: sourceURL,
                to: layout.storeURL(for: journal.targetGenerationID),
                failAt: failpoint,
                hardenSourceAfterCopy: false
            )
            journal.phase = .prepared
            journal.updatedAt = Date()
            try journalStore.write(journal)
            if failpoint == .afterGenerationPrepared {
                throw StoreBootstrapInterruption.injected
            }
        }

        let targetURL = layout.storeURL(for: journal.targetGenerationID)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw AppDataFailure.migrationFailed
        }
        let identity = try validateAndBackfillCore(storeURL: targetURL, failAt: failpoint)
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "3.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV3Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV3Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "3.0.0"
        )
        guard sourceIdentity.datasetID == pointer.datasetID,
              sourceIdentity.factCount >= pointer.minimumFactCount,
              sourceIdentity.revisionCount >= pointer.minimumRevisionCount else {
            throw AppDataFailure.corruptionSuspected
        }

        var journal: MigrationJournal
        if let existing = try journalStore.readIfPresent(),
           existing.origin == .schemaUpgrade,
           existing.sourceGenerationID == pointer.generationID,
           existing.sourceSchemaVersion == "3.0.0",
           existing.targetSchemaVersion == "4.0.0" {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "3.0.0",
                targetSchemaVersion: "4.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal || targetPresence.shm {
                journal.targetGenerationID = UUID()
                journal.updatedAt = Date()
                try journalStore.write(journal)
            }
            try prepareGeneration(journal.targetGenerationID)
            try copyStoreBundle(
                from: sourceURL,
                to: layout.storeURL(for: journal.targetGenerationID),
                failAt: failpoint,
                hardenSourceAfterCopy: false
            )
            journal.phase = .prepared
            journal.updatedAt = Date()
            try journalStore.write(journal)
            if failpoint == .afterGenerationPrepared {
                throw StoreBootstrapInterruption.injected
            }
        }

        let targetURL = layout.storeURL(for: journal.targetGenerationID)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw AppDataFailure.migrationFailed
        }
        let identity = try validateAndBackfillToday(storeURL: targetURL, failAt: failpoint)
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "4.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try openActive(pointer: upgradedPointer, reportedOrigin: .schemaUpgrade)
    }

    private struct GenerationIdentity {
        let datasetID: UUID
        let factCount: Int
        let revisionCount: Int
    }

    private func validateAndBackfillCore(
        storeURL: URL,
        failAt failpoint: StoreBootstrapFailpoint? = nil
    ) throws -> GenerationIdentity {
        do {
            if failpoint == .duringValidationWithNestedProtectedDataError {
                let permissionError = NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadNoPermissionError
                )
                throw NSError(
                    domain: "SwiftData.Error",
                    code: 1,
                    userInfo: [NSUnderlyingErrorKey: permissionError]
                )
            }
            try autoreleasepool {
                let container = try AppModelContainerFactory.makeCoreContainer(at: storeURL)
                let outcome = try LegacyV1Backfill.run(in: container)
                guard outcome.didComplete else { throw AppDataFailure.migrationFailed }
                let coreOutcome = try CoreTimeRegimenBackfill.run(in: container)
                guard coreOutcome.didComplete else { throw AppDataFailure.migrationFailed }
                let context = ModelContext(container)
                _ = try validateFoundation(
                    in: context,
                    failure: .migrationFailed,
                    includesCoreFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory.makeCoreContainer(at: storeURL)
                let context = ModelContext(reopened)
                return try validateFoundation(
                    in: context,
                    failure: .migrationFailed,
                    includesCoreFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .migrationFailed)
        }
    }

    private func validateAndBackfillToday(
        storeURL: URL,
        failAt failpoint: StoreBootstrapFailpoint? = nil
    ) throws -> GenerationIdentity {
        do {
            if failpoint == .duringValidationWithNestedProtectedDataError {
                let permissionError = NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadNoPermissionError
                )
                throw NSError(
                    domain: "SwiftData.Error",
                    code: 1,
                    userInfo: [NSUnderlyingErrorKey: permissionError]
                )
            }
            try autoreleasepool {
                let container = try AppModelContainerFactory.makeTodayContainer(at: storeURL)
                let legacyOutcome = try LegacyV1Backfill.run(in: container)
                guard legacyOutcome.didComplete else { throw AppDataFailure.migrationFailed }
                let coreOutcome = try CoreTimeRegimenBackfill.run(in: container)
                guard coreOutcome.didComplete else { throw AppDataFailure.migrationFailed }
                let todayOutcome = try TodayExecutionBackfill.run(in: container)
                guard todayOutcome.didComplete else { throw AppDataFailure.migrationFailed }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory.makeTodayContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .migrationFailed)
        }
    }

    private struct FactIdentity: Hashable {
        let recordType: String
        let recordID: UUID
        let digestHex: String

        var recordKey: String {
            recordType + ":" + recordID.uuidString.lowercased()
        }
    }

    private func validateFoundation(
        in context: ModelContext,
        failure: AppDataFailure,
        includesCoreFacts: Bool = false,
        includesTodayFacts: Bool = false
    ) throws -> GenerationIdentity {
        var stateDescriptor = FetchDescriptor<MigrationBackfillState>()
        stateDescriptor.fetchLimit = 2
        let states = try context.fetch(stateDescriptor)
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadata = try context.fetch(metadataDescriptor)
        guard metadata.count == 1,
              states.count == 1,
              metadata.first?.singletonKey == DatasetMetadata.fixedKey,
              metadata.first?.digestVersion == RecordDigestV1.version,
              states.first?.taskKey == MigrationBackfillState.fixedKey,
              states.first?.phase == .complete,
              states.first?.processedCountInPhase == 0,
              states.first?.updatedAt.timeIntervalSince1970.isFinite == true,
              states.first?.completedAt?.timeIntervalSince1970.isFinite != false,
              metadata.first?.createdAt.timeIntervalSince1970.isFinite == true,
              metadata.first?.lastCommittedAt?.timeIntervalSince1970.isFinite != false,
              let datasetID = metadata.first?.datasetID else {
            throw failure
        }

        if includesCoreFacts {
            var coreStateDescriptor = FetchDescriptor<CoreTimeRegimenBackfillState>()
            coreStateDescriptor.fetchLimit = 2
            let coreStates = try context.fetch(coreStateDescriptor)
            guard coreStates.count == 1,
                  coreStates.first?.taskKey == CoreTimeRegimenBackfillState.fixedKey,
                  coreStates.first?.completedAt != nil,
                  TimeZone(identifier: coreStates[0].assumedTimeZoneIdentifier) != nil else {
                throw failure
            }
            let eventIDs: Set<UUID> = includesTodayFacts
                ? Set(try context.fetch(FetchDescriptor<AdministrationEventRecord>()).map(\.id))
                : []
            try CoreRelationshipValidator.validate(
                in: context,
                failure: failure,
                administrationEventIDs: eventIDs
            )
        }
        if includesTodayFacts {
            try TodayExecutionRelationshipValidator.validate(in: context, failure: failure)
        }

        let facts = try factIdentities(
            in: context,
            includesCoreFacts: includesCoreFacts,
            includesTodayFacts: includesTodayFacts
        )
        let revisions = try context.fetch(FetchDescriptor<RecordRevision>())
        let expectedKeys = Set(facts.map(\.recordKey))
        let actualKeys = Set(revisions.map(\.recordKey))
        guard expectedKeys.count == facts.count,
              actualKeys.count == revisions.count,
              expectedKeys == actualKeys else {
            throw failure
        }
        let expectedDigests = Dictionary(
            uniqueKeysWithValues: facts.map { ($0.recordKey, $0.digestHex) }
        )
        guard revisions.allSatisfy({ revision in
                  let expectedKey = revision.recordType
                      + ":"
                      + revision.recordID.uuidString.lowercased()
                  return revision.recordKey == expectedKey
                      && revision.datasetID == datasetID
                      && revision.localRevision > 0
                      && revision.digestVersion == RecordDigestV1.version
                      && revision.digestHex == expectedDigests[revision.recordKey]
                      && revision.committedAt.timeIntervalSince1970.isFinite
              }),
              let nextLocalRevision = metadata.first?.nextLocalRevision,
              nextLocalRevision > (revisions.map(\.localRevision).max() ?? 0),
              nextLocalRevision < Int64.max else {
            throw failure
        }
        return GenerationIdentity(
            datasetID: datasetID,
            factCount: facts.count,
            revisionCount: revisions.count
        )
    }

    private func factIdentities(
        in context: ModelContext,
        includesCoreFacts: Bool = false,
        includesTodayFacts: Bool = false
    ) throws -> [FactIdentity] {
        var facts = try context.fetch(FetchDescriptor<HRTProfile>()).map {
            FactIdentity(recordType: "HRTProfile", recordID: $0.id, digestHex: try FactDigestV1.digest($0))
        } + context.fetch(FetchDescriptor<CountdownRecord>()).map {
            FactIdentity(recordType: "CountdownRecord", recordID: $0.id, digestHex: try FactDigestV1.digest($0))
        } + context.fetch(FetchDescriptor<RegimenVersion>()).map {
            FactIdentity(recordType: "RegimenVersion", recordID: $0.id, digestHex: try FactDigestV1.digest($0))
        } + context.fetch(FetchDescriptor<JourneyEntry>()).map {
            FactIdentity(recordType: "JourneyEntry", recordID: $0.id, digestHex: try FactDigestV1.digest($0))
        } + context.fetch(FetchDescriptor<LabRecord>()).map {
            FactIdentity(recordType: "LabRecord", recordID: $0.id, digestHex: try FactDigestV1.digest($0))
        }
        guard includesCoreFacts else { return facts }
        facts += try context.fetch(FetchDescriptor<UserPreferencesRecord>()).map {
            try coreFactIdentity(
                recordType: "UserPreferencesRecord",
                recordID: CoreTimeRegimenBackfill.stableUUID(for: $0.singletonKey),
                fields: CoreFactDigestV1.preferences($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<HrtJourneyProfileRecord>()).map {
            try coreFactIdentity(
                recordType: "HrtJourneyProfileRecord",
                recordID: CoreTimeRegimenBackfill.stableUUID(for: $0.singletonKey),
                fields: CoreFactDigestV1.journeyProfile($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<HrtPeriodRecord>()).map {
            try coreFactIdentity(
                recordType: "HrtPeriodRecord",
                recordID: $0.id,
                fields: CoreFactDigestV1.period($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>()).map {
            try coreFactIdentity(
                recordType: "RegimenPlanVersionRecord",
                recordID: $0.id,
                fields: CoreFactDigestV1.regimen($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<RegimenItemRecord>()).map {
            try coreFactIdentity(
                recordType: "RegimenItemRecord",
                recordID: $0.id,
                fields: CoreFactDigestV1.item($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<ScheduleRuleRecord>()).map {
            try coreFactIdentity(
                recordType: "ScheduleRuleRecord",
                recordID: $0.id,
                fields: CoreFactDigestV1.schedule($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<HistoricalTimeRecord>()).map {
            try coreFactIdentity(
                recordType: "HistoricalTimeRecord",
                recordID: CoreTimeRegimenBackfill.stableUUID(for: $0.recordKey),
                fields: CoreFactDigestV1.historicalTime($0)
            )
        }
        guard includesTodayFacts else { return facts }
        facts += try context.fetch(FetchDescriptor<AdministrationEventRecord>()).map {
            try coreFactIdentity(
                recordType: "AdministrationEventRecord",
                recordID: $0.id,
                fields: TodayExecutionDigestV1.administrationEvent($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<ReminderOverrideRecord>()).map {
            try coreFactIdentity(
                recordType: "ReminderOverrideRecord",
                recordID: $0.id,
                fields: TodayExecutionDigestV1.reminderOverride($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<ReminderPreferenceRecord>()).map {
            try coreFactIdentity(
                recordType: "ReminderPreferenceRecord",
                recordID: $0.id,
                fields: TodayExecutionDigestV1.reminderPreference($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<OperationReceiptRecord>()).map {
            try coreFactIdentity(
                recordType: "OperationReceiptRecord",
                recordID: $0.operationID,
                fields: TodayExecutionDigestV1.operationReceipt($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<OperationReceiptLedgerRecord>()).map {
            try coreFactIdentity(
                recordType: "OperationReceiptLedgerRecord",
                recordID: TodayExecutionDigestV1.receiptLedgerID,
                fields: TodayExecutionDigestV1.operationReceiptLedger($0)
            )
        }
        return facts
    }

    private func coreFactIdentity(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field]
    ) throws -> FactIdentity {
        FactIdentity(
            recordType: recordType,
            recordID: recordID,
            digestHex: try RecordDigestV1.sha256Hex(
                recordType: recordType,
                recordID: recordID,
                fields: fields
            )
        )
    }

    private func openActive(
        pointer: GenerationPointer,
        reportedOrigin: AppDataStoreOrigin
    ) throws -> BootstrappedAppDataStore {
        let storeURL = layout.storeURL(for: pointer.generationID)
        let protectionResources = layout.protectionResources(for: pointer.generationID)
        do {
            let identity = try validateActiveStoreBeforeWritableOpen(
                at: storeURL,
                schemaVersion: pointer.schemaVersion
            )
            guard identity.datasetID == pointer.datasetID,
                  identity.factCount >= pointer.minimumFactCount,
                  identity.revisionCount >= pointer.minimumRevisionCount else {
                throw AppDataFailure.corruptionSuspected
            }
            let container: ModelContainer
            if pointer.schemaVersion == "4.0.0" {
                container = try AppModelContainerFactory.makeTodayContainer(at: storeURL)
            } else if pointer.schemaVersion == "3.0.0" {
                container = try AppModelContainerFactory.makeCoreContainer(at: storeURL)
            } else {
                container = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            }
            _ = try LegacyV1Backfill.run(in: container)
            if ["3.0.0", "4.0.0"].contains(pointer.schemaVersion) {
                _ = try CoreTimeRegimenBackfill.run(in: container)
            }
            if pointer.schemaVersion == "4.0.0" {
                _ = try TodayExecutionBackfill.run(in: container)
            }
            let report = try StoreFileProtectionAuditor(
                backupPolicy: backupPolicy,
                verificationMode: fileProtectionVerificationMode
            )
                .hardenAndInspect(
                    storeURL: storeURL,
                    resources: protectionResources
                )
            guard report.isAcceptableForCurrentPlatform else {
                throw AppDataFailure.fileProtectionUnverified
            }
            return BootstrappedAppDataStore(
                container: container,
                generationID: pointer.generationID,
                storeURL: storeURL,
                origin: reportedOrigin,
                protectionReport: report,
                protectionPlan: StoreFileProtectionPlan(
                    storeURL: storeURL,
                    resources: protectionResources,
                    backupPolicy: backupPolicy,
                    verificationMode: fileProtectionVerificationMode
                )
            )
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .storageUnavailable)
        }
    }

    private func validateActiveStoreBeforeWritableOpen(
        at storeURL: URL,
        schemaVersion: String
    ) throws -> GenerationIdentity {
        guard try hasSQLiteHeader(at: storeURL) else {
            throw AppDataFailure.corruptionSuspected
        }
        do {
            return try autoreleasepool {
                let includesCoreFacts = ["3.0.0", "4.0.0"].contains(schemaVersion)
                let includesTodayFacts = schemaVersion == "4.0.0"
                let container: ModelContainer
                if includesTodayFacts {
                    container = try AppModelContainerFactory.makeReadOnlyTodayContainer(at: storeURL)
                } else if includesCoreFacts {
                    container = try AppModelContainerFactory.makeReadOnlyCoreContainer(at: storeURL)
                } else {
                    container = try AppModelContainerFactory.makeReadOnlyBridgeContainer(at: storeURL)
                }
                return try validateFoundation(
                    in: ModelContext(container),
                    failure: .corruptionSuspected,
                    includesCoreFacts: includesCoreFacts,
                    includesTodayFacts: includesTodayFacts
                )
            }
        } catch let failure as AppDataFailure {
            throw failure
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .corruptionSuspected)
        }
    }

    private func validateV2StoreBeforeUpgrade(at storeURL: URL) throws -> GenerationIdentity {
        try validateActiveStoreBeforeWritableOpen(at: storeURL, schemaVersion: "2.0.0")
    }

    private func hasSQLiteHeader(at url: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            return header == Data("SQLite format 3\0".utf8)
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .corruptionSuspected)
        }
    }

    private func prepareDirectories() throws {
        for url in [layout.rootURL, layout.generationsURL, layout.pointerDirectoryURL, layout.recoveryURL] {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try applyBackupPolicy(to: url)
        }
    }

    private func prepareGeneration(_ id: UUID) throws {
        for url in [layout.generationDirectoryURL(for: id), layout.storeDirectoryURL(for: id)] {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try applyBackupPolicy(to: url)
        }
    }

    private func containsUnresolvedGenerationEvidence() throws -> Bool {
        do {
            return try !fileManager.contentsOfDirectory(
                at: layout.generationsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).isEmpty
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .storageUnavailable)
        }
    }

    private func existingStoreBundleParts(
        at storeURL: URL
    ) -> (main: Bool, wal: Bool, shm: Bool) {
        (
            fileManager.fileExists(atPath: storeURL.path),
            fileManager.fileExists(atPath: storeURL.path + "-wal"),
            fileManager.fileExists(atPath: storeURL.path + "-shm")
        )
    }

    private func copyStoreBundle(
        from source: URL,
        to destination: URL,
        failAt failpoint: StoreBootstrapFailpoint?,
        hardenSourceAfterCopy: Bool
    ) throws {
        for suffix in ["", "-wal", "-shm"] {
            let sourcePart = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: sourcePart.path) else { continue }
            let destinationPart = URL(fileURLWithPath: destination.path + suffix)
            try fileManager.copyItem(at: sourcePart, to: destinationPart)
            try applyCompleteFileProtection(to: destinationPart)
            try applyBackupPolicy(to: destinationPart)
            if suffix.isEmpty, failpoint == .duringLegacyBundleCopyAfterMain {
                throw StoreBootstrapInterruption.injected
            }
        }
        // The legacy bundle is the only recovery source until every existing
        // SQLite part has reached the inactive generation. Never mutate its
        // metadata before that safety copy is complete.
        if hardenSourceAfterCopy {
            try hardenPreservedLegacyBundle(at: source)
        }
    }

    private func hardenPreservedLegacyBundle(at storeURL: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try applyCompleteFileProtection(to: url)
                try applyBackupPolicy(to: url)
                let values = try url.resourceValues(
                    forKeys: [.fileProtectionKey, .isExcludedFromBackupKey]
                )
                if !fileProtectionVerificationMode.skipsUnavailableSimulatorFileProtection {
                    guard values.fileProtection.map({ $0 == .complete }) != false else {
                        throw AppDataFailure.fileProtectionUnverified
                    }
                }
                if values.isExcludedFromBackup != (backupPolicy == .excluded) {
                    throw AppDataFailure.fileProtectionUnverified
                }
#if !targetEnvironment(simulator)
                guard values.fileProtection == .complete else {
                    throw AppDataFailure.fileProtectionUnverified
                }
#endif
            } catch let failure as AppDataFailure {
                throw failure
            } catch {
                throw AppDataFailure.classifyStorage(
                    error,
                    fallback: .fileProtectionUnverified
                )
            }
        }
    }

    private func applyBackupPolicy(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = backupPolicy == .excluded
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func applyCompleteFileProtection(to url: URL) throws {
        guard !fileProtectionVerificationMode.skipsUnavailableSimulatorFileProtection else {
            return
        }
        try (url as NSURL).setResourceValue(
            URLFileProtection.complete,
            forKey: .fileProtectionKey
        )
    }
}

private struct ProtectedAtomicJSONWriter: Sendable {
    let backupPolicy: SystemBackupPolicy

    func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let data = try JSONEncoder.unmanualFoundation.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = backupPolicy == .excluded
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }
}

private extension JSONEncoder {
    static var unmanualFoundation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var unmanualFoundation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
