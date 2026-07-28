import Foundation
import Observation
import SwiftData

struct AppDataRecoveryState: Equatable, Sendable {
    let reason: AppDataFailure

    var title: String {
        switch reason {
        case .protectedDataUnavailable:
            "数据暂时不可用"
        case .invalidGenerationPointer, .migrationFailed, .corruptionSuspected:
            "本地资料需要检查"
        case .storageUnavailable, .fileProtectionUnverified:
            "暂时无法打开本地资料"
        }
    }

    var userMessage: String {
        switch reason {
        case .protectedDataUnavailable:
            "设备解锁后可以重试。原数据会保留，App 不会自动建立替代资料库。"
        case .invalidGenerationPointer:
            "当前资料库的位置记录无法确认。原数据仍会保留，App 不会自动删除或改成空白资料库。"
        case .migrationFailed:
            "资料升级没有通过完整校验。旧资料会继续保留，App 不会自动删除或覆盖它。"
        case .corruptionSuspected:
            "资料库没有通过完整性检查。App 不会自动删除原数据，请先重试。"
        case .storageUnavailable:
            "本地存储暂时不可用。释放空间或稍后重试；App 不会自动删除原数据。"
        case .fileProtectionUnverified:
            "本地文件保护没有通过检查。原数据不会被自动删除，请在设备解锁后重试。"
        }
    }
}

final class AppDataSessionReleaseProbe:
    @unchecked Sendable {}

@MainActor
final class AppDataSession {
    let store: BootstrappedAppDataStore
    let releaseProbe: AppDataSessionReleaseProbe
    let dataControlCoordinator: AppDataControlCoordinator
    let writer: AppDataWriter
    let reader: AppDataReader
    let attachmentMutationService: AttachmentMutationService
    let attachmentMutationRecoveryLatch: AttachmentMutationRecoveryLatch
    let dataInventoryService: DataInventoryProductionService?
    let dataControlDeletionService: DataControlDeletionService?
    let dataResetPreparationService:
        DataResetPreparationService?

    init(
        store: BootstrappedAppDataStore,
        verifyStoreProtection: @escaping @Sendable (StoreFileProtectionPlan) async -> Bool,
        onProtectionFailure: @escaping @Sendable () async -> Void,
        onAttachmentIntegrityFailure: @escaping @Sendable () async -> Void
    ) {
        self.store = store
        let releaseProbe = AppDataSessionReleaseProbe()
        self.releaseProbe = releaseProbe
        let dataControlCoordinator = AppDataControlCoordinator(
            generationID: store.generationID
        )
        self.dataControlCoordinator = dataControlCoordinator
        let storage = AppWriteActor(modelContainer: store.container)
        let writer = AppDataWriter(
            storage: storage,
            dataControlCoordinator: dataControlCoordinator,
            verifyStoreProtection: {
                guard let plan = store.protectionPlan else { return true }
                return await verifyStoreProtection(plan)
            },
            onProtectionFailure: onProtectionFailure,
            sessionReleaseProbe: releaseProbe,
            onReminderInputsChanged: { result in
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .unmanualReminderInputsChanged,
                        object: result
                    )
                }
            }
        )
        self.writer = writer
        self.reader = AppDataReader(
            storage: AppReadActor(
                modelContainer: store.container
            ),
            dataControlCoordinator: dataControlCoordinator,
            sessionReleaseProbe: releaseProbe
        )
        let fileStore = AttachmentFileStore(rootURL: store.attachmentRootURL)
        let recoveryLatch = AttachmentMutationRecoveryLatch()
        self.attachmentMutationRecoveryLatch = recoveryLatch
        self.attachmentMutationService = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            dataControlCoordinator: dataControlCoordinator,
            recoveryLatch: recoveryLatch,
            onRecoveryRequired: onAttachmentIntegrityFailure
        )
        let dataInventoryService = DataInventoryProductionService(
            store: store,
            dataControlCoordinator: dataControlCoordinator,
            sessionReleaseProbe: releaseProbe
        )
        self.dataInventoryService = dataInventoryService
        self.dataControlDeletionService = dataInventoryService.map {
            DataControlDeletionService(
                generationID: store.generationID,
                writer: writer,
                fileStore: fileStore,
                inventoryService: $0,
                dataControlCoordinator: dataControlCoordinator,
                recoveryLatch: recoveryLatch,
                onRecoveryRequired:
                    onAttachmentIntegrityFailure
            )
        }
        self.dataResetPreparationService = dataInventoryService.map {
            DataResetPreparationService(
                store: store,
                manifestProvider: $0,
                coordinator: dataControlCoordinator
            )
        }
    }
}

