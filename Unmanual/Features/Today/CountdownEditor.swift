import SwiftUI

@MainActor
struct CountdownEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appReadActor) private var appReadActor
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var activeCountdown: CountdownRecordSnapshot?
    @State private var title = ""
    @State private var gentleTitle = ""
    @State private var targetDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var hasLoadedExistingValue = false
    @State private var saveErrorMessage: String?
    @State private var isSaving = false

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "LOCAL / COUNTDOWN",
                eyebrow: activeCountdown == nil ? "NEW DATE" : "EDIT DATE",
                title: activeCountdown == nil ? "新建倒计时" : "修改倒计时",
                detail: "名称和日期都由你决定；它可以是复诊，也可以是任何私人目标。",
                cancel: dismiss.callAsFunction
            ) {
                VStack(spacing: V25Theme.fieldSpacing) {
                    V25FieldSurface("这个日期是什么") {
                        TextField("例如：下一次复诊", text: $title, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityIdentifier("countdown.title")
                    }

                    V25FieldSurface("目标日期", labelColor: theme.indigoDeep) {
                        if dynamicTypeSize.isAccessibilitySize {
                            DatePicker("目标日期", selection: $targetDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                                .accessibilityLabel("目标日期")
                                .accessibilityIdentifier("countdown.date")
                        } else {
                            DatePicker("目标日期", selection: $targetDate, displayedComponents: .date)
                                .labelsHidden()
                                .accessibilityLabel("目标日期")
                                .accessibilityIdentifier("countdown.date")
                        }
                    }

                    V25FieldSurface(
                        "温和模式名称（可选）",
                        note: "温和模式可以使用这个名称，但不会改变系统备份设置，也不会隐藏导出文件。",
                        labelColor: theme.blueText
                    ) {
                        TextField("例如：私人日期", text: $gentleTitle, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityIdentifier("countdown.gentleTitle")
                    }
                    .accessibilityIdentifier("countdown.backupDisclosure")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V25SaveBar(
                    title: "保存倒计时",
                    isEnabled: canSave && !isSaving,
                    accessibilityIdentifier: "countdown.save",
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
        if let loadedSnapshot = try? await appReadActor?.todaySnapshot() {
            activeCountdown = loadedSnapshot.countdown
        }
        if let activeCountdown {
            title = activeCountdown.title
            gentleTitle = activeCountdown.gentleTitle ?? ""
            targetDate = activeCountdown.targetDate
        }
        hasLoadedExistingValue = true
    }

    private func save() {
        guard !isSaving else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGentleTitle = gentleTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let appDataWriter else {
            saveErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        let existingID = activeCountdown?.id
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await appDataWriter.saveCountdown(
                    SaveCountdownCommand(
                        recordID: existingID ?? UUID(),
                        expectsExistingRecord: existingID != nil,
                        title: cleanTitle,
                        gentleTitle: cleanGentleTitle.isEmpty ? nil : cleanGentleTitle,
                        targetDate: targetDate
                    )
                )
                dismiss()
            } catch {
                saveErrorMessage = "倒计时仍在当前页面，请检查后再保存。"
            }
        }
    }
}
