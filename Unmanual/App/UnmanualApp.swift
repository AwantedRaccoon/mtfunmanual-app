import SwiftData
import SwiftUI

@main
struct UnmanualApp: App {
    @State private var theme = AppTheme()
    @State private var dataRuntime = AppDataRuntime()

    var body: some Scene {
        WindowGroup {
#if DEBUG
            runtimeRoot
                .environment(theme)
                .modifier(DebugDynamicTypeOverride())
                .task {
                    dataRuntime.openIfNeeded()
                }
#else
            runtimeRoot
                .environment(theme)
                .task {
                    dataRuntime.openIfNeeded()
                }
#endif
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
                .task {
                    DemoDataSeeder.seedIfRequested(container: session.store.container)
                }
#else
            rootView
                .environment(\.appDataWriter, session.writer)
                .environment(\.appReadActor, session.reader)
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
