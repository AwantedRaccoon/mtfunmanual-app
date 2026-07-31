import Darwin
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

    var portableRestoreJournalURL: URL {
        recoveryURL.appending(
            path: "portable-restore-journal.json"
        )
    }

    var portablePackageCleanupJournalURL: URL {
        recoveryURL.appending(
            path: "portable-package-cleanup-v1.json"
        )
    }

    var portableRestoreStagingRootURL: URL {
        recoveryURL.appending(
            path: "PortableImports",
            directoryHint: .isDirectory
        )
    }

    func portableRestoreStagingURL(
        for operationID: UUID
    ) -> URL {
        portableRestoreStagingRootURL
            .appending(
                path: operationID.uuidString.lowercased(),
                directoryHint: .isDirectory
            )
            .appending(
                path: "package.unmanualbackup",
                directoryHint: .isDirectory
            )
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
            StoreFileProtectionResource(role: .journal, url: journalURL),
            StoreFileProtectionResource(
                role: .auxiliary,
                url: portableRestoreJournalURL
            ),
            StoreFileProtectionResource(
                role: .auxiliary,
                url: portablePackageCleanupJournalURL
            )
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
        administrationEventIDs: Set<UUID> = [],
        additionalHistoricalSourceIDs: [String: Set<UUID>] = [:]
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
                sourceExists = additionalHistoricalSourceIDs[time.sourceRecordType]?
                    .contains(time.sourceRecordID) == true
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
    static let attachmentSelection = "App 会在私有存储建立副本；原件仍留在照片或文件提供方。App 不主动上传或实时同步；私有副本可能按 iOS 设置进入系统备份，但不保证某次备份或恢复成功。启用 App Lock 后，附件预览会经过同一根门禁；它不会加密系统备份或原件。"
    static let quickRecord = "这条记录保存在 App 私有存储中；iOS 可能纳入系统备份"
    static let todayAccessibility = "今天页，记录保存在 App 私有存储中；App 不主动上传，iOS 可能纳入系统备份"
}

enum AppDataStoreOrigin: String, Codable, Equatable, Sendable {
    case newInstall
    case legacyAdoption
    case existingGeneration
    case schemaUpgrade
}

enum AppDataStoreBootstrapMode: Equatable, Sendable {
    case normal
    case freshAfterReset(
        expectedGenerationID: UUID,
        expectedDatasetID: UUID
    )
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
        schemaVersion: String = "13.0.0",
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
        do {
            let writer = ProtectedAtomicJSONWriter(
                backupPolicy: backupPolicy
            )
            guard let data = try writer
                .readReconciledData(
                    from: layout.pointerURL,
                    validator: {
                        (try? Self.decodeValidated($0))
                            != nil
                    }
                ) else {
                throw AppDataFailure.invalidGenerationPointer
            }
            return try Self.decodeValidated(data)
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .invalidGenerationPointer)
        }
    }

    func write(_ pointer: GenerationPointer) throws {
        try ProtectedAtomicJSONWriter(backupPolicy: backupPolicy)
            .write(
                pointer,
                to: layout.pointerURL,
                validator: {
                    (try? Self.decodeValidated($0))
                        != nil
                }
            )
    }

    func readIfPresent() throws -> GenerationPointer? {
        do {
            let writer = ProtectedAtomicJSONWriter(
                backupPolicy: backupPolicy
            )
            guard let data = try writer
                .readReconciledData(
                    from: layout.pointerURL,
                    validator: {
                        (try? Self.decodeValidated($0))
                            != nil
                    }
                ) else {
                return nil
            }
            return try Self.decodeValidated(data)
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback:
                    .invalidGenerationPointer
            )
        }
    }

    private static func decodeValidated(
        _ data: Data
    ) throws -> GenerationPointer {
        let pointer = try JSONDecoder
            .unmanualFoundation.decode(
                GenerationPointer.self,
                from: data
            )
        guard pointer.formatVersion
                == GenerationPointer.formatVersion,
              [
                  "2.0.0", "3.0.0", "4.0.0",
                  "5.0.0", "6.0.0", "7.0.0",
                  "8.0.0", "9.0.0", "10.0.0",
                  "11.0.0", "12.0.0", "13.0.0"
              ].contains(pointer.schemaVersion),
              pointer.minimumFactCount >= 0,
              pointer.minimumRevisionCount >= 0,
              pointer.minimumFactCount
                == pointer.minimumRevisionCount,
              pointer.activatedAt.timeIntervalSince1970
                .isFinite else {
            throw AppDataFailure
                .invalidGenerationPointer
        }
        return pointer
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
        do {
            let writer = ProtectedAtomicJSONWriter(
                backupPolicy: backupPolicy
            )
            guard let data = try writer
                .readReconciledData(
                    from: layout.journalURL,
                    validator: {
                        (try? Self.decodeValidated($0))
                            != nil
                    }
                ) else {
                throw AppDataFailure.migrationFailed
            }
            return try Self.decodeValidated(data)
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .migrationFailed)
        }
    }

    func readIfPresent() throws -> MigrationJournal? {
        do {
            let writer = ProtectedAtomicJSONWriter(
                backupPolicy: backupPolicy
            )
            guard let data = try writer
                .readReconciledData(
                    from: layout.journalURL,
                    validator: {
                        (try? Self.decodeValidated($0))
                            != nil
                    }
                ) else {
                return nil
            }
            return try Self.decodeValidated(data)
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback: .migrationFailed
            )
        }
    }

    func write(_ journal: MigrationJournal) throws {
        try ProtectedAtomicJSONWriter(backupPolicy: backupPolicy)
            .write(
                journal,
                to: layout.journalURL,
                validator: {
                    (try? Self.decodeValidated($0))
                        != nil
                }
            )
    }

    private static func decodeValidated(
        _ data: Data
    ) throws -> MigrationJournal {
        let journal = try JSONDecoder
            .unmanualFoundation.decode(
                MigrationJournal.self,
                from: data
            )
        guard journal.formatVersion
                == MigrationJournal.formatVersion,
              journal.origin != .existingGeneration,
              (journal.origin != .schemaUpgrade
                || (
                    journal.sourceGenerationID != nil
                    && journal.sourceGenerationID
                        != journal.targetGenerationID
                    && (
                        (
                            journal.sourceSchemaVersion
                                == "2.0.0"
                            && journal.targetSchemaVersion
                                == "3.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "3.0.0"
                            && journal.targetSchemaVersion
                                == "4.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "4.0.0"
                            && journal.targetSchemaVersion
                                == "5.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "5.0.0"
                            && [
                                "6.0.0", "7.0.0"
                            ].contains(
                                journal.targetSchemaVersion
                            )
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "6.0.0"
                            && [
                                "7.0.0", "8.0.0"
                            ].contains(
                                journal.targetSchemaVersion
                            )
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "7.0.0"
                            && journal.targetSchemaVersion
                                == "8.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "8.0.0"
                            && journal.targetSchemaVersion
                                == "9.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "9.0.0"
                            && journal.targetSchemaVersion
                                == "10.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "10.0.0"
                            && journal.targetSchemaVersion
                                == "11.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "11.0.0"
                            && journal.targetSchemaVersion
                                == "12.0.0"
                        )
                        || (
                            journal.sourceSchemaVersion
                                == "12.0.0"
                            && journal.targetSchemaVersion
                                == "13.0.0"
                        )
                    )
                )),
              (
                journal.origin == .schemaUpgrade
                    || (
                        journal.sourceGenerationID == nil
                        && journal.sourceSchemaVersion
                            == nil
                        && journal.targetSchemaVersion
                            == nil
                    )
              ),
              journal.updatedAt.timeIntervalSince1970
                .isFinite else {
            throw AppDataFailure.migrationFailed
        }
        return journal
    }
}

enum StoreBootstrapFailpoint: Equatable, Sendable {
    case duringLegacyBundleCopyAfterMain
    case afterGenerationPrepared
    case duringFileProtectionValidationBeforePointer
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
    let attachmentRootURL: URL
    let layout: AppDataStoreLayout?
    let origin: AppDataStoreOrigin
    let protectionReport: StoreFileProtectionReport
    let protectionPlan: StoreFileProtectionPlan?

    init(
        container: ModelContainer,
        generationID: UUID,
        storeURL: URL,
        origin: AppDataStoreOrigin,
        protectionReport: StoreFileProtectionReport,
        protectionPlan: StoreFileProtectionPlan? = nil,
        attachmentRootURL: URL? = nil,
        layout: AppDataStoreLayout? = nil
    ) {
        self.container = container
        self.generationID = generationID
        self.storeURL = storeURL
        self.attachmentRootURL = attachmentRootURL
            ?? storeURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Files", isDirectory: true)
        self.layout = layout
        self.origin = origin
        self.protectionReport = protectionReport
        self.protectionPlan = protectionPlan
    }
}

struct DataInventoryGenerationProvenance: Equatable, Sendable {
    let generationID: UUID
    let schemaVersion: String
    let datasetID: UUID
    let factCount: Int
    let revisionCount: Int
    let attachments: [DataInventoryAttachmentObservation]
}

struct AppDataStoreBootstrapper {
    let layout: AppDataStoreLayout
    let backupPolicy: SystemBackupPolicy
    let mode: AppDataStoreBootstrapMode
    private let fileManager: FileManager
    private let fileProtectionVerificationMode: StoreFileProtectionVerificationMode

    init(
        layout: AppDataStoreLayout,
        backupPolicy: SystemBackupPolicy = .production,
        mode: AppDataStoreBootstrapMode = .normal,
        fileManager: FileManager = .default,
        fileProtectionVerificationMode: StoreFileProtectionVerificationMode = .live
    ) {
        self.layout = layout
        self.backupPolicy = backupPolicy
        self.mode = mode
        self.fileManager = fileManager
        self.fileProtectionVerificationMode = fileProtectionVerificationMode
    }

    func validateGenerationForDataInventory(
        generationID: UUID,
        schemaVersion: String,
        expectedDatasetID: UUID
    ) throws -> DataInventoryGenerationProvenance {
        let storeURL = layout.storeURL(for: generationID)
        let expectedStoreURL = layout
            .generationDirectoryURL(for: generationID)
            .appending(path: "Store", directoryHint: .isDirectory)
            .appending(path: "user.sqlite")
            .standardizedFileURL
        guard storeURL.standardizedFileURL == expectedStoreURL else {
            throw AppDataFailure.corruptionSuspected
        }
        let identity = try validateActiveStoreBeforeWritableOpen(
            at: storeURL,
            schemaVersion: schemaVersion
        )
        guard identity.datasetID == expectedDatasetID,
              identity.factCount >= 0,
              identity.factCount == identity.revisionCount else {
            throw AppDataFailure.corruptionSuspected
        }
        let container: ModelContainer
        switch schemaVersion {
        case "11.0.0":
            container = try AppModelContainerFactory
                .makeReadOnlyPrivacyControlContainer(at: storeURL)
        case "12.0.0":
            container = try AppModelContainerFactory
                .makeReadOnlyDataControlContainer(at: storeURL)
        case "13.0.0":
            container = try AppModelContainerFactory
                .makeReadOnlyContentFavoriteContainer(at: storeURL)
        default:
            throw AppDataFailure.corruptionSuspected
        }
        let context = ModelContext(container)
        let attachmentCount = try context.fetchCount(
            FetchDescriptor<AttachmentRecord>()
        )
        guard attachmentCount >= 0,
              attachmentCount
                <= DataInventoryTaxonomy.maximumRowsPerModel else {
            throw AppDataFailure.corruptionSuspected
        }
        var attachmentDescriptor =
            FetchDescriptor<AttachmentRecord>()
        attachmentDescriptor.fetchLimit =
            DataInventoryTaxonomy.maximumRowsPerModel + 1
        let attachmentRows = try context.fetch(attachmentDescriptor)
        guard attachmentRows.count == attachmentCount else {
            throw AppDataFailure.corruptionSuspected
        }
        let attachments = try attachmentRows.map {
            guard let snapshot = AttachmentSnapshot($0) else {
                throw AppDataFailure.corruptionSuspected
            }
            return DataInventoryAttachmentObservation(
                operationID: $0.operationID,
                attachment: snapshot,
                deletedAt: $0.deletedAt,
                deleteOperationID: $0.deleteOperationID
            )
        }
        return DataInventoryGenerationProvenance(
            generationID: generationID,
            schemaVersion: schemaVersion,
            datasetID: identity.datasetID,
            factCount: identity.factCount,
            revisionCount: identity.revisionCount,
            attachments: attachments
        )
    }

    func validatePortableRestoreSourceForDataInventory(
        generationID: UUID,
        expectedDatasetID: UUID
    ) throws -> DataInventoryGenerationProvenance {
        for schemaVersion in ["13.0.0", "12.0.0"] {
            if let provenance = try? validateGenerationForDataInventory(
                generationID: generationID,
                schemaVersion: schemaVersion,
                expectedDatasetID: expectedDatasetID
            ) {
                return provenance
            }
        }
        throw AppDataFailure.corruptionSuspected
    }

