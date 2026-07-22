import SwiftUI

@MainActor
struct StartDateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appReadActor) private var appReadActor
    @Environment(AppTheme.self) private var theme

    @State private var profile: HRTProfileSnapshot?
    @State private var startDate = Date()
    @State private var hasLoadedExistingValue = false
    @State private var saveErrorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "LOCAL / START DATE",
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
                    isEnabled: !isSaving,
                    accessibilityIdentifier: "startDate.save",
                    action: save
                )
            }
            .task { await loadExistingValue() }
        }
        .tint(theme.indigo)
        .localSaveErrorAlert(message: $saveErrorMessage)
    }

    private func loadExistingValue() async {
        guard !hasLoadedExistingValue else { return }
        if let loadedSnapshot = try? await appReadActor?.todaySnapshot(),
           let profile = loadedSnapshot.profile {
            self.profile = profile
            startDate = profile.startDate
        }
        hasLoadedExistingValue = true
    }

    private func save() {
        guard !isSaving else { return }
        guard let appDataWriter else {
            saveErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        let existingID = profile?.id
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await appDataWriter.setStartDate(
                    SetStartDateCommand(
                        recordID: existingID ?? UUID(),
                        expectsExistingRecord: existingID != nil,
                        startDate: startDate
                    )
                )
                dismiss()
            } catch {
                saveErrorMessage = "开始日期仍在当前页面，请检查后再保存。"
            }
        }
    }
}
