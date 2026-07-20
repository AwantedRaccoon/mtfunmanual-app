import SwiftData
import SwiftUI

@main
struct UnmanualApp: App {
    @State private var theme = AppTheme()

    private let modelContainer: ModelContainer = {
        let schema = Schema([
            HRTProfile.self,
            CountdownRecord.self,
            RegimenVersion.self,
            JourneyEntry.self,
            LabRecord.self
        ])
        #if DEBUG
        let usesTemporaryEmptyStore = ProcessInfo.processInfo.arguments.contains("-unmanual-empty-store")
        #else
        let usesTemporaryEmptyStore = false
        #endif
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: usesTemporaryEmptyStore
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create local model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(theme)
                .task {
#if DEBUG
                    DemoDataSeeder.seedIfRequested(container: modelContainer)
#endif
                }
        }
        .modelContainer(modelContainer)
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
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-archive") {
            NavigationStack {
                ArchiveView()
            }
        } else if ProcessInfo.processInfo.arguments.contains("-unmanual-regimen-editor") {
            RegimenVersionEditor(
                initialMedications: [
                    RegimenMedicationDraft(
                        catalogID: "estradiol-patch-placeholder",
                        name: "雌二醇透皮贴片",
                        englishName: "Estradiol",
                        detail: "产品资料待目录接入 · 贴片 · 经皮",
                        origin: .catalog
                    ),
                    RegimenMedicationDraft(
                        catalogID: "spironolactone-oral-placeholder",
                        name: "螺内酯片",
                        englishName: "Spironolactone",
                        detail: "产品资料待目录接入 · 片剂 · 口服",
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