@MainActor
@Observable
final class AppDataRuntime {
    enum State {
        case opening
        case ready(AppDataSession)
        case recovery(AppDataRecoveryState)
        case resetPreparing
        case resetRestartRequired
        case resetRecovery
    }

    private(set) var state: State = .opening
    private var hasAttemptedOpen = false
    private var openSequence = 0
    private var pendingResetOperation:
        DataResetPreparedOperation?
    private weak var pendingResetReleaseProbe:
        AppDataSessionReleaseProbe?
    private var isContinuingReset = false
    private let openStore: () async throws -> BootstrappedAppDataStore
    private let verifyStoreProtection: @Sendable (StoreFileProtectionPlan) async -> Bool

    init(openStore: @escaping () async throws -> BootstrappedAppDataStore) {
        self.openStore = openStore
        let worker = AppStoreFileProtectionWorker()
        self.verifyStoreProtection = { plan in
            await worker.verify(plan)
        }
    }

    init(
        openStore: @escaping () async throws -> BootstrappedAppDataStore,
        verifyStoreProtection: @escaping @Sendable (StoreFileProtectionPlan) async -> Bool
    ) {
        self.openStore = openStore
        self.verifyStoreProtection = verifyStoreProtection
    }

    convenience init() {
        let worker = AppDataBootstrapWorker()
        self.init {
            try await worker.open()
        }
    }

    func openIfNeeded() {
        guard !hasAttemptedOpen else { return }
        hasAttemptedOpen = true
        open()
    }

    func retry() {
        state = .opening
        open()
    }

    func handleAttachmentIntegrityFailure(generationID: UUID) {
        guard case let .ready(session) = state,
              session.store.generationID == generationID else { return }
        Task {
            await session.dataControlCoordinator.invalidate()
        }
        session.attachmentMutationRecoveryLatch.invalidate()
        state = .recovery(
            AppDataRecoveryState(reason: .corruptionSuspected)
        )
    }

    func beginReset(
        confirmedStateDigest: String
    ) async throws {
        guard case let .ready(session) = state,
              let service =
                session.dataResetPreparationService else {
            throw DataResetServiceFailure.unavailable
        }
        let prepared = try await service.prepare(
            confirmedStateDigest:
                confirmedStateDigest
        )
        openSequence += 1
        pendingResetOperation = prepared
        pendingResetReleaseProbe = session.releaseProbe
        state = .resetPreparing
    }

    func continueResetAfterSessionRelease() async {
        guard case .resetPreparing = state,
              !isContinuingReset,
              let operation = pendingResetOperation else {
            return
        }
        isContinuingReset = true
        defer { isContinuingReset = false }

        for _ in 0..<50
            where pendingResetReleaseProbe != nil {
            await Task.yield()
            try? await Task.sleep(
                for: .milliseconds(10)
            )
        }
        guard pendingResetReleaseProbe == nil else {
            await operation.coordinator
                .endExclusiveResetLease(operation.lease)
            pendingResetOperation = nil
            state = .resetRecovery
            return
        }
        pendingResetOperation = nil
        let worker = DataResetCurrentProcessWorker()
        do {
            let journal = try await worker
                .advanceToRestartRequired(operation)
            guard journal.phase == .restartRequired
            else {
                throw DataResetServiceFailure
                    .recoveryRequired
            }
            state = .resetRestartRequired
        } catch {
            state = .resetRecovery
        }
    }

    private func open() {
        openSequence += 1
        let sequence = openSequence
        Task {
            do {
                let store = try await openStore()
                guard sequence == openSequence else { return }
                let generationID = store.generationID
                state = .ready(
                    AppDataSession(
                        store: store,
                        verifyStoreProtection: verifyStoreProtection,
                        onProtectionFailure: { [weak self] in
                            await self?.handlePostCommitProtectionFailure(
                                generationID: generationID
                            )
                        },
                        onAttachmentIntegrityFailure: { [weak self] in
                            await self?.handleAttachmentIntegrityFailure(
                                generationID: generationID
                            )
                        }
                    )
                )
            } catch is DataResetServiceFailure {
                guard sequence == openSequence else { return }
                state = .resetRecovery
            } catch is DataResetStateMachineError {
                guard sequence == openSequence else { return }
                state = .resetRecovery
            } catch let failure as AppDataFailure {
                guard sequence == openSequence else { return }
                state = .recovery(AppDataRecoveryState(reason: failure))
            } catch {
                guard sequence == openSequence else { return }
                state = .recovery(
                    AppDataRecoveryState(
                        reason: AppDataFailure.classifyStorage(error, fallback: .storageUnavailable)
                    )
                )
            }
        }
    }

