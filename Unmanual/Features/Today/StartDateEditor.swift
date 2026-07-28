import SwiftUI

enum HrtJourneyEditorPurpose: Equatable, Sendable {
    case firstStart
    case lifecycle
}

enum HrtJourneyEditorFailurePolicy {
    static func requiresRecovery(_ error: Error) -> Bool {
        if error as? AppDataFailure == .corruptionSuspected {
            return true
        }
        guard let failure = error as? HrtJourneyWriteFailure else {
            return false
        }
        return failure == .missingFoundation
            || failure == .corruptionSuspected
    }
}

@MainActor
struct StartDateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appReadActor) private var appReadActor
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @Environment(AppTheme.self) private var theme

    let purpose: HrtJourneyEditorPurpose
    private let automaticallyLoads: Bool

    @State private var snapshot: HrtJourneySnapshot?
    @State private var transitionDate = Date()
    @State private var note = ""
    @State private var hasLoaded = false
    @State private var readErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var isSaving = false

    init(
        purpose: HrtJourneyEditorPurpose = .lifecycle,
        initialSnapshot: HrtJourneySnapshot? = nil,
        startsLoaded: Bool = false,
        initialReadErrorMessage: String? = nil,
        initiallySaving: Bool = false,
        automaticallyLoads: Bool = true
    ) {
        self.purpose = purpose
        self.automaticallyLoads = automaticallyLoads
        _snapshot = State(initialValue: initialSnapshot)
        _hasLoaded = State(initialValue: startsLoaded)
        _readErrorMessage = State(
            initialValue: initialReadErrorMessage
        )
        _isSaving = State(initialValue: initiallySaving)
    }

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: register,
                eyebrow: "TIME COORDINATE",
                title: title,
                detail: detail,
                isCancelEnabled: !isSaving,
                cancel: {
                    if !isSaving { dismiss() }
                }
            ) {
                content
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let saveTitle {
                    V25SaveBar(
                        title: isSaving ? "正在保存" : saveTitle,
                        isEnabled: canSave,
                        accessibilityIdentifier: "startDate.save",
                        action: save
                    )
                }
            }
            .task {
                if automaticallyLoads {
                    await load()
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .tint(theme.indigo)
        .localSaveErrorAlert(message: $saveErrorMessage)
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded {
            ProgressView("正在读取 HRT 历程")
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityIdentifier("startDate.loading")
        } else if let readErrorMessage {
            readError(readErrorMessage)
        } else if isHistoricalCorrectionLocked {
            lockedCorrectionNotice
        } else {
            statusSummary
            transitionForm
            historyLedger
        }
    }

    private var register: String {
        switch editorAction {
        case .create:
            "LOCAL / HRT START"
        case .correct:
            "LOCAL / DATE CORRECTION"
        case .pause:
            "LOCAL / HRT PAUSE"
        case .resume:
            "LOCAL / HRT RESUME"
        case .locked:
            "LOCAL / HISTORY"
        }
    }

    private var title: String {
        switch editorAction {
        case .create:
            "记录首次开始日"
        case .correct:
            "修正首次开始日"
        case .pause:
            "记录暂停"
        case .resume:
            "记录恢复"
        case .locked:
            "已有多段历程"
        }
    }

    private var detail: String {
        switch editorAction {
        case .create, .correct:
            "日期只建立自然日时间坐标，不代表身体变化进度。"
        case .pause:
            "暂停日是第一天不再属于当前周期的日期。"
        case .resume:
            "恢复日是新周期的第一个活跃日。"
        case .locked:
            "已有暂停或恢复历史后，首次日期不能在这里直接覆盖。"
        }
    }

    private var saveTitle: String? {
        switch editorAction {
        case .create:
            "记录首次开始日"
        case .correct:
            "确认修正日期"
        case .pause:
            "确认记录暂停"
        case .resume:
            "确认记录恢复"
        case .locked:
            nil
        }
    }

    private var editorAction: EditorAction {
        guard let snapshot else { return .create }
        if purpose == .firstStart {
            return canCorrectFirstStart(snapshot) ? .correct : .locked
        }
        return snapshot.summary.state == .active ? .pause : .resume
    }

    private var isHistoricalCorrectionLocked: Bool {
        editorAction == .locked
    }

    private var canSave: Bool {
        hasLoaded
            && readErrorMessage == nil
            && !isSaving
            && saveTitle != nil
            && transitionDateIsValid
    }

    private var transitionDateIsValid: Bool {
        guard let selected = selectedCivilDate,
              let today = currentCivilDate else {
            return false
        }
        guard selected <= today else { return false }
        switch editorAction {
        case .create:
            return true
        case .correct:
            return snapshot?.firstEverStartDate != selected
        case .pause:
            guard let start = snapshot?.periods.last?.startDate else {
                return false
            }
            return start < selected
        case .resume:
            guard let end = snapshot?.periods.last?.endDate else {
                return false
            }
            return end < selected
        case .locked:
            return false
        }
    }

    private var selectedCivilDate: CivilDateFact? {
        try? HistoricalTimestamp.captured(
            instant: transitionDate,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            precision: .minute,
            provenance: .userEntered
        ).localDate
    }

    private var currentCivilDate: CivilDateFact? {
        try? HistoricalTimestamp.captured(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        ).localDate
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusHeading)
                .font(.headline.weight(.black))
            Text(statusDetail)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.22))
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hrtJourney.status")
    }

    private var statusHeading: String {
        guard let snapshot else { return "尚未记录 HRT 历程" }
        switch snapshot.summary.state {
        case .active:
            return "当前处于第 \(snapshot.summary.periodCount) 段周期"
        case .paused:
            return "HRT 历程当前已暂停"
        }
    }

    private var statusDetail: String {
        guard let snapshot else {
            return "可以填写已发生的首次开始日，也可以取消后继续使用其他功能。"
        }
        switch snapshot.summary.state {
        case .active:
            return "本周期第 \(snapshot.summary.currentPhaseDay ?? 1) 天；从首次开始第 \(snapshot.summary.overallJourneyDay) 个自然日。"
        case .paused:
            return "从首次开始第 \(snapshot.summary.overallJourneyDay) 个自然日；暂停从 \(snapshot.summary.pausedSince?.unmanualShortDateText ?? "已记录日期") 开始。"
        }
    }

    private var statusColor: Color {
        snapshot?.summary.state == .paused ? theme.mustard : theme.blue
    }

    private var transitionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            V25FieldSurface(
                dateFieldTitle,
                note: dateFieldNote,
                labelColor: theme.indigoDeep
            ) {
                DatePicker(
                    dateFieldTitle,
                    selection: $transitionDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("startDate.datePicker")
            }

            V25FieldSurface(
                "备注（可选）",
                note: "不需要填写医疗原因；最多 500 字。",
                labelColor: theme.indigoDeep
            ) {
                TextField(
                    "例如：修正旧记录",
                    text: $note,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("hrtJourney.note")
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("只记录历程时间", systemImage: "info.circle")
                    .font(.subheadline.weight(.black))
                Text("这次操作不会结束或改写方案，不会修改既有执行记录，也不会开关本地提醒。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.paper)
            .overlay {
                Rectangle().stroke(theme.indigo.opacity(0.45), lineWidth: 1)
            }

            if !transitionDateIsValid {
                Text(validationMessage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.vermilionText)
                    .accessibilityIdentifier("hrtJourney.validation")
            }
        }
    }

    private var dateFieldTitle: String {
        switch editorAction {
        case .create, .correct:
            "首次开始日期"
        case .pause:
            "第一天暂停日期"
        case .resume:
            "恢复周期日期"
        case .locked:
            "日期"
        }
    }

    private var dateFieldNote: String {
        switch editorAction {
        case .create:
            "只可记录今天或更早的日期。"
        case .correct:
            "会保留一条日期纠正事件，不覆盖审计历史。"
        case .pause:
            "必须晚于当前周期的开始日；同日暂停无法表达。"
        case .resume:
            "必须晚于暂停日；同日恢复无法表达。"
        case .locked:
            ""
        }
    }

    private var validationMessage: String {
        switch editorAction {
        case .correct:
            "请选择与当前首次开始日不同的日期。"
        case .pause:
            "暂停日必须晚于当前周期开始日，且不能晚于今天。"
        case .resume:
            "恢复日必须晚于暂停日，且不能晚于今天。"
        case .create:
            "请选择今天或更早的有效日期。"
        case .locked:
            ""
        }
    }

    @ViewBuilder
    private var historyLedger: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 0) {
                Text("已记录周期")
                    .font(.headline.weight(.black))
                    .padding(.vertical, 10)
                ForEach(Array(snapshot.periods.enumerated()), id: \.element.id) {
                    index,
                    period in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(format: "%02d", index + 1))
                            .font(theme.utility(11))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 28, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(period.startDate.unmanualShortDateText)
                                .font(.body.weight(.bold))
                            Text(
                                period.endDate.map {
                                    "暂停自 \($0.unmanualShortDateText)"
                                } ?? "当前周期"
                            )
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.indigo.opacity(0.3))
                            .frame(height: 1)
                    }
                }
            }
            .accessibilityIdentifier("hrtJourney.periods")
        }
    }

    private func readError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HRT 历程需要重新读取")
                .font(.headline.weight(.black))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Button("重新读取") {
                Task { await load(force: true) }
            }
            .font(.body.weight(.bold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("startDate.retryRead")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.rose.opacity(0.25))
        .overlay {
            Rectangle().stroke(theme.vermilion, lineWidth: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("startDate.readError")
    }

    private var lockedCorrectionNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("没有覆盖历史")
                .font(.title3.weight(.black))
            Text("已有暂停或恢复事件。直接改写首次日期会改变多个历史区间，因此当前版本只允许查看。后续会提供带影响预览的追加式纠正。")
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            historyLedger
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.mustard.opacity(0.2))
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 2)
        }
        .accessibilityIdentifier("hrtJourney.correctionLocked")
    }

    private func load(force: Bool = false) async {
        guard force || !hasLoaded else { return }
        hasLoaded = false
        readErrorMessage = nil
        guard let appReadActor, let today = currentCivilDate else {
            readErrorMessage =
                "本地资料尚未准备好；当前页面没有把它当作空记录。"
            hasLoaded = true
            return
        }
        do {
            let snapshot = try await appReadActor.hrtJourneySnapshot(
                asOf: today
            )
            self.snapshot = snapshot
            configureTransitionDate(for: snapshot)
        } catch is CancellationError {
            return
        } catch {
            snapshot = nil
            if HrtJourneyEditorFailurePolicy.requiresRecovery(error) {
                readErrorMessage =
                    "本地资料没有通过完整性检查。App 将进入恢复模式。"
                integrityFailureHandler?()
            } else {
                readErrorMessage =
                    "暂时无法读取 HRT 历程；请重新读取或取消。"
            }
        }
        hasLoaded = true
    }

    private func configureTransitionDate(
        for snapshot: HrtJourneySnapshot?
    ) {
        note = ""
        guard let snapshot else {
            transitionDate = Date()
            return
        }
        if purpose == .firstStart {
            transitionDate =
                displayDate(snapshot.firstEverStartDate) ?? Date()
        } else {
            transitionDate = Date()
        }
    }

    private func save() {
        guard canSave,
              note.count <= 500,
              let appDataWriter,
              let selectedCivilDate else {
            saveErrorMessage =
                "所选日期或备注尚不能保存，请检查页面提示。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains(
                    "-unmanual-hrt-save-delay"
                ) {
                    try await Task.sleep(for: .seconds(2))
                }
#endif
                let timestamp = try HistoricalTimestamp.captured(
                    instant: Date(),
                    timeZoneIdentifier:
                        TimeZone.autoupdatingCurrent.identifier,
                    precision: .second,
                    provenance: .userEntered
                )
                switch editorAction {
                case .create:
                    _ = try await appDataWriter.createHrtJourney(
                        CreateHrtJourneyCommand(
                            startDate: selectedCivilDate,
                            note: note,
                            timestamp: timestamp
                        )
                    )
                case .correct:
                    guard let snapshot,
                          let period = snapshot.periods.first else {
                        throw HrtJourneyWriteFailure.staleRecord
                    }
                    _ = try await appDataWriter
                        .correctHrtJourneyFirstStart(
                            CorrectHrtJourneyFirstStartCommand(
                                expectedLatestEventID:
                                    snapshot.latestEventID,
                                expectedPeriodID: period.id,
                                correctedStartDate:
                                    selectedCivilDate,
                                note: note,
                                timestamp: timestamp
                            )
                        )
                case .pause:
                    guard let snapshot,
                          let period = snapshot.periods.last else {
                        throw HrtJourneyWriteFailure.staleRecord
                    }
                    _ = try await appDataWriter.pauseHrtJourney(
                        PauseHrtJourneyCommand(
                            expectedLatestEventID:
                                snapshot.latestEventID,
                            expectedOpenPeriodID: period.id,
                            pauseDate: selectedCivilDate,
                            note: note,
                            timestamp: timestamp
                        )
                    )
                case .resume:
                    guard let snapshot,
                          let period = snapshot.periods.last else {
                        throw HrtJourneyWriteFailure.staleRecord
                    }
                    _ = try await appDataWriter.resumeHrtJourney(
                        ResumeHrtJourneyCommand(
                            expectedLatestEventID:
                                snapshot.latestEventID,
                            expectedLastPeriodID: period.id,
                            resumeDate: selectedCivilDate,
                            note: note,
                            timestamp: timestamp
                        )
                    )
                case .locked:
                    throw HrtJourneyWriteFailure.invalidTransition
                }
                NotificationCenter.default.post(
                    name: .unmanualLocalDataChanged,
                    object: nil
                )
                dismiss()
            } catch is CancellationError {
                return
            } catch let failure as HrtJourneyWriteFailure {
                saveErrorMessage = message(for: failure)
                if HrtJourneyEditorFailurePolicy.requiresRecovery(
                    failure
                ) {
                    integrityFailureHandler?()
                }
            } catch {
                if HrtJourneyEditorFailurePolicy.requiresRecovery(
                    error
                ) {
                    saveErrorMessage =
                        "本地资料没有通过完整性检查，HRT 历程没有改变。App 将进入恢复模式。"
                    integrityFailureHandler?()
                } else {
                    saveErrorMessage =
                        "HRT 历程没有改变。请重新读取后再试。"
                }
            }
        }
    }

    private func canCorrectFirstStart(
        _ snapshot: HrtJourneySnapshot
    ) -> Bool {
        snapshot.periods.count == 1
            && snapshot.periods.first?.endDate == nil
            && !snapshot.events.contains {
                $0.kind == .paused || $0.kind == .resumed
            }
    }

    private func message(
        for failure: HrtJourneyWriteFailure
    ) -> String {
        switch failure {
        case .staleRecord, .operationConflict:
            "页面打开后本地资料已经变化。HRT 历程没有改变，请重新读取。"
        case .invalidTransition:
            "所选日期不能形成这个转换；请检查日期边界。"
        case .capacityExceeded:
            "已记录的周期达到当前版本上限，HRT 历程没有改变。"
        case .invalidInput:
            "日期或备注格式无效，HRT 历程没有改变。"
        case .missingFoundation, .corruptionSuspected:
            "本地资料没有通过完整性检查，HRT 历程没有改变。"
        }
    }

    private func displayDate(_ value: CivilDateFact) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(
            from: DateComponents(
                year: value.year,
                month: value.month,
                day: value.day,
                hour: 12
            )
        )
    }
}

private enum EditorAction: Equatable {
    case create
    case correct
    case pause
    case resume
    case locked
}
