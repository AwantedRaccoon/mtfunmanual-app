import SwiftUI

@MainActor
struct CountdownEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appReadActor) private var appReadActor
    @Environment(\.localReminderRuntime) private var reminderRuntime
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var activeCountdown: CountdownCurrentSnapshot?
    @State private var replacementSource: CountdownCurrentSnapshot?
    @State private var gentleModeEnabled = false
    @State private var title = ""
    @State private var gentleTitle = ""
    @State private var targetDate =
        Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var showInToday = true
    @State private var reminderEnabled = false
    @State private var reminderLeadDays = 0
    @State private var reminderTime = Self.defaultReminderTime
    @State private var hasLoadedExistingValue = false
    @State private var readErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var isReading = false
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @State private var showArchiveConfirmation = false
    @State private var showReplaceConfirmation = false
    @State private var showsRetargetGuidance = false

    private static var defaultReminderTime: Date {
        Calendar.current.date(
            from: DateComponents(hour: 9, minute: 0)
        ) ?? Date()
    }

    private var canSave: Bool {
        if gentleModeEnabled,
           activeCountdown == nil || replacementSource != nil {
            return !gentleTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }
        return !title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    private var canDismiss: Bool {
        EditorWriteDismissalPolicy.allowsDismiss(
            isWriting: isSaving
        )
    }

    private var isDue: Bool {
        guard let current = activeCountdown,
              let today = try? currentCivilDate() else {
            return false
        }
        return current.targetDate <= today
    }

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "LOCAL / COUNTDOWN",
                eyebrow: editorEyebrow,
                title: editorTitle,
                detail: "目标日只是一条私人时间线。它不会自动作出医疗判断，也不会替你决定接下来该做什么。",
                isCancelEnabled: canDismiss,
                cancel: {
                    guard canDismiss else { return }
                    dismiss()
                }
            ) {
                VStack(spacing: V25Theme.fieldSpacing) {
                    if isReading {
                        ProgressView("正在读取本地倒计时")
                            .frame(maxWidth: .infinity, minHeight: 88)
                            .accessibilityIdentifier(
                                "countdown.reading"
                            )
                    } else if let readErrorMessage {
                        readError(readErrorMessage)
                    } else {
                        if isDue, replacementSource == nil {
                            dueDecision
                        }

                        if gentleModeEnabled {
                            V25FieldSurface(
                                "温和模式名称",
                                note: "原始名称不会显示在这个页面或辅助功能树中。",
                                labelColor: theme.blueText
                            ) {
                                TextField(
                                    "例如：私人日期",
                                    text: $gentleTitle,
                                    axis: .vertical
                                )
                                .lineLimit(1...3)
                                .accessibilityLabel("温和模式名称")
                                .accessibilityIdentifier(
                                    "countdown.gentleTitle"
                                )
                            }
                        } else {
                            V25FieldSurface("这个日期是什么") {
                                TextField(
                                    "例如：下一次复诊",
                                    text: $title,
                                    axis: .vertical
                                )
                                .lineLimit(1...3)
                                .accessibilityLabel("这个日期是什么")
                                .accessibilityIdentifier("countdown.title")
                            }
                        }

                        V25FieldSurface(
                            "目标日期",
                            labelColor: theme.indigoDeep
                        ) {
                            targetDatePicker
                        }

                        if !gentleModeEnabled {
                            V25FieldSurface(
                                "温和模式名称（可选）",
                                note: "温和模式会在 App 内改用这个名称；如果留空，会显示“私人日期”。",
                                labelColor: theme.blueText
                            ) {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextField(
                                        "例如：私人日期",
                                        text: $gentleTitle,
                                        axis: .vertical
                                    )
                                    .lineLimit(1...3)
                                    .accessibilityLabel(
                                        "温和模式名称（可选）"
                                    )
                                    .accessibilityIdentifier(
                                        "countdown.gentleTitle"
                                    )
                                    Text("温和模式可以使用这个名称，但不会改变系统备份设置，也不会隐藏导出文件。")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryText)
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                        .accessibilityIdentifier(
                                            "countdown.privacyBoundary"
                                        )
                                }
                            }
                        }

                        V25FieldSurface(
                            "今天页",
                            note: "关闭后，今天页不会显示这项；仍可从旅程中的倒计时台账回来管理。",
                            labelColor: theme.indigoDeep
                        ) {
                            Toggle("在今天页显示", isOn: $showInToday)
                                .accessibilityIdentifier(
                                    "countdown.showInToday"
                                )
                        }

                        reminderFields

                        if activeCountdown != nil,
                           replacementSource == nil {
                            managementActions
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V25SaveBar(
                    title: saveTitle,
                    isEnabled: canSave
                        && !isSaving
                        && !isReading
                        && readErrorMessage == nil,
                    accessibilityIdentifier: "countdown.save",
                    action: save
                )
            }
            .task { await loadExistingValue() }
            .confirmationDialog(
                "删除当前倒计时？",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除当前倒计时", role: .destructive) {
                    deleteCurrent()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前名称会从活动资料中移除；append-only 生命周期仍保留日期与动作时间，系统备份、旧 generation 或已导出文件也可能保留副本。这不是取证级擦除。")
            }
            .confirmationDialog(
                "未完成，收进旅程？",
                isPresented: $showArchiveConfirmation,
                titleVisibility: .visible
            ) {
                Button("收进旅程") { archiveCurrent() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这项会停止出现在今天页，也不会再安排新的倒计时提醒。")
            }
            .confirmationDialog(
                "删除并建立新的目标日？",
                isPresented: $showReplaceConfirmation,
                titleVisibility: .visible
            ) {
                Button("开始建立新目标", role: .destructive) {
                    beginReplacement()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("保存新目标时，旧目标的删除和新目标的建立会一起提交；新目标保存失败时，旧目标不会被删除。")
            }
        }
        .tint(theme.indigo)
        .interactiveDismissDisabled(!canDismiss)
        .localSaveErrorAlert(message: $saveErrorMessage)
    }

    private var editorEyebrow: String {
        if replacementSource != nil { return "REPLACE DATE" }
        return activeCountdown == nil ? "NEW DATE" : "EDIT DATE"
    }

    private var editorTitle: String {
        if replacementSource != nil { return "建立新的倒计时" }
        return activeCountdown == nil ? "新建倒计时" : "修改倒计时"
    }

    private var saveTitle: String {
        replacementSource == nil
            ? "保存倒计时"
            : "删除旧目标并保存新目标"
    }

    private func readError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("暂时无法读取倒计时")
                .font(.headline.weight(.black))
                .accessibilityIdentifier("countdown.readError")
            Text(message)
                .font(.subheadline)
            Button("重新读取") {
                Task { await loadExistingValue() }
            }
            .font(.body.weight(.bold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("countdown.retryRead")
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.rose.opacity(0.28))
        .overlay { Rectangle().stroke(theme.vermilion, lineWidth: 2) }
    }

    private var dueDecision: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                activeCountdown?.overdueMode == .countingUp
                    ? "正在继续计算"
                    : "目标日到了"
            )
                .font(theme.display(26, relativeTo: .title2))
            Text(
                activeCountdown?.overdueMode == .countingUp
                    ? "计时会继续保留到你明确完成或改期。你仍然可以把它收进旅程，或在下方换一个目标日。"
                    : "它不会自动结束。你可以把它作为完成路标收进旅程、继续计算已经过了多久，或直接在下方换一个目标日。"
            )
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Button("已经完成，收进旅程") {
                completeCurrent()
            }
            .buttonStyle(V25PrimaryButtonStyle())
            .accessibilityIdentifier("countdown.complete")
            if activeCountdown?.overdueMode == .awaitingDecision {
                Button("继续计算已经过了多久") {
                    continueCounting()
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("countdown.continue")
            }
            Button("换一个目标日") {
                showsRetargetGuidance = true
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("countdown.retarget")
            if showsRetargetGuidance {
                Text("请在下方“目标日期”中选择新的日期，再保存倒计时。改期后会回到等待目标日的状态。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "countdown.retargetGuidance"
                    )
            }
        }
        .padding(16)
        .background(theme.mustard.opacity(0.22))
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
    }

    private var reminderFields: some View {
        V25FieldSurface(
            "设备提醒",
            note: "通知标题和正文始终使用中性措辞，不包含原始名称或温和名称。系统已经投递到通知中心的内容不会被 App 追溯清除。",
            labelColor: theme.vermilionText
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("安排一次本地提醒", isOn: $reminderEnabled)
                    .accessibilityIdentifier("countdown.reminder.enabled")
                if reminderEnabled {
                    Stepper(
                        "提前 \(reminderLeadDays) 天",
                        value: $reminderLeadDays,
                        in: 0...365
                    )
                    .accessibilityIdentifier(
                        "countdown.reminder.leadDays"
                    )
                    DatePicker(
                        "当地时间",
                        selection: $reminderTime,
                        displayedComponents: .hourAndMinute
                    )
                    .accessibilityIdentifier(
                        "countdown.reminder.time"
                    )
                    Text("锁屏预览：给自己留一点时间 · 打开 App 查看下一件事。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let activeCountdown {
                        countdownCoverageLine(activeCountdown.coverage)
                    }
                }
            }
        }
    }

    private func countdownCoverageLine(
        _ coverage: CountdownReminderCoverageSnapshot
    ) -> some View {
        Label(
            CountdownReminderCoveragePresentation.title(
                coverage: coverage,
                countdownRuntimeErrorCode:
                    reminderRuntime?.countdownLastErrorCode
            ),
            systemImage:
                CountdownReminderCoveragePresentation.symbol(
                    coverage: coverage,
                    countdownRuntimeErrorCode:
                        reminderRuntime?.countdownLastErrorCode
                )
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(theme.vermilionText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("countdown.reminder.coverage")
    }

    @ViewBuilder
    private var targetDatePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            DatePicker(
                "目标日期",
                selection: $targetDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .accessibilityIdentifier("countdown.date")
        } else {
            DatePicker(
                "目标日期",
                selection: $targetDate,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .accessibilityIdentifier("countdown.date")
        }
    }

    private var managementActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("管理")
                .font(.caption.weight(.black))
                .foregroundStyle(theme.secondaryText)
                .padding(.bottom, 8)
            managementButton("未完成，收进旅程") {
                showArchiveConfirmation = true
            }
            managementButton("删除并建立新的目标日") {
                showReplaceConfirmation = true
            }
            managementButton("删除当前倒计时", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func managementButton(
        _ label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack {
                Text(label)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadExistingValue() async {
        guard !hasLoadedExistingValue, !isReading else { return }
        isReading = true
        defer { isReading = false }
        guard let appReadActor else {
            readErrorMessage = "本地资料尚未准备好，请稍后重试。"
            return
        }
        do {
            let snapshot = try await appReadActor
                .countdownEditorSnapshot()
            activeCountdown = snapshot.current
            gentleModeEnabled = snapshot.gentleModeEnabled
            if let activeCountdown {
                title = activeCountdown.title
                gentleTitle = activeCountdown.gentleTitle ?? ""
                targetDate = activeCountdown.displayTargetDate
                showInToday = activeCountdown.showInToday
                reminderEnabled = activeCountdown.reminder.isEnabled
                reminderLeadDays = activeCountdown.reminder.leadDays
                reminderTime = reminderDate(
                    hour: activeCountdown.reminder.localHour,
                    minute: activeCountdown.reminder.localMinute
                )
            }
            readErrorMessage = nil
            hasLoadedExistingValue = true
        } catch {
            readErrorMessage =
                "读取没有通过完整性检查。当前页面不会用空白内容覆盖原记录。"
        }
    }

    private func save() {
        guard !isSaving else { return }
        guard let appDataWriter else {
            saveErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let now = Date()
                let timestamp = try HistoricalTimestamp.captured(
                    instant: now,
                    timeZoneIdentifier:
                        TimeZone.autoupdatingCurrent.identifier,
                    provenance: .userEntered
                )
                let content = try commandContent()
                let shouldRequestReminderAuthorization =
                    CountdownReminderAuthorizationPolicy.shouldRequest(
                        previousIntentEnabled:
                            activeCountdown?.reminder.isEnabled
                                ?? replacementSource?.reminder.isEnabled,
                        newIntentEnabled: content.reminder.isEnabled
                    )
                if let replacementSource {
                    _ = try await appDataWriter.replaceCountdown(
                        ReplaceCountdownCommand(
                            operationID: UUID(),
                            deleteEventID: UUID(),
                            newEventID: UUID(),
                            countdownID: replacementSource.id,
                            expectedLatestEventID:
                                replacementSource.latestEventID,
                            title: content.title,
                            gentleTitle: content.gentleTitle,
                            targetDate: content.targetDate,
                            showInToday: showInToday,
                            reminder: content.reminder,
                            timestamp: timestamp
                        )
                    )
                } else if let activeCountdown {
                    _ = try await appDataWriter.updateCountdown(
                        UpdateCountdownCommand(
                            operationID: UUID(),
                            eventID: UUID(),
                            countdownID: activeCountdown.id,
                            expectedLatestEventID:
                                activeCountdown.latestEventID,
                            title: content.title,
                            gentleTitle: content.gentleTitle,
                            targetDate: content.targetDate,
                            showInToday: showInToday,
                            reminder: content.reminder,
                            timestamp: timestamp
                        )
                    )
                } else {
                    _ = try await appDataWriter.createCountdown(
                        CreateCountdownCommand(
                            operationID: UUID(),
                            eventID: UUID(),
                            title: content.title,
                            gentleTitle: content.gentleTitle,
                            targetDate: content.targetDate,
                            showInToday: showInToday,
                            reminder: content.reminder,
                            timestamp: timestamp
                        )
                    )
                }
                if let appReadActor, let reminderRuntime {
                    if shouldRequestReminderAuthorization {
                        await reminderRuntime.requestAuthorizationAndReconcile(
                            reader: appReadActor,
                            writer: appDataWriter
                        )
                    } else {
                        await reminderRuntime.reconcile(
                            reader: appReadActor,
                            writer: appDataWriter
                        )
                    }
                }
                dismiss()
            } catch {
                saveErrorMessage =
                    "倒计时仍在当前页面。请检查日期和提醒时间后再保存。"
            }
        }
    }

    private func completeCurrent() {
        guard let current = activeCountdown,
              let appDataWriter else { return }
        perform {
            let timestamp = try capturedTimestamp()
            _ = try await appDataWriter.completeCountdown(
                CompleteCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    countdownID: current.id,
                    expectedLatestEventID: current.latestEventID,
                    today: timestamp.localDate,
                    timestamp: timestamp
                )
            )
        }
    }

    private func continueCounting() {
        guard let current = activeCountdown,
              let appDataWriter else { return }
        perform {
            let timestamp = try capturedTimestamp()
            _ = try await appDataWriter.continueCountdown(
                ContinueCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    countdownID: current.id,
                    expectedLatestEventID: current.latestEventID,
                    today: timestamp.localDate,
                    timestamp: timestamp
                )
            )
        }
    }

    private func archiveCurrent() {
        guard let current = activeCountdown,
              let appDataWriter else { return }
        perform {
            _ = try await appDataWriter.archiveCountdown(
                ArchiveCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    countdownID: current.id,
                    expectedLatestEventID: current.latestEventID,
                    timestamp: try capturedTimestamp()
                )
            )
        }
    }

    private func deleteCurrent() {
        guard let current = activeCountdown,
              let appDataWriter else { return }
        perform {
            _ = try await appDataWriter.deleteCountdown(
                DeleteCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    countdownID: current.id,
                    expectedLatestEventID: current.latestEventID,
                    timestamp: try capturedTimestamp()
                )
            )
        }
    }

    private func perform(
        _ operation: @escaping () async throws -> Void
    ) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await operation()
                dismiss()
            } catch {
                saveErrorMessage =
                    "这项没有写入。记录可能已在另一处改变，请重新打开后再试。"
            }
        }
    }

    private func beginReplacement() {
        replacementSource = activeCountdown
        activeCountdown = nil
        title = ""
        gentleTitle = ""
        targetDate =
            Calendar.current.date(byAdding: .day, value: 30, to: Date())
                ?? Date()
        showInToday = true
        reminderEnabled = false
        reminderLeadDays = 0
        reminderTime = Self.defaultReminderTime
    }

    private func commandContent() throws -> (
        title: String,
        gentleTitle: String?,
        targetDate: CivilDateFact,
        reminder: CountdownReminderInput
    ) {
        let cleanTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let cleanGentle = gentleTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let isNewGentleCountdown = gentleModeEnabled
            && (activeCountdown == nil || replacementSource != nil)
        let resolvedTitle = isNewGentleCountdown
            ? cleanGentle
            : cleanTitle
        let time = Calendar.current.dateComponents(
            [.hour, .minute],
            from: reminderTime
        )
        guard let hour = time.hour, let minute = time.minute else {
            throw CountdownWriteFailure.invalidInput
        }
        return (
            resolvedTitle,
            cleanGentle.isEmpty ? nil : cleanGentle,
            try civilDate(from: targetDate),
            CountdownReminderInput(
                isEnabled: reminderEnabled,
                leadDays: reminderLeadDays,
                localHour: hour,
                localMinute: minute
            )
        )
    }

    private func capturedTimestamp() throws -> HistoricalTimestamp {
        try HistoricalTimestamp.captured(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            provenance: .userEntered
        )
    }

    private func currentCivilDate() throws -> CivilDateFact {
        try HistoricalTimestamp.captured(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        ).localDate
    }

    private func civilDate(from date: Date) throws -> CivilDateFact {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw CountdownWriteFailure.invalidInput
        }
        return try CivilDateFact(year: year, month: month, day: day)
    }

    private func reminderDate(hour: Int, minute: Int) -> Date {
        Calendar.current.date(
            from: DateComponents(hour: hour, minute: minute)
        ) ?? Self.defaultReminderTime
    }
}

