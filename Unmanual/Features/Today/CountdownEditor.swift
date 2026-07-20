import SwiftData
import SwiftUI

@MainActor
struct CountdownEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppTheme.self) private var theme
    @Query(sort: \CountdownRecord.createdAt, order: .reverse) private var countdowns: [CountdownRecord]

    @State private var title = ""
    @State private var gentleTitle = ""
    @State private var targetDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var hasLoadedExistingValue = false
    @State private var saveErrorMessage: String?

    private var activeCountdown: CountdownRecord? {
        countdowns.first(where: { $0.archivedAt == nil })
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "V2.5 / COUNTDOWN",
                eyebrow: activeCountdown == nil ? "NEW DATE" : "EDIT DATE",
                title: activeCountdown == nil ? "新建倒计时" : "修改倒计时",
                detail: "名称和日期都由你决定；它可以是复诊，也可以是任何私人目标。",
                cancel: dismiss.callAsFunction
            ) {
                VStack(spacing: V25Theme.fieldSpacing) {
                    V25FieldSurface("这个日期是什么") {
                        TextField("例如：下一次复诊", text: $title)
                            .accessibilityIdentifier("countdown.title")
                    }

                    V25FieldSurface("目标日期", labelColor: theme.indigoDeep) {
                        DatePicker("目标日期", selection: $targetDate, displayedComponents: .date)
                            .labelsHidden()
                            .accessibilityLabel("目标日期")
                            .accessibilityIdentifier("countdown.date")
                    }

                    V25FieldSurface(
                        "温和模式名称（可选）",
                        note: "温和模式可以使用这个名称，但不会隐藏系统备份或导出文件。",
                        labelColor: theme.blue
                    ) {
                        TextField("例如：私人日期", text: $gentleTitle)
                            .accessibilityIdentifier("countdown.gentleTitle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V25SaveBar(
                    title: "保存倒计时",
                    isEnabled: canSave,
                    accessibilityIdentifier: "countdown.save",
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
        if let activeCountdown {
            title = activeCountdown.title
            gentleTitle = activeCountdown.gentleTitle ?? ""
            targetDate = activeCountdown.targetDate
        }
        hasLoadedExistingValue = true
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGentleTitle = gentleTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if let activeCountdown {
            activeCountdown.title = cleanTitle
            activeCountdown.gentleTitle = cleanGentleTitle.isEmpty ? nil : cleanGentleTitle
            activeCountdown.targetDate = targetDate
        } else {
            modelContext.insert(
                CountdownRecord(
                    title: cleanTitle,
                    gentleTitle: cleanGentleTitle.isEmpty ? nil : cleanGentleTitle,
                    targetDate: targetDate
                )
            )
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            saveErrorMessage = "倒计时仍在当前页面，请检查后再保存。"
        }
    }
}