    func open(failAt failpoint: StoreBootstrapFailpoint? = nil) throws -> BootstrappedAppDataStore {
        if case let .freshAfterReset(
            expectedGenerationID,
            expectedDatasetID
        ) = mode {
            return try openFreshAfterReset(
                expectedGenerationID: expectedGenerationID,
                expectedDatasetID: expectedDatasetID,
                failAt: failpoint
            )
        }
        try prepareDirectories()
        let pointerStore = GenerationPointerStore(layout: layout, backupPolicy: backupPolicy)
        let journalStore = MigrationJournalStore(layout: layout, backupPolicy: backupPolicy)

        if let pointer = try pointerStore.readIfPresent() {
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
            if pointer.schemaVersion == "4.0.0" {
                return try upgradeV4Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "5.0.0" {
                return try upgradeV5Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "6.0.0" {
                return try upgradeV6Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "7.0.0" {
                return try upgradeV7Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "8.0.0" {
                return try upgradeV8Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "9.0.0" {
                return try upgradeV9Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "10.0.0" {
                return try upgradeV10Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "11.0.0" {
                return try upgradeV11Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            if pointer.schemaVersion == "12.0.0" {
                return try upgradeV12Generation(
                    pointer: pointer,
                    pointerStore: pointerStore,
                    journalStore: journalStore,
                    failAt: failpoint
                )
            }
            return try openActive(pointer: pointer, reportedOrigin: .existingGeneration)
        }

        if var journal = try journalStore.readIfPresent() {
            guard journal.origin == .newInstall
                    || journal.origin == .legacyAdoption,
                  journal.sourceGenerationID == nil,
                  journal.sourceSchemaVersion == nil,
                  journal.targetSchemaVersion == nil,
                  journal.phase != .activated else {
                throw AppDataFailure.migrationFailed
            }
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
            let identity = try validateAndBackfillDataControl(
                storeURL: targetURL,
                onboardingSource: journal.origin == .newInstall
                    ? .newInstallV8
                    : .legacyAdoption,
                hrtSourceSchemaVersion: "9.0.0",
                parentSourceSchemaVersion: "9.0.0",
                privacySource: .bootstrapV11,
                dataControlSource: .bootstrapV12,
                targetSchemaVersion: "13.0.0",
                failAt: failpoint
            )
            try validateAttachmentsBeforeActivation(
                generationID: journal.targetGenerationID,
                containerAt: targetURL,
                schemaVersion: "13.0.0",
                failure: .migrationFailed
            )
            journal.phase = .validated
            journal.updatedAt = Date()
            try journalStore.write(journal)
            if failpoint == .afterValidationBeforePointer {
                throw StoreBootstrapInterruption.injected
            }
            try pointerStore.write(
                GenerationPointer(
                    generationID: journal.targetGenerationID,
                    schemaVersion: "13.0.0",
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
                    schemaVersion: "13.0.0",
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

        let identity = try validateAndBackfillDataControl(
            storeURL: layout.storeURL(for: generationID),
            onboardingSource: origin == .newInstall
                ? .newInstallV8
                : .legacyAdoption,
            hrtSourceSchemaVersion: "9.0.0",
            parentSourceSchemaVersion: "9.0.0",
            privacySource: .bootstrapV11,
            dataControlSource: .bootstrapV12,
            targetSchemaVersion: "13.0.0",
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: generationID,
            containerAt: layout.storeURL(for: generationID),
            schemaVersion: "13.0.0",
            failure: .migrationFailed
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
                schemaVersion: "13.0.0",
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
                schemaVersion: "13.0.0",
                origin: origin,
                datasetID: identity.datasetID,
                minimumFactCount: identity.factCount,
                minimumRevisionCount: identity.revisionCount
            ),
            reportedOrigin: origin
        )
    }

    private func openFreshAfterReset(
        expectedGenerationID: UUID,
        expectedDatasetID: UUID,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let legacy = existingStoreBundleParts(
            at: layout.legacyStoreURL
        )
        guard !legacy.main, !legacy.wal, !legacy.shm else {
            throw AppDataFailure.corruptionSuspected
        }
        if fileManager.fileExists(atPath: layout.rootURL.path) {
            let allowed = Set([
                "Generations",
                "GenerationPointer",
                "Recovery"
            ])
            let children = try fileManager.contentsOfDirectory(
                at: layout.rootURL,
                includingPropertiesForKeys: [
                    .isSymbolicLinkKey,
                    .isDirectoryKey
                ],
                options: []
            )
            guard try children.allSatisfy({ child in
                let values = try child.resourceValues(
                    forKeys: [
                        .isSymbolicLinkKey,
                        .isDirectoryKey
                    ]
                )
                return values.isSymbolicLink != true
                    && values.isDirectory == true
                    && allowed.contains(
                        child.lastPathComponent
                    )
            }) else {
                throw AppDataFailure.corruptionSuspected
            }
        }
        try prepareDirectories()
        let pointerStore = GenerationPointerStore(
            layout: layout,
            backupPolicy: backupPolicy
        )
        let journalStore = MigrationJournalStore(
            layout: layout,
            backupPolicy: backupPolicy
        )
        try validateFreshResetControlLayout()
        let generationChildren = try fileManager
            .contentsOfDirectory(
                at: layout.generationsURL,
                includingPropertiesForKeys: [
                    .isSymbolicLinkKey,
                    .isDirectoryKey
                ],
                options: []
            )
        guard try generationChildren.allSatisfy({ child in
            let values = try child.resourceValues(
                forKeys: [
                    .isSymbolicLinkKey,
                    .isDirectoryKey
                ]
            )
            return child.lastPathComponent
                    == expectedGenerationID.uuidString.lowercased()
                && values.isSymbolicLink != true
                && values.isDirectory == true
        }) else {
            throw AppDataFailure.corruptionSuspected
        }
        if let pointer = try pointerStore.readIfPresent() {
            let migrationJournal: MigrationJournal
            do {
                migrationJournal = try journalStore.read()
            } catch {
                throw AppDataFailure.corruptionSuspected
            }
            guard pointer.generationID == expectedGenerationID,
                  pointer.datasetID == expectedDatasetID,
                  pointer.schemaVersion == "13.0.0",
                  pointer.origin == .newInstall,
                  migrationJournal.targetGenerationID
                    == expectedGenerationID,
                  migrationJournal.origin == .newInstall,
                  migrationJournal.sourceGenerationID == nil,
                  migrationJournal.sourceSchemaVersion == nil,
                  migrationJournal.targetSchemaVersion == nil,
                  migrationJournal.phase == .validated
                    || migrationJournal.phase
                        == .activated else {
                throw AppDataFailure.corruptionSuspected
            }
            try validateFreshResetGenerationLayout(
                expectedGenerationID,
                requiresCompleteStore: true
            )
            return try openActive(
                pointer: pointer,
                reportedOrigin: .newInstall
            )
        }
        var journal: MigrationJournal
        if let existing = try journalStore.readIfPresent() {
            guard existing.targetGenerationID == expectedGenerationID,
                  existing.origin == .newInstall,
                  existing.sourceGenerationID == nil,
                  existing.sourceSchemaVersion == nil,
                  existing.targetSchemaVersion == nil,
                  existing.phase != .activated else {
                throw AppDataFailure.corruptionSuspected
            }
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: expectedGenerationID,
                origin: .newInstall
            )
            try journalStore.write(journal)
        }
        if journal.phase == .preparing {
            try validateFreshPreparingGenerationLayout(
                expectedGenerationID
            )
            try prepareGeneration(expectedGenerationID)
            try validateFreshPreparedGenerationLayout(
                expectedGenerationID
            )
            journal.phase = .prepared
            journal.updatedAt = Date()
            try journalStore.write(journal)
            if failpoint == .afterGenerationPrepared {
                throw StoreBootstrapInterruption.injected
            }
        }
        switch journal.phase {
        case .prepared:
            try validateFreshResetGenerationLayout(
                expectedGenerationID,
                requiresCompleteStore: false
            )
        case .validated:
            try validateFreshResetGenerationLayout(
                expectedGenerationID,
                requiresCompleteStore: true
            )
        case .preparing, .activated:
            throw AppDataFailure.corruptionSuspected
        }
        let identity = try validateAndBackfillDataControl(
            storeURL: layout.storeURL(
                for: expectedGenerationID
            ),
            onboardingSource: .newInstallV8,
            hrtSourceSchemaVersion: "9.0.0",
            parentSourceSchemaVersion: "9.0.0",
            privacySource: .bootstrapV11,
            dataControlSource: .bootstrapV12,
            targetSchemaVersion: "13.0.0",
            expectedDatasetID: expectedDatasetID,
            failAt: failpoint
        )
        guard identity.datasetID == expectedDatasetID else {
            throw AppDataFailure.corruptionSuspected
        }
        try validateAttachmentsBeforeActivation(
            generationID: expectedGenerationID,
            containerAt: layout.storeURL(
                for: expectedGenerationID
            ),
            schemaVersion: "13.0.0",
            failure: .migrationFailed
        )
        try validateFreshResetGenerationLayout(
            expectedGenerationID,
            requiresCompleteStore: true
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }
        let pointer = GenerationPointer(
            generationID: expectedGenerationID,
            schemaVersion: "13.0.0",
            origin: .newInstall,
            datasetID: expectedDatasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(pointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try openActive(
            pointer: pointer,
            reportedOrigin: .newInstall
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
        return try upgradeV4Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV4Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "4.0.0"
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
           existing.sourceSchemaVersion == "4.0.0",
           existing.targetSchemaVersion == "5.0.0" {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "4.0.0",
                targetSchemaVersion: "5.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            guard journal.targetGenerationID != pointer.generationID else {
                throw AppDataFailure.migrationFailed
            }
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal || targetPresence.shm {
                // This exact inactive generation is owned by the preparing
                // journal. Rebuild it in place so an interrupted V4 copy
                // cannot leave an orphan or silently change recovery identity.
                try fileManager.removeItem(
                    at: layout.generationDirectoryURL(
                        for: journal.targetGenerationID
                    )
                )
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
        let identity = try validateAndBackfillPersonalTimeline(
            storeURL: targetURL,
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "5.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV5Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV5Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "5.0.0"
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
           existing.sourceSchemaVersion == "5.0.0",
           ["6.0.0", "7.0.0"].contains(
               existing.targetSchemaVersion ?? ""
           ) {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "5.0.0",
                targetSchemaVersion: "7.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            guard journal.targetGenerationID != pointer.generationID else {
                throw AppDataFailure.migrationFailed
            }
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal || targetPresence.shm {
                try fileManager.removeItem(
                    at: layout.generationDirectoryURL(
                        for: journal.targetGenerationID
                    )
                )
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
        let identity = try validateAndBackfillCountdownLifecycle(
            storeURL: targetURL,
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "7.0.0",
            failure: .migrationFailed
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "7.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV7Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV6Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "6.0.0"
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
           existing.sourceSchemaVersion == "6.0.0",
           existing.targetSchemaVersion == "7.0.0" {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "6.0.0",
                targetSchemaVersion: "7.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            guard journal.targetGenerationID != pointer.generationID else {
                throw AppDataFailure.migrationFailed
            }
            let targetGenerationURL = layout.generationDirectoryURL(
                for: journal.targetGenerationID
            )
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal
                || targetPresence.shm
                || fileManager.fileExists(atPath: targetGenerationURL.path) {
                try fileManager.removeItem(at: targetGenerationURL)
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
        let identity = try validateAndBackfillCountdownLifecycle(
            storeURL: targetURL,
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "7.0.0",
            failure: .migrationFailed
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "7.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV7Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV7Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "7.0.0"
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
           existing.sourceSchemaVersion == "7.0.0",
           existing.targetSchemaVersion == "8.0.0" {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "7.0.0",
                targetSchemaVersion: "8.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            guard journal.targetGenerationID != pointer.generationID else {
                throw AppDataFailure.migrationFailed
            }
            let targetGenerationURL = layout.generationDirectoryURL(
                for: journal.targetGenerationID
            )
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal
                || targetPresence.shm
                || fileManager.fileExists(atPath: targetGenerationURL.path) {
                try fileManager.removeItem(at: targetGenerationURL)
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
        let identity = try validateAndBackfillOnboarding(
            storeURL: targetURL,
            source: .schemaUpgradeV7,
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "8.0.0",
            failure: .migrationFailed
        )
        try validateFileProtectionBeforeActivation(
            generationID: journal.targetGenerationID,
            storeURL: targetURL,
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "8.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV8Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV8Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "8.0.0"
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
           existing.sourceSchemaVersion == "8.0.0",
           existing.targetSchemaVersion == "9.0.0" {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "8.0.0",
                targetSchemaVersion: "9.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            guard journal.targetGenerationID != pointer.generationID else {
                throw AppDataFailure.migrationFailed
            }
            let targetGenerationURL = layout.generationDirectoryURL(
                for: journal.targetGenerationID
            )
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal
                || targetPresence.shm
                || fileManager.fileExists(atPath: targetGenerationURL.path) {
                try fileManager.removeItem(at: targetGenerationURL)
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
        let identity = try validateAndBackfillHrtJourneyLifecycle(
            storeURL: targetURL,
            onboardingSource: .schemaUpgradeV7,
            hrtSourceSchemaVersion: "8.0.0",
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "9.0.0",
            failure: .migrationFailed
        )
        try validateFileProtectionBeforeActivation(
            generationID: journal.targetGenerationID,
            storeURL: targetURL,
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "9.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV9Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV9Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "9.0.0"
        )
        guard sourceIdentity.datasetID == pointer.datasetID,
              sourceIdentity.factCount >= pointer.minimumFactCount,
              sourceIdentity.revisionCount
                >= pointer.minimumRevisionCount else {
            throw AppDataFailure.corruptionSuspected
        }

        var journal: MigrationJournal
        if let existing = try journalStore.readIfPresent(),
           existing.origin == .schemaUpgrade,
           existing.sourceGenerationID == pointer.generationID,
           existing.sourceSchemaVersion == "9.0.0",
           existing.targetSchemaVersion == "10.0.0" {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "9.0.0",
                targetSchemaVersion: "10.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            guard journal.targetGenerationID != pointer.generationID else {
                throw AppDataFailure.migrationFailed
            }
            let targetGenerationURL = layout.generationDirectoryURL(
                for: journal.targetGenerationID
            )
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal
                || targetPresence.shm
                || fileManager.fileExists(
                    atPath: targetGenerationURL.path
                ) {
                try fileManager.removeItem(at: targetGenerationURL)
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
        let identity = try validateAndBackfillParentRecordLifecycle(
            storeURL: targetURL,
            onboardingSource: .schemaUpgradeV7,
            hrtSourceSchemaVersion: "9.0.0",
            parentSourceSchemaVersion: "9.0.0",
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "10.0.0",
            failure: .migrationFailed
        )
        try validateFileProtectionBeforeActivation(
            generationID: journal.targetGenerationID,
            storeURL: targetURL,
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "10.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV10Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV10Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "10.0.0"
        )
        guard sourceIdentity.datasetID == pointer.datasetID,
              sourceIdentity.factCount >= pointer.minimumFactCount,
              sourceIdentity.revisionCount
                >= pointer.minimumRevisionCount else {
            throw AppDataFailure.corruptionSuspected
        }

        var journal: MigrationJournal
        if let existing = try journalStore.readIfPresent(),
           existing.origin == .schemaUpgrade,
           existing.sourceGenerationID == pointer.generationID,
           existing.sourceSchemaVersion == "10.0.0",
           existing.targetSchemaVersion == "11.0.0" {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "10.0.0",
                targetSchemaVersion: "11.0.0"
            )
            try journalStore.write(journal)
        }

        if journal.phase == .preparing {
            guard journal.targetGenerationID != pointer.generationID else {
                throw AppDataFailure.migrationFailed
            }
            let targetGenerationURL = layout.generationDirectoryURL(
                for: journal.targetGenerationID
            )
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal
                || targetPresence.shm
                || fileManager.fileExists(
                    atPath: targetGenerationURL.path
                ) {
                try fileManager.removeItem(at: targetGenerationURL)
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
        let identity = try validateAndBackfillPrivacyControl(
            storeURL: targetURL,
            onboardingSource: .schemaUpgradeV7,
            hrtSourceSchemaVersion: "9.0.0",
            parentSourceSchemaVersion: "9.0.0",
            privacySource: .schemaUpgradeV10,
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "11.0.0",
            failure: .migrationFailed
        )
        try validateFileProtectionBeforeActivation(
            generationID: journal.targetGenerationID,
            storeURL: targetURL,
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "11.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV11Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV11Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "11.0.0"
        )
        guard sourceIdentity.datasetID == pointer.datasetID,
              sourceIdentity.factCount >= pointer.minimumFactCount,
              sourceIdentity.revisionCount
                >= pointer.minimumRevisionCount else {
            throw AppDataFailure.corruptionSuspected
        }

        var journal: MigrationJournal
        if let existing = try journalStore.readIfPresent(),
           existing.origin == .schemaUpgrade,
           existing.sourceGenerationID == pointer.generationID,
           existing.sourceSchemaVersion == "11.0.0",
           existing.targetSchemaVersion == "12.0.0",
           existing.targetGenerationID != pointer.generationID,
           existing.phase != .activated {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "11.0.0",
                targetSchemaVersion: "12.0.0"
            )
            try journalStore.write(journal)
        }
        guard journal.sourceGenerationID == pointer.generationID,
              journal.targetGenerationID != pointer.generationID,
              journal.sourceSchemaVersion == "11.0.0",
              journal.targetSchemaVersion == "12.0.0",
              journal.phase != .activated else {
            throw AppDataFailure.migrationFailed
        }

        if journal.phase == .preparing {
            let targetGenerationURL = layout.generationDirectoryURL(
                for: journal.targetGenerationID
            )
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal
                || targetPresence.shm
                || fileManager.fileExists(
                    atPath: targetGenerationURL.path
                ) {
                try fileManager.removeItem(at: targetGenerationURL)
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
        let identity = try validateAndBackfillDataControl(
            storeURL: targetURL,
            onboardingSource: .schemaUpgradeV7,
            hrtSourceSchemaVersion: "9.0.0",
            parentSourceSchemaVersion: "9.0.0",
            privacySource: .schemaUpgradeV10,
            dataControlSource: .schemaUpgradeV11,
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "12.0.0",
            failure: .migrationFailed
        )
        try validateFileProtectionBeforeActivation(
            generationID: journal.targetGenerationID,
            storeURL: targetURL,
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "12.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try upgradeV12Generation(
            pointer: upgradedPointer,
            pointerStore: pointerStore,
            journalStore: journalStore,
            failAt: failpoint
        )
    }

    private func upgradeV12Generation(
        pointer: GenerationPointer,
        pointerStore: GenerationPointerStore,
        journalStore: MigrationJournalStore,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws -> BootstrappedAppDataStore {
        let sourceURL = layout.storeURL(for: pointer.generationID)
        let sourceIdentity = try validateActiveStoreBeforeWritableOpen(
            at: sourceURL,
            schemaVersion: "12.0.0"
        )
        guard sourceIdentity.datasetID == pointer.datasetID,
              sourceIdentity.factCount >= pointer.minimumFactCount,
              sourceIdentity.revisionCount
                >= pointer.minimumRevisionCount else {
            throw AppDataFailure.corruptionSuspected
        }

        var journal: MigrationJournal
        if let existing = try journalStore.readIfPresent(),
           existing.origin == .schemaUpgrade,
           existing.sourceGenerationID == pointer.generationID,
           existing.sourceSchemaVersion == "12.0.0",
           existing.targetSchemaVersion == "13.0.0",
           existing.targetGenerationID != pointer.generationID,
           existing.phase != .activated {
            journal = existing
        } else {
            journal = MigrationJournal(
                targetGenerationID: UUID(),
                origin: .schemaUpgrade,
                sourceGenerationID: pointer.generationID,
                sourceSchemaVersion: "12.0.0",
                targetSchemaVersion: "13.0.0"
            )
            try journalStore.write(journal)
        }
        guard journal.sourceGenerationID == pointer.generationID,
              journal.targetGenerationID != pointer.generationID,
              journal.sourceSchemaVersion == "12.0.0",
              journal.targetSchemaVersion == "13.0.0",
              journal.phase != .activated else {
            throw AppDataFailure.migrationFailed
        }

        if journal.phase == .preparing {
            let targetGenerationURL = layout.generationDirectoryURL(
                for: journal.targetGenerationID
            )
            let targetPresence = existingStoreBundleParts(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            if targetPresence.main || targetPresence.wal
                || targetPresence.shm
                || fileManager.fileExists(
                    atPath: targetGenerationURL.path
                ) {
                try fileManager.removeItem(at: targetGenerationURL)
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
        let identity = try migrateAndValidateContentFavorite(
            storeURL: targetURL,
            failAt: failpoint
        )
        try validateAttachmentsBeforeActivation(
            generationID: journal.targetGenerationID,
            containerAt: targetURL,
            schemaVersion: "13.0.0",
            failure: .migrationFailed
        )
        try validateFileProtectionBeforeActivation(
            generationID: journal.targetGenerationID,
            storeURL: targetURL,
            failAt: failpoint
        )
        journal.phase = .validated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        if failpoint == .afterValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }

        let upgradedPointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            schemaVersion: "13.0.0",
            origin: .schemaUpgrade,
            datasetID: identity.datasetID,
            minimumFactCount: identity.factCount,
            minimumRevisionCount: identity.revisionCount
        )
        try pointerStore.write(upgradedPointer)
        journal.phase = .activated
        journal.updatedAt = Date()
        try journalStore.write(journal)
        return try openActive(
            pointer: upgradedPointer,
            reportedOrigin: .schemaUpgrade
        )
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

    private func validateAndBackfillPersonalTimeline(
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
                let container = try AppModelContainerFactory
                    .makePersonalTimelineContainer(at: storeURL)
                guard try LegacyV1Backfill.run(in: container).didComplete,
                      try CoreTimeRegimenBackfill.run(in: container).didComplete,
                      try TodayExecutionBackfill.run(in: container).didComplete,
                      try PersonalTimelineBackfill.run(in: container).didComplete else {
                    throw AppDataFailure.migrationFailed
                }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory
                    .makePersonalTimelineContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .migrationFailed)
        }
    }

    private func validateAndBackfillCountdownLifecycle(
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
                let container = try AppModelContainerFactory
                    .makeV7CountdownIntegrityContainer(at: storeURL)
                guard try LegacyV1Backfill.run(in: container).didComplete,
                      try CoreTimeRegimenBackfill.run(in: container).didComplete,
                      try TodayExecutionBackfill.run(in: container).didComplete,
                      try PersonalTimelineBackfill.run(in: container).didComplete,
                      try CountdownLifecycleBackfill.run(in: container)
                        .didComplete,
                      try CountdownIntegrityBackfill.run(in: container)
                        .didComplete else {
                    throw AppDataFailure.migrationFailed
                }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory
                    .makeV7CountdownIntegrityContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .migrationFailed)
        }
    }

    private func validateAndBackfillOnboarding(
        storeURL: URL,
        source: OnboardingBackfillSource,
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
                let container = try AppModelContainerFactory
                    .makeCountdownLifecycleContainer(at: storeURL)
                guard try LegacyV1Backfill.run(in: container).didComplete,
                      try CoreTimeRegimenBackfill.run(in: container).didComplete,
                      try TodayExecutionBackfill.run(in: container).didComplete,
                      try PersonalTimelineBackfill.run(in: container).didComplete,
                      try CountdownLifecycleBackfill.run(in: container)
                        .didComplete,
                      try CountdownIntegrityBackfill.run(in: container)
                        .didComplete,
                      try OnboardingBackfill.run(
                          in: container,
                          source: source
                      ).didComplete else {
                    throw AppDataFailure.migrationFailed
                }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory
                    .makeCountdownLifecycleContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback: .migrationFailed
            )
        }
    }

    private func validateAndBackfillHrtJourneyLifecycle(
        storeURL: URL,
        onboardingSource: OnboardingBackfillSource,
        hrtSourceSchemaVersion: String,
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
                let container = try AppModelContainerFactory
                    .makeHrtJourneyLifecycleContainer(at: storeURL)
                guard try LegacyV1Backfill.run(in: container).didComplete,
                      try CoreTimeRegimenBackfill.run(in: container).didComplete,
                      try TodayExecutionBackfill.run(in: container).didComplete,
                      try PersonalTimelineBackfill.run(in: container).didComplete,
                      try CountdownLifecycleBackfill.run(in: container)
                        .didComplete,
                      try CountdownIntegrityBackfill.run(in: container)
                        .didComplete,
                      try OnboardingBackfill.run(
                          in: container,
                          source: onboardingSource
                      ).didComplete,
                      try HrtJourneyLifecycleBackfill.run(
                          in: container,
                          sourceSchemaVersion: hrtSourceSchemaVersion
                      ).didComplete else {
                    throw AppDataFailure.migrationFailed
                }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory
                    .makeHrtJourneyLifecycleContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback: .migrationFailed
            )
        }
    }

    private func validateAndBackfillParentRecordLifecycle(
        storeURL: URL,
        onboardingSource: OnboardingBackfillSource,
        hrtSourceSchemaVersion: String,
        parentSourceSchemaVersion: String,
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
                let container = try AppModelContainerFactory
                    .makeParentRecordLifecycleContainer(at: storeURL)
                guard try LegacyV1Backfill.run(in: container).didComplete,
                      try CoreTimeRegimenBackfill.run(in: container)
                        .didComplete,
                      try TodayExecutionBackfill.run(in: container)
                        .didComplete,
                      try PersonalTimelineBackfill.run(in: container)
                        .didComplete,
                      try CountdownLifecycleBackfill.run(in: container)
                        .didComplete,
                      try CountdownIntegrityBackfill.run(in: container)
                        .didComplete,
                      try OnboardingBackfill.run(
                          in: container,
                          source: onboardingSource
                      ).didComplete,
                      try HrtJourneyLifecycleBackfill.run(
                          in: container,
                          sourceSchemaVersion: hrtSourceSchemaVersion
                      ).didComplete,
                      try ParentRecordLifecycleBackfill.run(
                          in: container,
                          sourceSchemaVersion: parentSourceSchemaVersion
                      ).didComplete else {
                    throw AppDataFailure.migrationFailed
                }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory
                    .makeParentRecordLifecycleContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback: .migrationFailed
            )
        }
    }

    private func validateAndBackfillPrivacyControl(
        storeURL: URL,
        onboardingSource: OnboardingBackfillSource,
        hrtSourceSchemaVersion: String,
        parentSourceSchemaVersion: String,
        privacySource: PrivacyControlBackfillSource,
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
                let container = try AppModelContainerFactory
                    .makePrivacyControlContainer(at: storeURL)
                guard try LegacyV1Backfill.run(in: container).didComplete,
                      try CoreTimeRegimenBackfill.run(in: container)
                        .didComplete,
                      try TodayExecutionBackfill.run(in: container)
                        .didComplete,
                      try PersonalTimelineBackfill.run(in: container)
                        .didComplete,
                      try CountdownLifecycleBackfill.run(in: container)
                        .didComplete,
                      try CountdownIntegrityBackfill.run(in: container)
                        .didComplete,
                      try OnboardingBackfill.run(
                          in: container,
                          source: onboardingSource
                      ).didComplete,
                      try HrtJourneyLifecycleBackfill.run(
                          in: container,
                          sourceSchemaVersion: hrtSourceSchemaVersion
                      ).didComplete,
                      try ParentRecordLifecycleBackfill.run(
                          in: container,
                          sourceSchemaVersion: parentSourceSchemaVersion
                      ).didComplete,
                      try PrivacyControlBackfill.run(
                          in: container,
                          source: privacySource
                      ).didComplete else {
                    throw AppDataFailure.migrationFailed
                }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true,
                    includesPrivacyControlFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory
                    .makeReadOnlyPrivacyControlContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true,
                    includesPrivacyControlFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback: .migrationFailed
            )
        }
    }

    private func validateAndBackfillDataControl(
        storeURL: URL,
        onboardingSource: OnboardingBackfillSource,
        hrtSourceSchemaVersion: String,
        parentSourceSchemaVersion: String,
        privacySource: PrivacyControlBackfillSource,
        dataControlSource: DataControlBackfillSource,
        targetSchemaVersion: String = "12.0.0",
        expectedDatasetID: UUID? = nil,
        failAt failpoint: StoreBootstrapFailpoint? = nil
    ) throws -> GenerationIdentity {
        guard ["12.0.0", "13.0.0"].contains(
            targetSchemaVersion
        ) else {
            throw AppDataFailure.migrationFailed
        }
        let includesContentFavoriteFacts =
            targetSchemaVersion == "13.0.0"
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
                let container = includesContentFavoriteFacts
                    ? try AppModelContainerFactory
                        .makeContentFavoriteContainer(at: storeURL)
                    : try AppModelContainerFactory
                        .makeDataControlContainer(at: storeURL)
                guard try LegacyV1Backfill.run(
                    in: container,
                    expectedDatasetID: expectedDatasetID
                ).didComplete,
                      try CoreTimeRegimenBackfill.run(in: container)
                        .didComplete,
                      try TodayExecutionBackfill.run(in: container)
                        .didComplete,
                      try PersonalTimelineBackfill.run(in: container)
                        .didComplete,
                      try CountdownLifecycleBackfill.run(in: container)
                        .didComplete,
                      try CountdownIntegrityBackfill.run(in: container)
                        .didComplete,
                      try OnboardingBackfill.run(
                          in: container,
                          source: onboardingSource
                      ).didComplete,
                      try HrtJourneyLifecycleBackfill.run(
                          in: container,
                          sourceSchemaVersion: hrtSourceSchemaVersion
                      ).didComplete,
                      try ParentRecordLifecycleBackfill.run(
                          in: container,
                          sourceSchemaVersion: parentSourceSchemaVersion
                      ).didComplete,
                      try PrivacyControlBackfill.run(
                          in: container,
                          source: privacySource
                      ).didComplete,
                      try DataControlBackfill.run(
                          in: container,
                          source: dataControlSource
                      ).didComplete else {
                    throw AppDataFailure.migrationFailed
                }
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true,
                    includesPrivacyControlFacts: true,
                    includesDataControlFacts: true,
                    includesContentFavoriteFacts:
                        includesContentFavoriteFacts
                )
            }
            return try autoreleasepool {
                let reopened = includesContentFavoriteFacts
                    ? try AppModelContainerFactory
                        .makeReadOnlyContentFavoriteContainer(
                            at: storeURL
                        )
                    : try AppModelContainerFactory
                        .makeReadOnlyDataControlContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true,
                    includesPrivacyControlFacts: true,
                    includesDataControlFacts: true,
                    includesContentFavoriteFacts:
                        includesContentFavoriteFacts
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback: .migrationFailed
            )
        }
    }

    private func migrateAndValidateContentFavorite(
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
                let container = try AppModelContainerFactory
                    .makeContentFavoriteContainer(at: storeURL)
                _ = try validateFoundation(
                    in: ModelContext(container),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true,
                    includesPrivacyControlFacts: true,
                    includesDataControlFacts: true,
                    includesContentFavoriteFacts: true
                )
            }
            return try autoreleasepool {
                let reopened = try AppModelContainerFactory
                    .makeReadOnlyContentFavoriteContainer(at: storeURL)
                return try validateFoundation(
                    in: ModelContext(reopened),
                    failure: .migrationFailed,
                    includesCoreFacts: true,
                    includesTodayFacts: true,
                    includesPersonalTimelineFacts: true,
                    includesCountdownFacts: true,
                    includesCountdownIntegrityFacts: true,
                    includesOnboardingFacts: true,
                    includesHrtJourneyLifecycleFacts: true,
                    includesParentRecordLifecycleFacts: true,
                    includesPrivacyControlFacts: true,
                    includesDataControlFacts: true,
                    includesContentFavoriteFacts: true
                )
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(
                error,
                fallback: .migrationFailed
            )
        }
    }

    func validateV12DataInventoryFoundation(
        in context: ModelContext
    ) throws -> (
        datasetID: UUID,
        nextLocalRevision: Int64,
        factCount: Int,
        revisionCount: Int
    ) {
        let identity = try validateFoundation(
            in: context,
            failure: .corruptionSuspected,
            includesCoreFacts: true,
            includesTodayFacts: true,
            includesPersonalTimelineFacts: true,
            includesCountdownFacts: true,
            includesCountdownIntegrityFacts: true,
            includesOnboardingFacts: true,
            includesHrtJourneyLifecycleFacts: true,
            includesParentRecordLifecycleFacts: true,
            includesPrivacyControlFacts: true,
            includesDataControlFacts: true
        )
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadata = try context.fetch(metadataDescriptor)
        guard metadata.count == 1,
              metadata[0].datasetID == identity.datasetID,
              metadata[0].nextLocalRevision > 0 else {
            throw AppDataFailure.corruptionSuspected
        }
        return (
            identity.datasetID,
            metadata[0].nextLocalRevision,
            identity.factCount,
            identity.revisionCount
        )
    }

    func validateV13DataInventoryFoundation(
        in context: ModelContext
    ) throws -> (
        datasetID: UUID,
        nextLocalRevision: Int64,
        factCount: Int,
        revisionCount: Int
    ) {
        let identity = try validateFoundation(
            in: context,
            failure: .corruptionSuspected,
            includesCoreFacts: true,
            includesTodayFacts: true,
            includesPersonalTimelineFacts: true,
            includesCountdownFacts: true,
            includesCountdownIntegrityFacts: true,
            includesOnboardingFacts: true,
            includesHrtJourneyLifecycleFacts: true,
            includesParentRecordLifecycleFacts: true,
            includesPrivacyControlFacts: true,
            includesDataControlFacts: true,
            includesContentFavoriteFacts: true
        )
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadata = try context.fetch(metadataDescriptor)
        guard metadata.count == 1,
              metadata[0].datasetID == identity.datasetID,
              metadata[0].nextLocalRevision > 0 else {
            throw AppDataFailure.corruptionSuspected
        }
        return (
            identity.datasetID,
            metadata[0].nextLocalRevision,
            identity.factCount,
            identity.revisionCount
        )
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
        includesTodayFacts: Bool = false,
        includesPersonalTimelineFacts: Bool = false,
        includesCountdownFacts: Bool = false,
        includesCountdownIntegrityFacts: Bool = false,
        includesOnboardingFacts: Bool = false,
        includesHrtJourneyLifecycleFacts: Bool = false,
        includesParentRecordLifecycleFacts: Bool = false,
        includesPrivacyControlFacts: Bool = false,
        includesDataControlFacts: Bool = false,
        includesContentFavoriteFacts: Bool = false
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
            var additionalHistoricalSourceIDs: [String: Set<UUID>] = [:]
            if includesPersonalTimelineFacts {
                additionalHistoricalSourceIDs["LabSampleRecord"] = Set(
                    try context.fetch(FetchDescriptor<LabSampleRecord>()).map(\.id)
                )
                additionalHistoricalSourceIDs["StatusObservationRecord"] = Set(
                    try context.fetch(FetchDescriptor<StatusObservationRecord>()).map(\.id)
                )
            }
            try CoreRelationshipValidator.validate(
                in: context,
                failure: failure,
                administrationEventIDs: eventIDs,
                additionalHistoricalSourceIDs: additionalHistoricalSourceIDs
            )
        }
        if includesTodayFacts {
            var additionalReceiptResultTypes: Set<String> = []
            if includesPersonalTimelineFacts {
                additionalReceiptResultTypes.formUnion([
                    "LabSampleRecord",
                    "StatusMetricDefinitionRecord",
                    "StatusObservationRecord",
                    "AttachmentRecord"
                ])
            }
            if includesCountdownFacts {
                additionalReceiptResultTypes.insert(
                    "CountdownLifecycleEventRecord"
                )
            }
            if includesHrtJourneyLifecycleFacts {
                additionalReceiptResultTypes.insert(
                    "HrtJourneyLifecycleEventRecord"
                )
            }
            if includesParentRecordLifecycleFacts {
                additionalReceiptResultTypes.insert(
                    "ParentRecordMutationEventRecord"
                )
            }
            if includesPrivacyControlFacts {
                additionalReceiptResultTypes.insert(
                    "PrivacyControlRecord"
                )
            }
            if includesDataControlFacts {
                additionalReceiptResultTypes.insert(
                    "DataControlDeletionTombstoneRecord"
                )
            }
            if includesContentFavoriteFacts {
                additionalReceiptResultTypes.insert(
                    "ContentFavoriteRecord"
                )
            }
            try TodayExecutionRelationshipValidator.validate(
                in: context,
                failure: failure,
                additionalReceiptResultTypes: additionalReceiptResultTypes
            )
        }
        if includesPersonalTimelineFacts {
            try PersonalTimelineRelationshipValidator.validate(
                in: context,
                failure: failure
            )
        }
        if includesCountdownFacts {
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: failure,
                includesIntegrityFacts: includesCountdownIntegrityFacts
            )
        }
        if includesOnboardingFacts {
            try OnboardingRelationshipValidator.validate(
                in: context,
                failure: failure
            )
        }
        if includesHrtJourneyLifecycleFacts {
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: failure
            )
        }
        if includesParentRecordLifecycleFacts {
            try ParentRecordLifecycleValidator.validate(
                in: context,
                failure: failure
            )
        }
        if includesPrivacyControlFacts {
            try PrivacyControlRelationshipValidator.validate(
                in: context,
                failure: failure
            )
        }
        if includesDataControlFacts {
            try DataControlRelationshipValidator.validate(
                in: context,
                failure: failure
            )
        }
        if includesContentFavoriteFacts {
            try ContentFavoriteRelationshipValidator.validate(
                in: context,
                failure: failure
            )
        }

        let facts = try factIdentities(
            in: context,
            includesCoreFacts: includesCoreFacts,
            includesTodayFacts: includesTodayFacts,
            includesPersonalTimelineFacts: includesPersonalTimelineFacts,
            includesCountdownFacts: includesCountdownFacts,
            includesCountdownIntegrityFacts:
                includesCountdownIntegrityFacts,
            includesOnboardingFacts: includesOnboardingFacts,
            includesHrtJourneyLifecycleFacts:
                includesHrtJourneyLifecycleFacts,
            includesParentRecordLifecycleFacts:
                includesParentRecordLifecycleFacts,
            includesPrivacyControlFacts:
                includesPrivacyControlFacts,
            includesDataControlFacts:
                includesDataControlFacts,
            includesContentFavoriteFacts:
                includesContentFavoriteFacts
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
        includesTodayFacts: Bool = false,
        includesPersonalTimelineFacts: Bool = false,
        includesCountdownFacts: Bool = false,
        includesCountdownIntegrityFacts: Bool = false,
        includesOnboardingFacts: Bool = false,
        includesHrtJourneyLifecycleFacts: Bool = false,
        includesParentRecordLifecycleFacts: Bool = false,
        includesPrivacyControlFacts: Bool = false,
        includesDataControlFacts: Bool = false,
        includesContentFavoriteFacts: Bool = false
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
                fields: try CoreFactDigestV1.historicalTime($0)
            )
        }
        guard includesTodayFacts else { return facts }
        facts += try context.fetch(FetchDescriptor<AdministrationEventRecord>()).map {
            try coreFactIdentity(
                recordType: "AdministrationEventRecord",
                recordID: $0.id,
                fields: try TodayExecutionDigestV1.administrationEvent($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<ReminderOverrideRecord>()).map {
            try coreFactIdentity(
                recordType: "ReminderOverrideRecord",
                recordID: $0.id,
                fields: try TodayExecutionDigestV1.reminderOverride($0)
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
                fields: try TodayExecutionDigestV1.operationReceipt($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<OperationReceiptLedgerRecord>()).map {
            try coreFactIdentity(
                recordType: "OperationReceiptLedgerRecord",
                recordID: TodayExecutionDigestV1.receiptLedgerID,
                fields: TodayExecutionDigestV1.operationReceiptLedger($0)
            )
        }
        guard includesPersonalTimelineFacts else { return facts }
        facts += try context.fetch(FetchDescriptor<LabItemDefinitionRecord>()).map {
            try coreFactIdentity(
                recordType: "LabItemDefinitionRecord",
                recordID: $0.id,
                fields: try PersonalTimelineDigestV1.labItemDefinition($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<LabSampleRecord>()).map {
            try coreFactIdentity(
                recordType: "LabSampleRecord",
                recordID: $0.id,
                fields: try PersonalTimelineDigestV1.labSample($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<LabResultRecord>()).map {
            try coreFactIdentity(
                recordType: "LabResultRecord",
                recordID: $0.id,
                fields: try PersonalTimelineDigestV1.labResult($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<StatusMetricDefinitionRecord>()).map {
            try coreFactIdentity(
                recordType: "StatusMetricDefinitionRecord",
                recordID: $0.id,
                fields: try StatusDigestV1.metric($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<StatusObservationRecord>()).map {
            try coreFactIdentity(
                recordType: "StatusObservationRecord",
                recordID: $0.id,
                fields: try StatusDigestV1.observation($0)
            )
        }
        facts += try context.fetch(FetchDescriptor<AttachmentRecord>()).map {
            try coreFactIdentity(
                recordType: "AttachmentRecord",
                recordID: $0.id,
                fields: try AttachmentDigestV1.record($0)
            )
        }
        guard includesCountdownFacts else { return facts }
        facts += try context.fetch(FetchDescriptor<CountdownStateRecord>()).map {
            try coreFactIdentity(
                recordType: "CountdownStateRecord",
                recordID: $0.id,
                fields: try CountdownDigestV1.state($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "CountdownLifecycleEventRecord",
                recordID: $0.id,
                fields: try CountdownDigestV1.event($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<CountdownReminderRuleRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "CountdownReminderRuleRecord",
                recordID: $0.id,
                fields: try CountdownDigestV1.reminder($0)
            )
        }
        guard includesCountdownIntegrityFacts else { return facts }
        facts += try context.fetch(
            FetchDescriptor<CountdownCommandAuditRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "CountdownCommandAuditRecord",
                recordID: $0.eventID,
                fields: try CountdownIntegrityDigest.revisionFields($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<CountdownV6AuditCheckpointRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "CountdownV6AuditCheckpointRecord",
                recordID: $0.countdownID,
                fields:
                    try CountdownIntegrityDigest
                        .checkpointRevisionFields($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<CountdownIntegrityBackfillState>()
        ).map {
            try coreFactIdentity(
                recordType: "CountdownIntegrityBackfillState",
                recordID: CoreTimeRegimenBackfill.stableUUID(
                    for: $0.taskKey
                ),
                fields: try CountdownIntegrityDigest.backfillState($0)
            )
        }
        if includesOnboardingFacts {
            facts += try context.fetch(
                FetchDescriptor<OnboardingProgressRecord>()
            ).map {
                try coreFactIdentity(
                    recordType: "OnboardingProgressRecord",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: $0.singletonKey
                    ),
                    fields: try OnboardingDigestV1.progress($0)
                )
            }
            facts += try context.fetch(
                FetchDescriptor<OnboardingBackfillState>()
            ).map {
                try coreFactIdentity(
                    recordType: "OnboardingBackfillState",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: $0.taskKey
                    ),
                    fields: try OnboardingDigestV1.backfillState($0)
                )
            }
        }
        guard includesHrtJourneyLifecycleFacts else { return facts }
        facts += try context.fetch(
            FetchDescriptor<HrtJourneyLifecycleEventRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "HrtJourneyLifecycleEventRecord",
                recordID: $0.id,
                fields: try HrtJourneyLifecycleDigest.event($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<HrtJourneyLifecycleBackfillState>()
        ).map {
            try coreFactIdentity(
                recordType: "HrtJourneyLifecycleBackfillState",
                recordID: CoreTimeRegimenBackfill.stableUUID(
                    for: $0.taskKey
                ),
                fields: try HrtJourneyLifecycleDigest.backfillState($0)
            )
        }
        guard includesParentRecordLifecycleFacts else { return facts }
        facts += try context.fetch(
            FetchDescriptor<ParentRecordLifecycleHeadRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "ParentRecordLifecycleHeadRecord",
                recordID:
                    ParentRecordLifecycleBackfill.stableHeadID(
                        for: $0.parentKey
                    ),
                fields: try ParentRecordLifecycleDigest.head($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<ParentRecordMutationEventRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "ParentRecordMutationEventRecord",
                recordID: $0.id,
                fields: try ParentRecordLifecycleDigest.event($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<LabSampleCorrectionSnapshotRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "LabSampleCorrectionSnapshotRecord",
                recordID: $0.id,
                fields: try ParentRecordLifecycleDigest.labCorrection($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<LabResultCorrectionSnapshotRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "LabResultCorrectionSnapshotRecord",
                recordID: $0.id,
                fields:
                    ParentRecordLifecycleDigest.labResultCorrection($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<StatusObservationCorrectionSnapshotRecord>()
        ).map {
            try coreFactIdentity(
                recordType:
                    "StatusObservationCorrectionSnapshotRecord",
                recordID: $0.id,
                fields:
                    try ParentRecordLifecycleDigest.statusCorrection($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<ParentRecordDeletionTombstoneRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "ParentRecordDeletionTombstoneRecord",
                recordID: $0.id,
                fields: try ParentRecordLifecycleDigest.tombstone($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<ParentRecordLifecycleBackfillState>()
        ).map {
            try coreFactIdentity(
                recordType: "ParentRecordLifecycleBackfillState",
                recordID: CoreTimeRegimenBackfill.stableUUID(
                    for: $0.taskKey
                ),
                fields:
                    try ParentRecordLifecycleDigest.backfillState($0)
            )
        }
        guard includesPrivacyControlFacts else { return facts }
        facts += try context.fetch(
            FetchDescriptor<PrivacyControlRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "PrivacyControlRecord",
                recordID: PrivacyControlRecord.stableID,
                fields: try PrivacyControlDigestV1.record($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<PrivacyControlBackfillState>()
        ).map {
            try coreFactIdentity(
                recordType: "PrivacyControlBackfillState",
                recordID: PrivacyControlBackfillState.stableID,
                fields: try PrivacyControlDigestV1.backfillState($0)
            )
        }
        guard includesDataControlFacts else { return facts }
        facts += try context.fetch(
            FetchDescriptor<DataControlDeletionTombstoneRecord>()
        ).map {
            try coreFactIdentity(
                recordType: "DataControlDeletionTombstoneRecord",
                recordID: $0.id,
                fields: try DataControlDigestV1.tombstone($0)
            )
        }
        facts += try context.fetch(
            FetchDescriptor<DataControlBackfillState>()
        ).map {
            try coreFactIdentity(
                recordType: "DataControlBackfillState",
                recordID: DataControlBackfillState.stableID,
                fields: try DataControlDigestV1.backfillState($0)
            )
        }
        guard includesContentFavoriteFacts else { return facts }
        facts += try context.fetch(
            FetchDescriptor<ContentFavoriteRecord>()
        ).map {
            try coreFactIdentity(
                recordType: ContentFavoriteContract.recordType,
                recordID: $0.id,
                fields: try ContentFavoriteDigestV1.record($0)
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
            if pointer.schemaVersion == "13.0.0" {
                container = try AppModelContainerFactory
                    .makeContentFavoriteContainer(at: storeURL)
            } else if pointer.schemaVersion == "12.0.0" {
                container = try AppModelContainerFactory
                    .makeDataControlContainer(at: storeURL)
            } else if pointer.schemaVersion == "11.0.0" {
                container = try AppModelContainerFactory
                    .makePrivacyControlContainer(at: storeURL)
            } else if pointer.schemaVersion == "10.0.0" {
                container = try AppModelContainerFactory
                    .makeParentRecordLifecycleContainer(at: storeURL)
            } else if pointer.schemaVersion == "9.0.0" {
                container = try AppModelContainerFactory
                    .makeHrtJourneyLifecycleContainer(at: storeURL)
            } else if pointer.schemaVersion == "8.0.0" {
                container = try AppModelContainerFactory
                    .makeCountdownLifecycleContainer(at: storeURL)
            } else if pointer.schemaVersion == "7.0.0" {
                container = try AppModelContainerFactory
                    .makeV7CountdownIntegrityContainer(at: storeURL)
            } else if pointer.schemaVersion == "6.0.0" {
                container = try AppModelContainerFactory
                    .makeV6CountdownLifecycleContainer(at: storeURL)
            } else if pointer.schemaVersion == "5.0.0" {
                container = try AppModelContainerFactory
                    .makePersonalTimelineContainer(at: storeURL)
            } else if pointer.schemaVersion == "4.0.0" {
                container = try AppModelContainerFactory.makeTodayContainer(at: storeURL)
            } else if pointer.schemaVersion == "3.0.0" {
                container = try AppModelContainerFactory.makeCoreContainer(at: storeURL)
            } else {
                container = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            }
            _ = try LegacyV1Backfill.run(in: container)
            if [
                "3.0.0", "4.0.0", "5.0.0",
                "6.0.0", "7.0.0", "8.0.0", "9.0.0",
                "10.0.0", "11.0.0", "12.0.0", "13.0.0"
            ]
                .contains(pointer.schemaVersion) {
                _ = try CoreTimeRegimenBackfill.run(in: container)
            }
            if [
                "4.0.0", "5.0.0", "6.0.0",
                "7.0.0", "8.0.0", "9.0.0", "10.0.0",
                "11.0.0", "12.0.0", "13.0.0"
            ]
                .contains(pointer.schemaVersion) {
                _ = try TodayExecutionBackfill.run(in: container)
            }
            if [
                "5.0.0", "6.0.0", "7.0.0", "8.0.0", "9.0.0",
                "10.0.0", "11.0.0", "12.0.0", "13.0.0"
            ]
                .contains(pointer.schemaVersion) {
                _ = try PersonalTimelineBackfill.run(in: container)
                if [
                    "6.0.0", "7.0.0", "8.0.0", "9.0.0",
                    "10.0.0", "11.0.0", "12.0.0", "13.0.0"
                ].contains(
                    pointer.schemaVersion
                ) {
                    _ = try CountdownLifecycleBackfill.run(
                        in: container,
                        includeIntegrityFacts:
                            [
                                "7.0.0", "8.0.0", "9.0.0",
                                "10.0.0", "11.0.0", "12.0.0",
                                "13.0.0"
                            ].contains(
                                pointer.schemaVersion
                            )
                    )
                }
                if [
                    "8.0.0", "9.0.0", "10.0.0", "11.0.0",
                    "12.0.0", "13.0.0"
                ].contains(
                    pointer.schemaVersion
                ) {
                    _ = try OnboardingBackfill.run(
                        in: container,
                        source: .newInstallV8
                    )
                }
                if [
                    "9.0.0", "10.0.0", "11.0.0", "12.0.0",
                    "13.0.0"
                ].contains(
                    pointer.schemaVersion
                ) {
                    _ = try HrtJourneyLifecycleBackfill.run(
                        in: container,
                        sourceSchemaVersion: "9.0.0"
                    )
                }
                if [
                    "10.0.0", "11.0.0", "12.0.0", "13.0.0"
                ].contains(
                    pointer.schemaVersion
                ) {
                    _ = try ParentRecordLifecycleBackfill.run(
                        in: container,
                        sourceSchemaVersion: "9.0.0"
                    )
                }
                if [
                    "11.0.0", "12.0.0", "13.0.0"
                ].contains(pointer.schemaVersion) {
                    _ = try PrivacyControlBackfill.run(
                        in: container,
                        source: pointer.origin == .schemaUpgrade
                            ? .schemaUpgradeV10
                            : .bootstrapV11
                    )
                }
                if [
                    "12.0.0", "13.0.0"
                ].contains(pointer.schemaVersion) {
                    _ = try DataControlBackfill.run(
                        in: container,
                        source: pointer.origin == .schemaUpgrade
                            ? .schemaUpgradeV11
                            : .bootstrapV12
                    )
                }
                let context = ModelContext(container)
                let records = try context.fetch(FetchDescriptor<AttachmentRecord>())
                let activeRecords = records.filter { $0.deletedAt == nil }
                let attachments = activeRecords.compactMap(AttachmentSnapshot.init)
                guard attachments.count == activeRecords.count else {
                    throw AppDataFailure.corruptionSuspected
                }
                var committedAttachments: [UUID: AttachmentCommittedImport] = [:]
                for record in activeRecords {
                    guard let attachment = AttachmentSnapshot(record),
                          committedAttachments.updateValue(
                            AttachmentCommittedImport(
                                operationID: record.operationID,
                                attachment: attachment
                            ),
                            forKey: record.id
                          ) == nil else {
                        throw AppDataFailure.corruptionSuspected
                    }
                }
                var committedDeletions: [UUID: AttachmentCommittedDeletion] = [:]
                for record in records where record.deletedAt != nil {
                    guard let operationID = record.deleteOperationID,
                          let attachment = AttachmentSnapshot(record),
                          committedDeletions.updateValue(
                            AttachmentCommittedDeletion(
                                operationID: operationID,
                                attachment: attachment
                            ),
                            forKey: record.id
                          ) == nil else {
                        throw AppDataFailure.corruptionSuspected
                    }
                }
                let attachmentStore = AttachmentFileStore(
                    rootURL: layout.generationDirectoryURL(for: pointer.generationID)
                        .appendingPathComponent("Files", isDirectory: true)
                )
                _ = try attachmentStore.recover(
                    committedAttachments: committedAttachments,
                    committedDeletions: committedDeletions
                )
                try attachmentStore.audit(attachments)
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
                ),
                layout: layout
            )
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: .storageUnavailable)
        }
    }

    private func validateAttachmentsBeforeActivation(
        generationID: UUID,
        containerAt storeURL: URL,
        schemaVersion: String = "13.0.0",
        failure: AppDataFailure
    ) throws {
        do {
            let container: ModelContainer
            if schemaVersion == "13.0.0" {
                container = try AppModelContainerFactory
                    .makeContentFavoriteContainer(at: storeURL)
            } else if schemaVersion == "12.0.0" {
                container = try AppModelContainerFactory
                    .makeDataControlContainer(at: storeURL)
            } else if schemaVersion == "11.0.0" {
                container = try AppModelContainerFactory
                    .makePrivacyControlContainer(at: storeURL)
            } else if schemaVersion == "10.0.0" {
                container = try AppModelContainerFactory
                    .makeParentRecordLifecycleContainer(at: storeURL)
            } else if schemaVersion == "7.0.0" {
                container = try AppModelContainerFactory
                    .makeV7CountdownIntegrityContainer(at: storeURL)
            } else if schemaVersion == "8.0.0" {
                container = try AppModelContainerFactory
                    .makeCountdownLifecycleContainer(at: storeURL)
            } else if schemaVersion == "9.0.0" {
                container = try AppModelContainerFactory
                    .makeHrtJourneyLifecycleContainer(at: storeURL)
            } else {
                throw failure
            }
            let context = ModelContext(container)
            let records = try context.fetch(
                FetchDescriptor<AttachmentRecord>()
            )
            let activeRecords = records.filter { $0.deletedAt == nil }
            let attachments = activeRecords.compactMap(AttachmentSnapshot.init)
            guard attachments.count == activeRecords.count else {
                throw failure
            }
            var committedAttachments: [UUID: AttachmentCommittedImport] = [:]
            for record in activeRecords {
                guard let attachment = AttachmentSnapshot(record),
                      committedAttachments.updateValue(
                        AttachmentCommittedImport(
                            operationID: record.operationID,
                            attachment: attachment
                        ),
                        forKey: record.id
                      ) == nil else {
                    throw failure
                }
            }
            var committedDeletions: [UUID: AttachmentCommittedDeletion] = [:]
            for record in records where record.deletedAt != nil {
                guard let operationID = record.deleteOperationID,
                      let attachment = AttachmentSnapshot(record),
                      committedDeletions.updateValue(
                        AttachmentCommittedDeletion(
                            operationID: operationID,
                            attachment: attachment
                        ),
                        forKey: record.id
                      ) == nil else {
                    throw failure
                }
            }
            let attachmentStore = AttachmentFileStore(
                rootURL: layout.generationDirectoryURL(for: generationID)
                    .appendingPathComponent("Files", isDirectory: true)
            )
            _ = try attachmentStore.recover(
                committedAttachments: committedAttachments,
                committedDeletions: committedDeletions
            )
            try attachmentStore.audit(attachments)
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw AppDataFailure.classifyStorage(error, fallback: failure)
        }
    }

    private func validateFileProtectionBeforeActivation(
        generationID: UUID,
        storeURL: URL,
        failAt failpoint: StoreBootstrapFailpoint?
    ) throws {
        if failpoint == .duringFileProtectionValidationBeforePointer {
            throw StoreBootstrapInterruption.injected
        }
        let report = try StoreFileProtectionAuditor(
            backupPolicy: backupPolicy,
            verificationMode: fileProtectionVerificationMode
        )
        .hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(for: generationID)
        )
        guard report.isAcceptableForCurrentPlatform else {
            throw AppDataFailure.fileProtectionUnverified
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
                let includesCoreFacts = [
                    "3.0.0", "4.0.0", "5.0.0",
                    "6.0.0", "7.0.0", "8.0.0", "9.0.0",
                    "10.0.0", "11.0.0", "12.0.0", "13.0.0"
                ].contains(schemaVersion)
                let includesTodayFacts = [
                    "4.0.0", "5.0.0", "6.0.0",
                    "7.0.0", "8.0.0", "9.0.0", "10.0.0",
                    "11.0.0", "12.0.0", "13.0.0"
                ].contains(schemaVersion)
                let includesPersonalTimelineFacts = [
                    "5.0.0", "6.0.0", "7.0.0", "8.0.0",
                    "9.0.0", "10.0.0", "11.0.0", "12.0.0",
                    "13.0.0"
                ].contains(schemaVersion)
                let includesCountdownFacts = [
                    "6.0.0", "7.0.0", "8.0.0", "9.0.0",
                    "10.0.0", "11.0.0", "12.0.0", "13.0.0"
                ].contains(schemaVersion)
                let includesCountdownIntegrityFacts = [
                    "7.0.0", "8.0.0", "9.0.0", "10.0.0",
                    "11.0.0", "12.0.0", "13.0.0"
                ].contains(schemaVersion)
                let includesOnboardingFacts =
                    [
                        "8.0.0", "9.0.0", "10.0.0", "11.0.0",
                        "12.0.0", "13.0.0"
                    ].contains(
                        schemaVersion
                    )
                let includesHrtJourneyLifecycleFacts =
                    [
                        "9.0.0", "10.0.0", "11.0.0", "12.0.0",
                        "13.0.0"
                    ].contains(
                        schemaVersion
                    )
                let includesParentRecordLifecycleFacts =
                    [
                        "10.0.0", "11.0.0", "12.0.0", "13.0.0"
                    ].contains(
                        schemaVersion
                    )
                let includesPrivacyControlFacts =
                    ["11.0.0", "12.0.0", "13.0.0"].contains(
                        schemaVersion
                    )
                let includesDataControlFacts =
                    ["12.0.0", "13.0.0"].contains(schemaVersion)
                let includesContentFavoriteFacts =
                    schemaVersion == "13.0.0"
                let container: ModelContainer
                if includesContentFavoriteFacts {
                    container = try AppModelContainerFactory
                        .makeReadOnlyContentFavoriteContainer(
                            at: storeURL
                        )
                } else if includesDataControlFacts {
                    container = try AppModelContainerFactory
                        .makeReadOnlyDataControlContainer(at: storeURL)
                } else if includesPrivacyControlFacts {
                    container = try AppModelContainerFactory
                        .makeReadOnlyPrivacyControlContainer(at: storeURL)
                } else if includesParentRecordLifecycleFacts {
                    container = try AppModelContainerFactory
                        .makeReadOnlyParentRecordLifecycleContainer(
                            at: storeURL
                        )
                } else if includesHrtJourneyLifecycleFacts {
                    container = try AppModelContainerFactory
                        .makeReadOnlyHrtJourneyLifecycleContainer(at: storeURL)
                } else if includesOnboardingFacts {
                    container = try AppModelContainerFactory
                        .makeReadOnlyCountdownLifecycleContainer(at: storeURL)
                } else if includesCountdownIntegrityFacts {
                    container = try AppModelContainerFactory
                        .makeV7CountdownIntegrityContainer(
                            at: storeURL,
                            allowsSave: false
                        )
                } else if includesCountdownFacts {
                    container = try AppModelContainerFactory
                        .makeV6CountdownLifecycleContainer(
                            at: storeURL,
                            allowsSave: false
                        )
                } else if includesPersonalTimelineFacts {
                    container = try AppModelContainerFactory
                        .makeReadOnlyPersonalTimelineContainer(at: storeURL)
                } else if includesTodayFacts {
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
                    includesTodayFacts: includesTodayFacts,
                    includesPersonalTimelineFacts: includesPersonalTimelineFacts,
                    includesCountdownFacts: includesCountdownFacts,
                    includesCountdownIntegrityFacts:
                        includesCountdownIntegrityFacts,
                    includesOnboardingFacts: includesOnboardingFacts,
                    includesHrtJourneyLifecycleFacts:
                        includesHrtJourneyLifecycleFacts,
                    includesParentRecordLifecycleFacts:
                        includesParentRecordLifecycleFacts,
                    includesPrivacyControlFacts:
                        includesPrivacyControlFacts,
                    includesDataControlFacts:
                        includesDataControlFacts,
                    includesContentFavoriteFacts:
                        includesContentFavoriteFacts
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

    private func validateFreshPreparingGenerationLayout(
        _ id: UUID
    ) throws {
        let generationURL =
            layout.generationDirectoryURL(for: id)
        guard fileManager.fileExists(
            atPath: generationURL.path
        ) else {
            return
        }
        try validateFreshDirectory(
            generationURL,
            allowedChildren: ["Store"]
        )
        let storeDirectory = layout.storeDirectoryURL(for: id)
        if fileManager.fileExists(
            atPath: storeDirectory.path
        ) {
            try validateFreshDirectory(
                storeDirectory,
                allowedChildren: []
            )
        }
    }

    private func validateFreshPreparedGenerationLayout(
        _ id: UUID
    ) throws {
        let generationURL =
            layout.generationDirectoryURL(for: id)
        try validateFreshDirectory(
            generationURL,
            allowedChildren: ["Store"],
            requiresAllChildren: true
        )
        try validateFreshDirectory(
            layout.storeDirectoryURL(for: id),
            allowedChildren: []
        )
    }

    private func validateFreshResetGenerationLayout(
        _ id: UUID,
        requiresCompleteStore: Bool
    ) throws {
        let generationURL =
            layout.generationDirectoryURL(for: id)
        let generationValues = try generationURL
            .resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
        guard generationValues.isDirectory == true,
              generationValues.isSymbolicLink != true else {
            throw AppDataFailure.corruptionSuspected
        }
        let generationChildren = try fileManager
            .contentsOfDirectory(
                at: generationURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        let generationNames = Set(
            generationChildren.map(\.lastPathComponent)
        )
        guard generationNames.count
                == generationChildren.count,
              generationNames.contains("Store"),
              generationNames.isSubset(
                  of: ["Store", "Files"]
              ),
              !requiresCompleteStore
                || generationNames
                    == Set(["Store", "Files"]),
              try generationChildren.allSatisfy({
                  let values = try $0.resourceValues(
                      forKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey
                      ]
                  )
                  return values.isDirectory == true
                      && values.isSymbolicLink != true
              }) else {
            throw AppDataFailure.corruptionSuspected
        }

        let storeDirectory =
            layout.storeDirectoryURL(for: id)
        let storeChildren = try fileManager
            .contentsOfDirectory(
                at: storeDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        let storeNames = Set(
            storeChildren.map(\.lastPathComponent)
        )
        let allowedStoreNames: Set<String> = [
            "user.sqlite",
            "user.sqlite-shm",
            "user.sqlite-wal"
        ]
        guard storeNames.count == storeChildren.count,
              storeNames.isSubset(of: allowedStoreNames),
              !requiresCompleteStore
                || storeNames.contains("user.sqlite"),
              try storeChildren.allSatisfy({
                  let values = try $0.resourceValues(
                      forKeys: [
                          .isRegularFileKey,
                          .isSymbolicLinkKey
                      ]
                  )
                  return values.isRegularFile == true
                      && values.isSymbolicLink != true
              }) else {
            throw AppDataFailure.corruptionSuspected
        }

        let filesURL = generationURL.appendingPathComponent(
            "Files",
            isDirectory: true
        )
        guard generationNames.contains("Files") else {
            return
        }
        let fileTreeChildren = try fileManager
            .contentsOfDirectory(
                at: filesURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        let fileTreeNames = Set(
            fileTreeChildren.map(\.lastPathComponent)
        )
        let allowedFileTreeNames: Set<String> = [
            ".staging",
            ".trash",
            "Attachments"
        ]
        guard fileTreeNames.count
                == fileTreeChildren.count,
              fileTreeNames.isSubset(
                  of: allowedFileTreeNames
              ),
              !requiresCompleteStore
                || fileTreeNames
                    == allowedFileTreeNames,
              try fileTreeChildren.allSatisfy({
                  let values = try $0.resourceValues(
                      forKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey
                      ]
                  )
                  guard values.isDirectory == true,
                        values.isSymbolicLink != true else {
                      return false
                  }
                  return try fileManager
                      .contentsOfDirectory(
                          at: $0,
                          includingPropertiesForKeys: nil,
                          options: []
                      )
                      .isEmpty
              }) else {
            throw AppDataFailure.corruptionSuspected
        }
    }

    private func validateFreshResetControlLayout()
        throws {
        let pointerChildren = try fileManager
            .contentsOfDirectory(
                at: layout.pointerDirectoryURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        let pointerNames = Set(
            pointerChildren.map(\.lastPathComponent)
        )
        guard pointerNames.count
                == pointerChildren.count,
              pointerNames.isEmpty
                || pointerNames
                    == Set(["active.json"]),
              try pointerChildren.allSatisfy({
                  let values = try $0.resourceValues(
                      forKeys: [
                          .isRegularFileKey,
                          .isSymbolicLinkKey
                      ]
                  )
                  return values.isRegularFile == true
                      && values.isSymbolicLink != true
              }) else {
            throw AppDataFailure.corruptionSuspected
        }

        let recoveryChildren = try fileManager
            .contentsOfDirectory(
                at: layout.recoveryURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        let recoveryNames = Set(
            recoveryChildren.map(\.lastPathComponent)
        )
        guard recoveryNames.count
                == recoveryChildren.count,
              recoveryNames.isEmpty
                || recoveryNames
                    == Set([
                        "migration-journal.json"
                    ]),
              try recoveryChildren.allSatisfy({
                  let values = try $0.resourceValues(
                      forKeys: [
                          .isRegularFileKey,
                          .isSymbolicLinkKey
                      ]
                  )
                  return values.isRegularFile == true
                      && values.isSymbolicLink != true
              }),
              pointerNames.isEmpty
                || recoveryNames
                    == Set([
                        "migration-journal.json"
                    ]) else {
            throw AppDataFailure.corruptionSuspected
        }
    }

    private func validateFreshDirectory(
        _ directory: URL,
        allowedChildren: Set<String>,
        requiresAllChildren: Bool = false
    ) throws {
        let values = try directory.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw AppDataFailure.corruptionSuspected
        }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: []
        )
        let names = Set(children.map(\.lastPathComponent))
        guard names.count == children.count,
              names.isSubset(of: allowedChildren),
              !requiresAllChildren
                || names == allowedChildren,
              try children.allSatisfy({ child in
                  let childValues = try child.resourceValues(
                      forKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey
                      ]
                  )
                  return childValues.isDirectory == true
                      && childValues.isSymbolicLink != true
              }) else {
            throw AppDataFailure.corruptionSuspected
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
        try copyGenerationFilesIfPresent(
            fromStoreURL: source,
            toStoreURL: destination
        )
        // The legacy bundle is the only recovery source until every existing
        // SQLite part has reached the inactive generation. Never mutate its
        // metadata before that safety copy is complete.
        if hardenSourceAfterCopy {
            try hardenPreservedLegacyBundle(at: source)
        }
    }

    private func copyGenerationFilesIfPresent(
        fromStoreURL sourceStoreURL: URL,
        toStoreURL destinationStoreURL: URL
    ) throws {
        let sourceGenerationURL = sourceStoreURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        let generationsRoot = layout.generationsURL.standardizedFileURL
        let generationsPrefix = generationsRoot.path + "/"
        guard sourceGenerationURL.path.hasPrefix(generationsPrefix) else {
            return
        }
        let sourceFilesURL = sourceGenerationURL
            .appendingPathComponent("Files", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceFilesURL.path) else {
            return
        }
        let sourceRootValues = try sourceFilesURL.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        )
        guard sourceRootValues.isSymbolicLink != true,
              sourceRootValues.isDirectory == true else {
            throw AppDataFailure.corruptionSuspected
        }
        let destinationFilesURL = destinationStoreURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Files", isDirectory: true)
        guard !fileManager.fileExists(atPath: destinationFilesURL.path) else {
            throw AppDataFailure.migrationFailed
        }
        try fileManager.createDirectory(
            at: destinationFilesURL,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try applyBackupPolicy(to: destinationFilesURL)
        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .isRegularFileKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: sourceFilesURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw AppDataFailure.migrationFailed
        }
        let sourcePrefix = sourceFilesURL.standardizedFileURL.path + "/"
        while let sourceItem = enumerator.nextObject() as? URL {
            let standardized = sourceItem.standardizedFileURL
            guard standardized.path.hasPrefix(sourcePrefix) else {
                throw AppDataFailure.corruptionSuspected
            }
            let relativePath = String(
                standardized.path.dropFirst(sourcePrefix.count)
            )
            guard !relativePath.isEmpty,
                  !relativePath.split(separator: "/").contains("..") else {
                throw AppDataFailure.corruptionSuspected
            }
            let values = try standardized.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw AppDataFailure.corruptionSuspected
            }
            let destinationItem = destinationFilesURL
                .appendingPathComponent(relativePath)
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: destinationItem,
                    withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.complete]
                )
                try applyBackupPolicy(to: destinationItem)
            } else if values.isRegularFile == true {
                try fileManager.copyItem(
                    at: standardized,
                    to: destinationItem
                )
                try applyCompleteFileProtection(to: destinationItem)
                try applyBackupPolicy(to: destinationItem)
            } else {
                throw AppDataFailure.corruptionSuspected
            }
        }
        if let enumerationError {
            throw AppDataFailure.classifyStorage(
                enumerationError,
                fallback: .migrationFailed
            )
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

struct ProtectedAtomicJSONWriter: Sendable {
    typealias MutationProbe = @Sendable () throws -> Void
    typealias ContentValidator =
        @Sendable (Data) -> Bool

    let backupPolicy: SystemBackupPolicy
    let beforePublish: MutationProbe
    let afterPublish: MutationProbe

    init(
        backupPolicy: SystemBackupPolicy,
        beforePublish: @escaping MutationProbe = {},
        afterPublish: @escaping MutationProbe = {}
    ) {
        self.backupPolicy = backupPolicy
        self.beforePublish = beforePublish
        self.afterPublish = afterPublish
    }

    func write<Value: Encodable>(
        _ value: Value,
        to url: URL,
        validator:
            @escaping ContentValidator = { _ in true }
    ) throws {
        try AtomicControlFileTransaction.locked {
            try writeUnlocked(
                value,
                to: url,
                validator: validator
            )
        }
    }

    func readReconciledData(
        from url: URL,
        validator:
            @escaping ContentValidator
    ) throws -> Data? {
        try AtomicControlFileTransaction.locked {
            let parentURL =
                url.deletingLastPathComponent()
            let parentDescriptor =
                parentURL.path.withCString {
                    Darwin.open(
                        $0,
                        O_RDONLY | O_DIRECTORY
                            | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            guard parentDescriptor >= 0 else {
                throw AppDataFailure
                    .storageUnavailable
            }
            defer { Darwin.close(parentDescriptor) }
            do {
                return try AtomicControlFileTransaction
                    .reconcile(
                        parentDescriptor:
                            parentDescriptor,
                        destinationName:
                            url.lastPathComponent,
                        maximumBytes: 64 * 1_024,
                        validator: validator
                    )
            } catch {
                throw AppDataFailure
                    .storageUnavailable
            }
        }
    }

    private func writeUnlocked<Value: Encodable>(
        _ value: Value,
        to url: URL,
        validator:
            @escaping ContentValidator
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let data = try JSONEncoder.unmanualFoundation.encode(value)
        guard data.count <= 64 * 1_024,
              validator(data) else {
            throw AppDataFailure.storageUnavailable
        }
        let parentURL = url.deletingLastPathComponent()
        let parentDescriptor = parentURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard parentDescriptor >= 0 else {
            throw AppDataFailure.storageUnavailable
        }
        defer { Darwin.close(parentDescriptor) }
        var parentStatus = stat()
        guard Darwin.fstat(parentDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw AppDataFailure.storageUnavailable
        }
        let destinationName = url.lastPathComponent
        guard isSafeComponent(destinationName) else {
            throw AppDataFailure.storageUnavailable
        }
        do {
            _ = try AtomicControlFileTransaction
                .reconcile(
                    parentDescriptor: parentDescriptor,
                    destinationName: destinationName,
                    maximumBytes: 64 * 1_024,
                    validator: validator
                )
        } catch {
            throw AppDataFailure.storageUnavailable
        }
        var existing = stat()
        let existingResult = destinationName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &existing,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard existingResult != 0
                || (
                    (existing.st_mode & S_IFMT) == S_IFREG
                        && existing.st_nlink == 1
                ),
              existingResult == 0 || errno == ENOENT else {
            throw AppDataFailure.storageUnavailable
        }
        let existingDescriptor: Int32?
        if existingResult == 0 {
            let openedExisting = destinationName.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard openedExisting >= 0 else {
                throw AppDataFailure.storageUnavailable
            }
            var openedExistingStatus = stat()
            guard Darwin.fstat(
                    openedExisting,
                    &openedExistingStatus
                  ) == 0,
                  sameFile(
                    existing,
                    openedExistingStatus
                  ),
                  openedExistingStatus.st_nlink == 1 else {
                Darwin.close(openedExisting)
                throw AppDataFailure.storageUnavailable
            }
            existingDescriptor = openedExisting
        } else {
            existingDescriptor = nil
        }
        defer {
            if let existingDescriptor {
                Darwin.close(existingDescriptor)
            }
        }
        let previousData: Data?
        if let existingDescriptor {
            guard existing.st_size >= 0,
                  existing.st_size <= 64 * 1_024 else {
                throw AppDataFailure.storageUnavailable
            }
            previousData = try readAll(
                from: existingDescriptor,
                byteCount: Int(existing.st_size)
            )
        } else {
            previousData = nil
        }
        let rollbackName: String?
        let rollbackDescriptor: Int32?
        let rollbackIdentity: stat?
        if let previousData {
            let rollback =
                try makeIndependentRollback(
                    previousData,
                    parentDescriptor: parentDescriptor,
                    destinationName: destinationName
                )
            rollbackName = rollback.name
            rollbackDescriptor = rollback.descriptor
            rollbackIdentity = rollback.identity
        } else {
            rollbackName = nil
            rollbackDescriptor = nil
            rollbackIdentity = nil
        }
        var removeRollbackOnExit = true
        defer {
            if let rollbackDescriptor {
                Darwin.close(rollbackDescriptor)
            }
            if removeRollbackOnExit,
               let rollbackName,
               let rollbackIdentity {
                removeOwnedEntryIfPublished(
                    name: rollbackName,
                    identity: rollbackIdentity,
                    parentDescriptor: parentDescriptor
                )
            }
        }

        let temporaryName =
            AtomicControlFileTransaction.newName(
                destinationName: destinationName,
                data: data
            )
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw AppDataFailure.storageUnavailable
        }
        var temporaryPublished = true
        var temporaryContainsPrevious = false
        var destinationPublished = false
        var commitVerified = false
        defer {
            Darwin.close(descriptor)
            if temporaryPublished,
               !temporaryContainsPrevious {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, 0)
                }
            }
        }
        do {
            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  (opened.st_mode & S_IFMT) == S_IFREG,
                  opened.st_nlink == 1 else {
                throw AppDataFailure.storageUnavailable
            }
            try applyProtection(to: descriptor)
            try writeAll(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw AppDataFailure.storageUnavailable
            }
            var temporaryStatus = stat()
            guard temporaryName.withCString({
                Darwin.fstatat(
                    parentDescriptor,
                    $0,
                    &temporaryStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0,
            sameFile(opened, temporaryStatus),
            temporaryStatus.st_nlink == 1,
            temporaryStatus.st_size == off_t(data.count)
            else {
                throw AppDataFailure.storageUnavailable
            }
            try beforePublish()
            try verifyCanonicalParent(
                parentURL,
                expected: parentStatus
            )
            let renameResult: Int32
            if existingDescriptor != nil {
                renameResult = temporaryName.withCString {
                    source in
                    destinationName.withCString {
                        destination in
                        Darwin.renameatx_np(
                            parentDescriptor,
                            source,
                            parentDescriptor,
                            destination,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
            } else {
                renameResult = temporaryName.withCString {
                    source in
                    destinationName.withCString {
                        destination in
                        Darwin.renameatx_np(
                            parentDescriptor,
                            source,
                            parentDescriptor,
                            destination,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
            }
            guard renameResult == 0 else {
                throw AppDataFailure.storageUnavailable
            }
            temporaryPublished = existingDescriptor != nil
            temporaryContainsPrevious =
                existingDescriptor != nil
            destinationPublished = true
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw AppDataFailure.storageUnavailable
            }
            try afterPublish()
            var openedAfterPublish = stat()
            var published = stat()
            guard Darwin.fstat(
                    descriptor,
                    &openedAfterPublish
                  ) == 0,
                  destinationName.withCString({
                      Darwin.fstatat(
                          parentDescriptor,
                          $0,
                          &published,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  sameFile(opened, openedAfterPublish),
                  sameFile(openedAfterPublish, published),
                  openedAfterPublish.st_nlink == 1,
                  openedAfterPublish.st_size
                    == off_t(data.count),
                  try readAll(
                    from: descriptor,
                    byteCount: data.count
                  ) == data,
                  Darwin.fsync(parentDescriptor) == 0 else {
                throw AppDataFailure.storageUnavailable
            }
            try verifyCanonicalParent(
                parentURL,
                expected: parentStatus
            )
            commitVerified = true
            if let rollbackName,
               let rollbackIdentity {
                try discardOwnedEntry(
                    name: rollbackName,
                    identity: rollbackIdentity,
                    parentDescriptor: parentDescriptor
                )
                removeRollbackOnExit = false
            }
            if let existingDescriptor {
                var priorOpened = stat()
                var priorPublished = stat()
                guard Darwin.fstat(
                        existingDescriptor,
                        &priorOpened
                      ) == 0,
                      temporaryName.withCString({
                          Darwin.fstatat(
                              parentDescriptor,
                              $0,
                              &priorPublished,
                              AT_SYMLINK_NOFOLLOW
                          )
                      }) == 0,
                      sameFile(
                        priorOpened,
                        priorPublished
                      ),
                      priorOpened.st_nlink == 1,
                      temporaryName.withCString({
                          Darwin.unlinkat(
                              parentDescriptor,
                              $0,
                              0
                          )
                      }) == 0,
                      Darwin.fsync(parentDescriptor) == 0 else {
                    throw AppDataFailure.storageUnavailable
                }
                temporaryPublished = false
                temporaryContainsPrevious = false
            }
        } catch {
            let originalError = error
            do {
                if !commitVerified,
                   destinationPublished,
                   let previousData,
                   let rollbackName,
                   let rollbackDescriptor,
                   let rollbackIdentity {
                    var currentNew = stat()
                    var currentRollback = stat()
                    var publishedRollback = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &currentNew
                          ) == 0,
                          Darwin.fstat(
                            rollbackDescriptor,
                            &currentRollback
                          ) == 0,
                          rollbackName.withCString({
                              Darwin.fstatat(
                                  parentDescriptor,
                                  $0,
                                  &publishedRollback,
                                  AT_SYMLINK_NOFOLLOW
                              )
                          }) == 0,
                          sameFile(
                            rollbackIdentity,
                            currentRollback
                          ),
                          sameFile(
                            currentRollback,
                            publishedRollback
                          ),
                          currentRollback.st_nlink == 1,
                          currentRollback.st_size
                            == off_t(previousData.count),
                          try readAll(
                            from: rollbackDescriptor,
                            byteCount: previousData.count
                          ) == previousData else {
                        removeRollbackOnExit = false
                        temporaryPublished = false
                        try? sanitize(descriptor)
                        throw AppDataFailure.storageUnavailable
                    }
                    var currentDestination = stat()
                    let destinationResult =
                        destinationName.withCString {
                            Darwin.fstatat(
                                parentDescriptor,
                                $0,
                                &currentDestination,
                                AT_SYMLINK_NOFOLLOW
                            )
                        }
                    let rollbackNowContainsFailedNew: Bool
                    if destinationResult == 0,
                       sameFile(
                        currentNew,
                        currentDestination
                       ) {
                        guard rollbackName.withCString({
                            source in
                            destinationName.withCString {
                                destination in
                                Darwin.renameatx_np(
                                    parentDescriptor,
                                    source,
                                    parentDescriptor,
                                    destination,
                                    UInt32(RENAME_SWAP)
                                )
                            }
                        }) == 0 else {
                            removeRollbackOnExit = false
                            temporaryPublished = false
                            throw AppDataFailure.storageUnavailable
                        }
                        rollbackNowContainsFailedNew = true
                        removeRollbackOnExit = false
                    } else if destinationResult != 0,
                              errno == ENOENT {
                        guard rollbackName.withCString({
                            source in
                            destinationName.withCString {
                                destination in
                                Darwin.renameat(
                                    parentDescriptor,
                                    source,
                                    parentDescriptor,
                                    destination
                                )
                            }
                        }) == 0 else {
                            removeRollbackOnExit = false
                            temporaryPublished = false
                            throw AppDataFailure.storageUnavailable
                        }
                        rollbackNowContainsFailedNew = false
                        removeRollbackOnExit = false
                    } else if destinationResult == 0,
                              sameFile(
                                currentRollback,
                                currentDestination
                              ) {
                        rollbackNowContainsFailedNew = false
                        removeRollbackOnExit = false
                    } else {
                        // Do not delete a foreign replacement. Preserve the
                        // independent valid rollback inode for Recovery.
                        removeRollbackOnExit = false
                        temporaryPublished = false
                        try? sanitize(descriptor)
                        throw AppDataFailure.storageUnavailable
                    }
                    var restored = stat()
                    guard destinationName.withCString({
                              Darwin.fstatat(
                                  parentDescriptor,
                                  $0,
                                  &restored,
                                  AT_SYMLINK_NOFOLLOW
                              )
                          }) == 0,
                          sameFile(
                            currentRollback,
                            restored
                          ),
                          try readAll(
                            from: rollbackDescriptor,
                            byteCount: previousData.count
                          ) == previousData,
                          Darwin.fsync(parentDescriptor) == 0 else {
                        throw AppDataFailure.storageUnavailable
                    }
                    try sanitize(descriptor)
                    if rollbackNowContainsFailedNew {
                        removeOwnedEntryIfPublished(
                            name: rollbackName,
                            identity: currentNew,
                            parentDescriptor:
                                parentDescriptor
                        )
                    }
                    if let existingDescriptor {
                        var prior = stat()
                        if Darwin.fstat(
                            existingDescriptor,
                            &prior
                        ) == 0 {
                            removeOwnedEntryIfPublished(
                                name: temporaryName,
                                identity: prior,
                                parentDescriptor:
                                    parentDescriptor
                            )
                        }
                    }
                    guard Darwin.fsync(parentDescriptor) == 0 else {
                        throw AppDataFailure.storageUnavailable
                    }
                    temporaryPublished = false
                    temporaryContainsPrevious = false
                } else if !commitVerified {
                    do {
                        try sanitize(descriptor)
                    } catch {
                        if !destinationPublished {
                            temporaryPublished = false
                        }
                        throw error
                    }
                    if destinationPublished {
                        var published = stat()
                        var opened = stat()
                        guard Darwin.fstat(
                                descriptor,
                                &opened
                              ) == 0 else {
                            throw AppDataFailure.storageUnavailable
                        }
                        if destinationName.withCString({
                            Darwin.fstatat(
                                parentDescriptor,
                                $0,
                                &published,
                                AT_SYMLINK_NOFOLLOW
                            )
                        }) == 0,
                        sameFile(opened, published) {
                            guard destinationName.withCString({
                                Darwin.unlinkat(
                                    parentDescriptor,
                                    $0,
                                    0
                                )
                            }) == 0,
                            Darwin.fsync(parentDescriptor) == 0 else {
                                throw AppDataFailure
                                    .storageUnavailable
                            }
                        }
                    }
                }
            } catch {
                throw AppDataFailure.storageUnavailable
            }
            throw originalError
        }
    }

    private func makeIndependentRollback(
        _ data: Data,
        parentDescriptor: Int32,
        destinationName: String
    ) throws -> (
        name: String,
        descriptor: Int32,
        identity: stat
    ) {
        let name =
            AtomicControlFileTransaction.oldName(
                destinationName: destinationName,
                data: data
            )
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL
                    | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw AppDataFailure.storageUnavailable
        }
        var shouldUnlink = true
        defer {
            if shouldUnlink {
                Darwin.close(descriptor)
                _ = name.withCString {
                    Darwin.unlinkat(
                        parentDescriptor,
                        $0,
                        0
                    )
                }
            }
        }
        try applyProtection(to: descriptor)
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw AppDataFailure.storageUnavailable
        }
        var opened = stat()
        var published = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              opened.st_size == off_t(data.count),
              name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(opened, published),
              try readAll(
                from: descriptor,
                byteCount: data.count
              ) == data,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw AppDataFailure.storageUnavailable
        }
        shouldUnlink = false
        return (name, descriptor, opened)
    }

    private func discardOwnedEntry(
        name: String,
        identity: stat,
        parentDescriptor: Int32
    ) throws {
        var published = stat()
        guard name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(identity, published),
              name.withCString({
                  Darwin.unlinkat(
                      parentDescriptor,
                      $0,
                      0
                  )
              }) == 0,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw AppDataFailure.storageUnavailable
        }
    }

    private func removeOwnedEntryIfPublished(
        name: String,
        identity: stat,
        parentDescriptor: Int32
    ) {
        var published = stat()
        guard name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(identity, published) else {
            return
        }
        _ = name.withCString {
            Darwin.unlinkat(
                parentDescriptor,
                $0,
                0
            )
        }
        _ = Darwin.fsync(parentDescriptor)
    }

    private func applyProtection(to descriptor: Int32) throws {
        #if !targetEnvironment(simulator)
        guard Darwin.fcntl(
            descriptor,
            F_SETPROTECTIONCLASS,
            1
        ) == 0 else {
            throw AppDataFailure.storageUnavailable
        }
        #endif
        guard backupPolicy == .excluded else {
            return
        }
        var excluded: UInt8 = 1
        let result = "com.apple.MobileBackup".withCString {
            name in
            withUnsafePointer(to: &excluded) {
                value in
                Darwin.fsetxattr(
                    descriptor,
                    name,
                    value,
                    MemoryLayout<UInt8>.size,
                    0,
                    0
                )
            }
        }
        #if targetEnvironment(simulator)
        guard result == 0
                || errno == ENOTSUP
                || errno == EOPNOTSUPP else {
            throw AppDataFailure.storageUnavailable
        }
        #else
        guard result == 0 else {
            throw AppDataFailure.storageUnavailable
        }
        #endif
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        var offset = 0
        try data.withUnsafeBytes {
            buffer in
            while offset < buffer.count {
                guard let base = buffer.baseAddress else {
                    break
                }
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw AppDataFailure.storageUnavailable
                }
                offset += written
            }
        }
        guard offset == data.count else {
            throw AppDataFailure.storageUnavailable
        }
    }

    private func readAll(
        from descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        var result = Data(count: byteCount)
        var offset = 0
        try result.withUnsafeMutableBytes {
            buffer in
            while offset < buffer.count {
                guard let base = buffer.baseAddress else {
                    break
                }
                let count = Darwin.pread(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw AppDataFailure.storageUnavailable
                }
                offset += count
            }
        }
        guard offset == byteCount else {
            throw AppDataFailure.storageUnavailable
        }
        return result
    }

    private func verifyCanonicalParent(
        _ url: URL,
        expected: stat
    ) throws {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw AppDataFailure.storageUnavailable
        }
        defer { Darwin.close(descriptor) }
        var current = stat()
        guard Darwin.fstat(descriptor, &current) == 0,
              sameFile(current, expected) else {
            throw AppDataFailure.storageUnavailable
        }
    }

    private func sanitize(_ descriptor: Int32) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw AppDataFailure.storageUnavailable
        }
    }

    private func sameFile(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT)
                == (rhs.st_mode & S_IFMT)
    }

    private func isSafeComponent(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }
}

extension JSONEncoder {
    static var unmanualFoundation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var unmanualFoundation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
