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

@MainActor
struct AppDataSession {
    let store: BootstrappedAppDataStore
    let writer: AppDataWriter
    let reader: AppReadActor
    let attachmentMutationService: AttachmentMutationService
    let attachmentMutationRecoveryLatch: AttachmentMutationRecoveryLatch

    init(
        store: BootstrappedAppDataStore,
        verifyStoreProtection: @escaping @Sendable (StoreFileProtectionPlan) async -> Bool,
        onProtectionFailure: @escaping @Sendable () async -> Void,
        onAttachmentIntegrityFailure: @escaping @Sendable () async -> Void
    ) {
        self.store = store
        let storage = AppWriteActor(modelContainer: store.container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: {
                guard let plan = store.protectionPlan else { return true }
                return await verifyStoreProtection(plan)
            },
            onProtectionFailure: onProtectionFailure,
            onReminderInputsChanged: { didInvalidateCoverage in
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .unmanualReminderInputsChanged,
                        object: didInvalidateCoverage
                    )
                }
            }
        )
        self.writer = writer
        self.reader = AppReadActor(modelContainer: store.container)
        let fileStore = AttachmentFileStore(rootURL: store.attachmentRootURL)
        let recoveryLatch = AttachmentMutationRecoveryLatch()
        self.attachmentMutationRecoveryLatch = recoveryLatch
        self.attachmentMutationService = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            recoveryLatch: recoveryLatch,
            onRecoveryRequired: onAttachmentIntegrityFailure
        )
    }
}

@MainActor
@Observable
final class AppDataRuntime {
    enum State {
        case opening
        case ready(AppDataSession)
        case recovery(AppDataRecoveryState)
    }

    private(set) var state: State = .opening
    private var hasAttemptedOpen = false
    private var openSequence = 0
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
        session.attachmentMutationRecoveryLatch.invalidate()
        state = .recovery(
            AppDataRecoveryState(reason: .corruptionSuspected)
        )
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

    func open() throws -> BootstrappedAppDataStore {
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
        if ProcessInfo.processInfo.arguments.contains("-unmanual-empty-store") {
            let container = try AppModelContainerFactory.makeInMemoryPersonalTimelineContainer()
            _ = try LegacyV1Backfill.run(in: container)
            _ = try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
            )
            _ = try TodayExecutionBackfill.run(in: container)
            _ = try PersonalTimelineBackfill.run(in: container)
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
                    .appendingPathComponent("Unmanual-DebugAttachments", isDirectory: true)
            )
        }
#endif
        let layout = try AppDataStoreLayout.production()
        return try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .production
        ).open()
    }
}

#if DEBUG
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
