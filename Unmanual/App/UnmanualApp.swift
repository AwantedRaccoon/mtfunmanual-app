import SwiftData
import SwiftUI
import UIKit

@main
struct UnmanualApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var notificationDelegate
    @State private var theme = AppTheme()
    @State private var dataRuntime = AppDataRuntime()
    @State private var reminderRuntime: LocalReminderRuntime
    @State private var privacyCoordinator: AppPrivacyCoordinator

    init() {
#if DEBUG
        let client: any LocalNotificationClient =
            ProcessInfo.processInfo.arguments.contains(
                "-unmanual-notification-denied"
            )
            ? DebugDeniedNotificationClient()
            : UserNotificationClient()
        _reminderRuntime = State(
            initialValue: LocalReminderRuntime(client: client)
        )
#else
        _reminderRuntime = State(
            initialValue: LocalReminderRuntime()
        )
#endif
#if DEBUG
        let authenticationClient:
            any DeviceOwnerAuthenticationClient =
            ProcessInfo.processInfo.arguments.contains(
                "-unmanual-authentication-success"
            )
            ? DebugSuccessfulAuthenticationClient()
            : LocalAuthenticationClient()
#else
        let authenticationClient:
            any DeviceOwnerAuthenticationClient =
            LocalAuthenticationClient()
#endif
        _privacyCoordinator = State(
            initialValue: AppPrivacyCoordinator(
                client: authenticationClient
            )
        )
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-ui-test-notification-tap-today"
        ) {
            AppNotificationResponseRouter.route(
                identifier: "unmanual.exec.v1.ui-test"
            )
        }
#endif
        PrivacyShieldWindowController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            ScenePrivacyShieldContainer(
                isActive: scenePhase == .active
            ) {
                runtimeRoot
            }
                .environment(theme)
                .environment(
                    \.appPrivacyCoordinator,
                    privacyCoordinator
                )
                .modifier(DebugDynamicTypeOverride())
                .task {
                    privacyCoordinator.handleSceneState(
                        AppPrivacySceneState(scenePhase)
                    )
                    dataRuntime.openIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    privacyCoordinator.handleSceneState(
                        AppPrivacySceneState(phase)
                    )
                    if phase == .active { reconcileWhenReady() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .unmanualReminderInputsChanged)
                ) { notification in
                    if let result = notification.object
                        as? ReminderCoverageInvalidationResult {
                        reminderRuntime.noteReminderInputsChanged(result)
                    }
                    reconcileWhenReady()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                ) { notification in
                    reconcileForTemporalChange(notification)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.significantTimeChangeNotification
                    )
                ) { notification in
                    reconcileForTemporalChange(notification)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
                ) { notification in
                    reconcileForTemporalChange(notification)
                }
#else
            ScenePrivacyShieldContainer(
                isActive: scenePhase == .active
            ) {
                runtimeRoot
            }
                .environment(theme)
                .environment(
                    \.appPrivacyCoordinator,
                    privacyCoordinator
                )
                .task {
                    privacyCoordinator.handleSceneState(
                        AppPrivacySceneState(scenePhase)
                    )
                    dataRuntime.openIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    privacyCoordinator.handleSceneState(
                        AppPrivacySceneState(phase)
                    )
                    if phase == .active { reconcileWhenReady() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .unmanualReminderInputsChanged)
                ) { notification in
                    if let result = notification.object
                        as? ReminderCoverageInvalidationResult {
                        reminderRuntime.noteReminderInputsChanged(result)
                    }
                    reconcileWhenReady()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                ) { notification in
                    reconcileForTemporalChange(notification)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.significantTimeChangeNotification
                    )
                ) { notification in
                    reconcileForTemporalChange(notification)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
                ) { notification in
                    reconcileForTemporalChange(notification)
                }