    private func handlePostCommitProtectionFailure(generationID: UUID) {
        guard case let .ready(session) = state,
              session.store.generationID == generationID else { return }
        Task {
            await session.dataControlCoordinator.invalidate()
        }
        session.attachmentMutationRecoveryLatch.invalidate()
        state = .recovery(AppDataRecoveryState(reason: .fileProtectionUnverified))
    }

}

private actor AppStoreFileProtectionWorker {
    func verify(_ plan: StoreFileProtectionPlan) -> Bool {
        do {
            return try plan.audit().isAcceptableForCurrentPlatform
        } catch {
            return false
        }
    }
}

private actor AppDataBootstrapWorker {
#if DEBUG
    private var hasConsumedOneTimeRecoveryFailure = false
#endif

    func open() async throws -> BootstrappedAppDataStore {
#if DEBUG
        switch DebugRecoveryLaunchConfiguration.mode(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ) {
        case let .always(forcedFailure):
            throw forcedFailure
        case let .once(forcedFailure) where !hasConsumedOneTimeRecoveryFailure:
            hasConsumedOneTimeRecoveryFailure = true
            throw forcedFailure
        case .once, nil:
            break
        }
        if let testStore = try DebugUITestStoreConfiguration.selection(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            let urls = try DebugUITestStoreConfiguration.urls(
                for: testStore.id
            )
            if (testStore.resetsBeforeOpen || testStore.cleansUp),
               FileManager.default.fileExists(atPath: urls.root.path) {
                try FileManager.default.removeItem(at: urls.root)
            }
            if testStore.cleansUp {
                return try await makeInMemoryDebugStore()
            }
            let resetLayout = DataResetPathLayout(
                applicationSupportURL:
                    urls.layout.rootURL
                    .deletingLastPathComponent(),
                storeLayout: urls.layout
            )
            let openedStore: BootstrappedAppDataStore
            if FileManager.default.fileExists(
                atPath: resetLayout.journalURL.path
            ) {
                openedStore = try await
                    DataResetColdLaunchCoordinator(
                        layoutProvider: {
                            urls.layout
                        },
                        fileProtectionVerificationMode:
                            .simulatorTestHarness
                    ).open()
            } else {
                openedStore = try AppDataStoreBootstrapper(
                    layout: urls.layout,
                    backupPolicy: .production,
                    fileProtectionVerificationMode:
                        .simulatorTestHarness
                ).open()
            }
            try await seedDebugHrtJourneyIfRequested(
                in: openedStore.container
            )
            return openedStore
        }
        if ProcessInfo.processInfo.arguments.contains("-unmanual-empty-store") {
            return try await makeInMemoryDebugStore()
        }
#endif
        let layout = try AppDataStoreLayout.production()
        let resetLayout = DataResetPathLayout(
            applicationSupportURL:
                layout.rootURL.deletingLastPathComponent(),
            storeLayout: layout
        )
        let resetJournalExists =
            FileManager.default.fileExists(
                atPath: resetLayout.journalURL.path
            )
        do {
            return try await DataResetColdLaunchCoordinator(
                layoutProvider: { layout }
            ).open()
        } catch {
            if resetJournalExists {
                throw DataResetServiceFailure
                    .recoveryRequired
            }
            throw error
        }
    }

#if DEBUG
    private func makeInMemoryDebugStore()
        async throws -> BootstrappedAppDataStore {
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        _ = try CountdownLifecycleBackfill.run(in: container)
        _ = try OnboardingBackfill.run(
            in: container,
            source: .newInstallV8
        )
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0"
        )
        _ = try ParentRecordLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0"
        )
        _ = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11
        )
        _ = try DataControlBackfill.run(
            in: container,
            source: .bootstrapV12
        )
        try await seedDebugHrtJourneyIfRequested(in: container)
        return BootstrappedAppDataStore(
            container: container,
            generationID: UUID(),
            storeURL: URL(fileURLWithPath: "/debug-only/in-memory.store"),
            origin: .newInstall,
            protectionReport: StoreFileProtectionReport(
                entries: [],
                requiresPhysicalDeviceValidation: true
            ),
            attachmentRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Unmanual-DebugAttachments",
                    isDirectory: true
                )
        )
    }

    private func seedDebugHrtJourneyIfRequested(
        in container: ModelContainer
    ) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsActive = arguments.contains(
            "-unmanual-hrt-active-fixture"
        )
        let wantsPaused = arguments.contains(
            "-unmanual-hrt-paused-fixture"
        )
        guard wantsActive || wantsPaused else { return }

        let now = Date()
        let timeZoneIdentifier =
            TimeZone.autoupdatingCurrent.identifier
        let timestamp = try HistoricalTimestamp.captured(
            instant: now,
            timeZoneIdentifier: timeZoneIdentifier,
            precision: .second,
            provenance: .userEntered
        )
        guard let startInstant = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -10,
            to: now
        ) else {
            throw AppDataFailure.migrationFailed
        }
        let startDate = try HistoricalTimestamp.captured(
            instant: startInstant,
            timeZoneIdentifier: timeZoneIdentifier
        ).localDate
        let writer = AppWriteActor(modelContainer: container)
        let created = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: startDate,
                note: "DEBUG UI fixture",
                timestamp: timestamp
            )
        )
        guard wantsPaused else { return }
        guard let pauseInstant = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -1,
            to: now
        ) else {
            throw AppDataFailure.migrationFailed
        }
        let pauseDate = try HistoricalTimestamp.captured(
            instant: pauseInstant,
            timeZoneIdentifier: timeZoneIdentifier
        ).localDate
        _ = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: created.eventID,
                expectedOpenPeriodID: created.periodID,
                pauseDate: pauseDate,
                note: "DEBUG UI fixture",
                timestamp: timestamp
            )
        )
    }
