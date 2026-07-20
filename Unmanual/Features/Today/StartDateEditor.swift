import SwiftData
import SwiftUI

@MainActor
struct StartDateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppTheme.self) private var theme
    @Query(sort: \HRTProfile.createdAt, order: .forward) private var profiles: [HRTProfile]

    @State private var startDate = Date()
    @State private var hasLoadedExistingValue = false
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "V2.5 / START DATE",
                eyebrow: "TIME COORDINATE",
                title: "HRT 开始日",
                detail: "这一天只用来建立时间坐标，不代表身体变化的完成度。",
                cancel: dismiss.callAsFunction
            ) {
                V25FieldSurface(
                    "首次开始日期",
                    note: "之后可以随时修改；HRT 日数会按自然日重新计算。",
                    labelColor: theme.indigoDeep
                ) {
                    DatePicker(
                        "首次开始日期",
                        selection: $startDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("startDate.datePicker")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V25SaveBar(
                    title: "保存日期",
                    isEnabled: true,
                    accessibilityIdentifier: "startDate.save",
                    action: save
                )
            }
            .task { loadExistingValue() }
        }
        .tint(theme.indigo)
        .localSaveErrorAlert(message: $saveErrorMessage)
    }

    private func loadExistingValue() {
        guard !hasLoadedExistingValue else { return }
        if let profile = profiles.first {
            startDate = profile.startDate
        }
        hasLoadedExistingValue = true
    }

    private func save() {
        if let profile = profiles.first {
            profile.startDate = startDate
            if profile.activePeriodStartDate < startDate {
                profile.activePeriodStartDate = startDate
            }
        } else {
            modelContext.insert(HRTProfile(startDate: startDate))
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            saveErrorMessage = "开始日期仍在当前页面，请检查后再保存。"
        }
    }
}