#endif
        }
    }

    private func reconcileWhenReady() {
        guard case let .ready(session) = dataRuntime.state else { return }
        Task {
            await reconcileAndRefresh(session: session)
        }
    }

    private func reconcileForTemporalChange(_ notification: Notification) {
        guard AppReminderLifecyclePolicy.shouldReconcile(
            notificationName: notification.name
        ) else { return }
        reconcileWhenReady()
    }

    private func reconcileAndRefresh(session: AppDataSession) async {
        await AppReminderLifecycleFlow.reconcileThenRefresh(
            reconcile: {
                await reminderRuntime.reconcile(
                    reader: session.reader,
                    writer: session.writer,
                    dataControlCoordinator:
                        session.dataControlCoordinator
                )
            },
            refresh: {
                NotificationCenter.default.post(
                    name: .unmanualLocalDataChanged,
                    object: nil
                )
            }
        )
    }

    @ViewBuilder
    private var runtimeRoot: some View {
        switch dataRuntime.state {
        case .opening:
            AppDataOpeningView()
        case let .ready(session):
#if DEBUG
            AppPrivacySessionRoot(
                session: session,
                coordinator: privacyCoordinator
            ) {
                rootView
            }
                .modelContainer(session.store.container)
                .environment(\.appDataWriter, session.writer)
                .environment(\.appReadActor, session.reader)
                .environment(
                    \.appDataControlCoordinator,
                    session.dataControlCoordinator
                )
                .environment(
                    \.dataInventoryService,
                    session.dataInventoryService
                )
                .environment(
                    \.dataControlDeletionService,
                    session.dataControlDeletionService
                )
                .environment(
                    \.appDataResetAction,
                    AppDataResetAction {
                        stateDigest in
                        try await dataRuntime.beginReset(
                            confirmedStateDigest:
                                stateDigest
                        )
                    }
                )
                .environment(
                    \.portableRestoreAction,
                    session
                        .portableRestorePreparationService
                        .map { service in
                            PortableRestoreAction(
                                makePlan: {
                                    package,
                                    mode in
                                    try await service
                                        .makePlan(
                                            for: package,
                                            mode: mode
                                        )
                                },
                                confirm: {
                                    package,
                                    plan in
                                    try await dataRuntime
                                        .beginPortableRestore(
                                            package: package,
                                            plan: plan
                                        )
                                }
                            )
                        }
                )
                .environment(
                    \.attachmentMutationService,
                    session.attachmentMutationService
                )
                .environment(
                    \.attachmentIntegrityFailureHandler,
                    AttachmentIntegrityFailureHandler {
                        dataRuntime.handleAttachmentIntegrityFailure(
                            generationID: session.store.generationID
                        )
                    }
                )
                .environment(\.localReminderRuntime, reminderRuntime)
                .task {
                    await reminderRuntime.resumeAfterRecovery()
                    await DemoDataSeeder.seedIfRequested(container: session.store.container)
                    await reconcileAndRefresh(session: session)
                }
#else
            AppPrivacySessionRoot(
                session: session,
                coordinator: privacyCoordinator
            ) {
                rootView
            }
                .environment(\.appDataWriter, session.writer)
                .environment(\.appReadActor, session.reader)
                .environment(
                    \.appDataControlCoordinator,
                    session.dataControlCoordinator
                )
                .environment(
                    \.dataInventoryService,
                    session.dataInventoryService
                )
                .environment(
                    \.dataControlDeletionService,
                    session.dataControlDeletionService
                )
                .environment(
                    \.appDataResetAction,
                    AppDataResetAction {
                        stateDigest in
                        try await dataRuntime.beginReset(
                            confirmedStateDigest:
                                stateDigest
                        )
                    }
                )
                .environment(
                    \.portableRestoreAction,
                    session
                        .portableRestorePreparationService
                        .map { service in
                            PortableRestoreAction(
                                makePlan: {
                                    package,
                                    mode in
                                    try await service
                                        .makePlan(
                                            for: package,
                                            mode: mode
                                        )
                                },
                                confirm: {
                                    package,
                                    plan in
                                    try await dataRuntime
                                        .beginPortableRestore(
                                            package: package,
                                            plan: plan
                                        )
                                }
                            )
                        }
                )
                .environment(
                    \.attachmentMutationService,
                    session.attachmentMutationService
                )
                .environment(
                    \.attachmentIntegrityFailureHandler,
                    AttachmentIntegrityFailureHandler {
                        dataRuntime.handleAttachmentIntegrityFailure(
                            generationID: session.store.generationID
                        )
                    }
                )
                .environment(\.localReminderRuntime, reminderRuntime)
                .task {
                    await reminderRuntime.resumeAfterRecovery()
                    await reconcileAndRefresh(session: session)
                }
#endif
        case let .recovery(recovery):
            RecoveryModeView(recovery: recovery, retry: dataRuntime.retry)
                .task {
                    _ = await reminderRuntime.suspendForRecoveryAndClearOwnedPending()
                }
        case .resetPreparing:
            DataResetStatusView(kind: .preparing)
                .task {
                    await dataRuntime
                        .continueResetAfterSessionRelease()
                }
        case .resetRestartRequired:
            DataResetStatusView(kind: .restartRequired)
        case .resetRecovery:
            DataResetStatusView(kind: .recovery)
        case .portableRestoreRestartRequired:
            PortableRestoreStatusView(
                kind: .restartRequired
            )
        case .portableRestoreRecovery:
            PortableRestoreStatusView(
                kind: .recovery
            )
        }
    }

    @ViewBuilder
    private var rootView: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-regimen-analysis"
        ) {
            RegimenAnalysisView(regimen: RegimenAnalysisDebugFixture.regimen)
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-medication-picker") {
            NavigationStack {
                MedicationCatalogPicker(backAction: {}, chooseAction: { _ in })
            }
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-journey") {
            NavigationStack {
                JourneyView()
            }
        } else if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-archive-legacy-import"
        ) {
            LegacyArchiveDataImportSheet()
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-archive-import") {
            ArchiveDataImportSheet()
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-archive-export") {
            ArchiveDataExportSheet()
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-archive") {
            NavigationStack {
                ArchiveView()
            }
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-quick-record") {
            QuickRecordEditor(autofocus: false)
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-countdown") {
            CountdownEditor()
        } else if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-hrt-editor"
        ) {
            StartDateEditor()
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-regimen-editor") {
            RegimenVersionEditor(
                initialMedications: [
                    RegimenMedicationDraft(
                        catalogID: "estradiol-patch-placeholder",
                        name: "雌二醇透皮贴片",
                        englishName: "Estradiol",
                        detail: "产品资料待目录接入 · 贴片 · 经皮",
                        dosageForm: "贴片",
                        route: "经皮",
                        origin: .catalog
                    ),
                    RegimenMedicationDraft(
                        catalogID: "spironolactone-oral-placeholder",
                        name: "螺内酯片",
                        englishName: "Spironolactone",
                        detail: "产品资料待目录接入 · 片剂 · 口服",
                        dosageForm: "片剂",
                        route: "口服",
                        origin: .catalog
                    )
                ]
            )
        } else if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-skip-onboarding"
        ) {
            AppShellView(
                initialTab:
                    ProcessInfo.processInfo.arguments.contains(
                        "-unmanual-ui-test-initial-archive"
                    )
                    ? .archive
                    : .today
            )
        } else {
            OnboardingGateView()
        }
#else
        OnboardingGateView()
#endif
    }
}

enum AppReminderLifecyclePolicy {
    static let temporalNotificationNames: Set<Notification.Name> = [
        .NSCalendarDayChanged,
        UIApplication.significantTimeChangeNotification,
        .NSSystemTimeZoneDidChange
    ]

    static func shouldReconcile(notificationName: Notification.Name) -> Bool {
        temporalNotificationNames.contains(notificationName)
    }
}

enum AppReminderLifecycleFlow {
    @MainActor
    static func reconcileThenRefresh(
        reconcile: () async -> Bool,
        refresh: () -> Void
    ) async {
        if await reconcile() {
            refresh()
        }
    }
}

#if DEBUG
private struct DebugDynamicTypeOverride: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.arguments.contains("-unmanual-ui-test-accessibility5") {
            content.environment(\.dynamicTypeSize, .accessibility5)
        } else {
            content
        }
    }
}
#endif