#endif
}

#if DEBUG
enum DebugUITestStoreConfiguration {
    struct Selection: Equatable {
        let id: UUID
        let resetsBeforeOpen: Bool
        let cleansUp: Bool
    }

    static func selection(arguments: [String]) throws -> Selection? {
        let hasStoreArgument = arguments.contains(
            "-unmanual-ui-test-store-id"
        )
        let hasStoreMutationArgument = arguments.contains(
            "-unmanual-ui-test-reset-store"
        ) || arguments.contains(
            "-unmanual-ui-test-cleanup-store"
        )
        guard hasStoreArgument || hasStoreMutationArgument else {
            return nil
        }
        guard let value = value(
            after: "-unmanual-ui-test-store-id",
            in: arguments
        ),
        let id = UUID(uuidString: value) else {
            throw AppDataFailure.storageUnavailable
        }
        return Selection(
            id: id,
            resetsBeforeOpen: arguments.contains(
                "-unmanual-ui-test-reset-store"
            ),
            cleansUp: arguments.contains(
                "-unmanual-ui-test-cleanup-store"
            )
        )
    }

    static func urls(
        for id: UUID
    ) throws -> (root: URL, layout: AppDataStoreLayout) {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppDataFailure.storageUnavailable
        }
        let root = applicationSupport
            .appendingPathComponent(
                "UnmanualUITestStores",
                isDirectory: true
            )
            .appendingPathComponent(
                id.uuidString.lowercased(),
                isDirectory: true
            )
        return (
            root,
            AppDataStoreLayout(
                rootURL: root.appendingPathComponent(
                    "Unmanual",
                    isDirectory: true
                ),
                legacyStoreURL: root
                    .appendingPathComponent("default.store")
            )
        )
    }

    private static func value(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        arguments.firstIndex(of: flag)
            .flatMap { flagIndex in
                arguments.indices.contains(flagIndex + 1)
                    ? arguments[flagIndex + 1]
                    : nil
            }
    }
}

enum DebugRecoveryLaunchConfiguration {
    enum Mode: Equatable {
        case always(AppDataFailure)
        case once(AppDataFailure)
    }

    static func failure(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> AppDataFailure? {
        mode(arguments: arguments, environment: environment)?.failure
    }

    static func mode(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> Mode? {
        if let value = value(after: "-unmanual-recovery-once", in: arguments),
           let failure = failure(named: value) {
            return .once(failure)
        }
        let argumentValue = value(after: "-unmanual-recovery", in: arguments)
        guard let value = environment["UNMANUAL_RECOVERY_REASON"] ?? argumentValue,
              let failure = failure(named: value) else {
            return nil
        }
        return .always(failure)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag)
            .flatMap { flagIndex in
                arguments.indices.contains(flagIndex + 1)
                    ? arguments[flagIndex + 1]
                    : nil
            }
    }

    private static func failure(named value: String) -> AppDataFailure? {
        switch value {
        case "protectedDataUnavailable": return .protectedDataUnavailable
        case "storageUnavailable": return .storageUnavailable
        case "migrationFailed": return .migrationFailed
        case "corruptionSuspected": return .corruptionSuspected
        case "invalidGenerationPointer": return .invalidGenerationPointer
        case "fileProtectionUnverified": return .fileProtectionUnverified
        default: return nil
        }
    }
}

private extension DebugRecoveryLaunchConfiguration.Mode {
    var failure: AppDataFailure {
        switch self {
        case let .always(failure), let .once(failure): failure
        }
    }
}
#endif
