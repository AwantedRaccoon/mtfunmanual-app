import SwiftData
import SwiftUI

@main
struct UnmanualApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var notificationDelegate
    @State private var theme = AppTheme()
    @State private var dataRuntime = AppDataRuntime()
    @State private var reminderRuntime = LocalReminderRuntime()

    var body: some Scene {
        WindowGroup {
#if DEBUG
            runtimeRoot
                .environment(theme)
                .modifier(DebugDynamicTypeOverride())
                .task {
                    dataRuntime.openIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { reconcileWhenReady() }
                }
#else
            runtimeRoot
                .environment(theme)
                .task {
                    dataRuntime.openIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { reconcileWhenReady() }
                }
#endif
        }
    }

    private func reconcileWhenReady() {
        guard case let .ready(session) = dataRuntime.state else { return }
        Task {
            await reminderRuntime.reconcile(
                reader: session.reader,
                writer: session.writer
            )
        }
    }

    @ViewBuilder
    private var runtimeRoot: some View {
        switch dataRuntime.state {
        case .opening:
            AppDataOpeningView()
        case let .ready(session):
#if DEBUG
            rootView
                .modelContainer(session.store.container)
                .environment(\.appDataWriter, session.writer)
                .environment(\.appReadActor, session.reader)
                .environment(\.localReminderRuntime, reminderRuntime)
                .task {
                    await DemoDataSeeder.seedIfRequested(container: session.store.container)
                    NotificationCenter.default.post(
                        name: .unmanualLocalDataChanged,
                        object: nil
                    )
                    await reminderRuntime.reconcile(
                        reader: session.reader,
                        writer: session.writer
                    )
                }
#else
            rootView
                .environment(\.appDataWriter, session.writer)
                .environment(\.appReadActor, session.reader)
                .environment(\.localReminderRuntime, reminderRuntime)
                .task {
                    await reminderRuntime.reconcile(
                        reader: session.reader,
                        writer: session.writer
                    )
                }
#endif
        case let .recovery(recovery):
            RecoveryModeView(recovery: recovery, retry: dataRuntime.retry)
        }
    }

    @ViewBuilder
    private var rootView: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-unmanual-medication-picker") {
            NavigationStack {
                MedicationCatalogPicker(backAction: {}, chooseAction: { _ in })
            }
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-journey") {
            NavigationStack {
                JourneyView()
            }
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
        } else {
            AppShellView()
        }
#else
        AppShellView()
#endif
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