enum CountdownReminderCoveragePresentation {
    static func title(
        coverage: CountdownReminderCoverageSnapshot,
        countdownRuntimeErrorCode: String?
    ) -> String {
        if countdownRuntimeErrorCode == "countdown-needs-confirmation"
            || coverage.lastErrorCode == "countdown-needs-confirmation" {
            return "旧版提醒需要你重新保存一次，确认后才会安排"
        }
        if countdownRuntimeErrorCode != nil {
            return "提醒覆盖没有完成核对，请打开 App 重试"
        }
        switch coverage.status {
        case .disabledByUser:
            return "设备提醒未开启"
        case .notDetermined:
            return "等待你确认系统通知权限"
        case .blockedByPermission:
            return "系统通知已关闭，可在系统设置中修改"
        case .limitedBySystemSettings:
            return "系统当前不会显示提醒横幅"
        case .reconciliationPending:
            return "正在核对这条设备提醒"
        case .scheduledForWindow:
            if let fireAt = coverage.scheduledFireAt {
                return "已安排在 \(fireAt.formatted(date: .abbreviated, time: .shortened))"
            }
            return "当前没有可安排的未来提醒"
        case .limitedByBudget:
            return "系统提醒容量不足，这条提醒尚未安排"
        case .schedulingFailed:
            return "提醒尚未安排，请检查日期和当地时间后重试"
        case .staleObservation:
            return "提醒覆盖等待重新核对"
        }
    }

    static func symbol(
        coverage: CountdownReminderCoverageSnapshot,
        countdownRuntimeErrorCode: String?
    ) -> String {
        if countdownRuntimeErrorCode != nil {
            return "bell.slash"
        }
        return switch coverage.status {
        case .scheduledForWindow: "bell.badge"
        case .limitedByBudget: "bell.badge.fill"
        case .blockedByPermission, .limitedBySystemSettings,
             .schedulingFailed: "bell.slash"
        default: "bell"
        }
    }
}
