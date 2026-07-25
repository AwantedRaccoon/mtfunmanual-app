import SwiftUI

enum CountdownLedgerStatusText {
    static func make(
        hasError: Bool,
        isLoading: Bool,
        reviewCount: Int,
        reviewHasMore: Bool,
        hasCurrent: Bool,
        historyCount: Int,
        historyHasMore: Bool
    ) -> String {
        if hasError { return "需要检查" }
        if isLoading { return "读取中" }
        if reviewCount > 0 {
            return (reviewHasMore ? "至少 " : "")
                + "\(reviewCount) 项待核对"
        }
        if hasCurrent { return "1 项进行中" }
        if historyCount == 0 { return "尚无日期" }
        return (historyHasMore ? "至少 " : "")
            + "\(historyCount) 项历史"
    }
}

enum CountdownDetailLoadState {
    case loading
    case loaded
    case failed
}

enum CountdownDetailTerminalText {
    static func make(
        timestamp: HistoricalTimestamp?,
        loadState: CountdownDetailLoadState
    ) -> String {
        switch loadState {
        case .loading:
            return "读取中"
        case .loaded:
            return timestamp?.recordedCivilMinuteLabel ?? "未记录"
        case .failed:
            return "未能核对"
        }
    }
}

enum CountdownDetailPresentation {
    static func verifiedDetail(
        _ detail: CountdownDetailSnapshot?,
        loadState: CountdownDetailLoadState
    ) -> CountdownDetailSnapshot? {
        guard case .loaded = loadState else { return nil }
        return detail
    }

    static func terminalTimestamp(
        in detail: CountdownDetailSnapshot
    ) -> HistoricalTimestamp? {
        let current = detail.current
        guard let latest = detail.events.first(where: {
            $0.id == current.latestEventID
        }) else {
            return nil
        }
        let terminalEvent: CountdownEventSnapshot
        let terminalInstant: Date
        switch current.lifecycle {
        case .completed:
            guard latest.kind == .completed,
                  let completedAt = current.completedAt else {
                return nil
            }
            terminalEvent = latest
            terminalInstant = completedAt
        case .archived:
            guard let archivedAt = current.archivedAt else {
                return nil
            }
            if latest.kind == .reviewResolved {
                guard let previousEventID = latest.previousEventID,
                      let predecessor = detail.events.first(where: {
                          $0.id == previousEventID
                      }) else {
                    return nil
                }
                terminalEvent = predecessor
            } else {
                terminalEvent = latest
            }
            guard terminalEvent.kind == .archived
                    || terminalEvent.kind == .migratedSnapshot else {
                return nil
            }
            terminalInstant = archivedAt
        case .active, .deleted:
            return nil
        }
        guard terminalEvent.timestamp.instant == terminalInstant else {
            return nil
        }
        return terminalEvent.timestamp
    }
}

@MainActor
struct CountdownLedgerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var reader
    @Environment(\.appDataWriter) private var writer
    @Environment(AppTheme.self) private var theme
    @State private var current: CountdownCurrentSnapshot?
    @State private var history: [CountdownCurrentSnapshot] = []
    @State private var reviewItems: [CountdownCurrentSnapshot] = []
    @State private var activeReviewCount = 0
    @State private var historyNextCursor: CountdownLedgerCursor?
    @State private var reviewNextCursor: CountdownLedgerCursor?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadGeneration = 0
    @State private var reviewMutationID: UUID?
    @State private var errorMessage: String?
    @State private var presentsEditor = false

    var body: some View {
        NavigationStack {
            V25Page {
                VStack(alignment: .leading, spacing: 0) {
                    V25PageHeader(
                        register: "JOURNEY / COUNTDOWN",
                        title: "倒计时台账",
                        subtitle: "当前目标与已经完成或归档的日期，保留在同一条私人时间线上。",
                        status: statusText
                    )

                    if let errorMessage {
                        errorNotice(errorMessage)
                            .padding(.top, 18)
                    } else if isLoading {
                        ProgressView("正在读取本地台账")
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .accessibilityIdentifier(
                                "countdown.ledger.loading"
                            )
                    } else {
                        reviewSection
                            .padding(.top, 20)
                        currentSection
                            .padding(.top, reviewItems.isEmpty ? 20 : 28)
                        historySection
                            .padding(.top, 28)
                    }

                    V25PrivacyFooter(
                        text: "倒计时名称和目标日保存在本机资料中。设备提醒只使用中性通知文案。"
                    )
                    .padding(.top, 28)
                }
            }
            .navigationTitle("倒计时台账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $presentsEditor, onDismiss: reload) {
                CountdownEditor()
            }
            .task { await load() }
        }
    }

    private var statusText: String {
        CountdownLedgerStatusText.make(
            hasError: errorMessage != nil,
            isLoading: isLoading,
            reviewCount: reviewItems.count,
            reviewHasMore: reviewNextCursor != nil,
            hasCurrent: current != nil,
            historyCount: history.count,
            historyHasMore: historyNextCursor != nil
        )
    }

    @ViewBuilder
    private var reviewSection: some View {
        if !reviewItems.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeading("REVIEW / 需要核对")
                    .padding(.bottom, 10)
                Text("旧版本中存在互相矛盾或同时进行的目标日。请逐项确认；核对完成前不会建立新的目标，也不会把这些项目放到今天页。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                ForEach(reviewItems) { entry in
                    reviewRow(entry)
                }
                if reviewNextCursor != nil {
                    Button(isLoadingMore ? "正在读取…" : "加载更多待核对项目") {
                        loadMoreReview()
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .disabled(isLoadingMore)
                    .padding(.top, 12)
                    .accessibilityIdentifier(
                        "countdown.ledger.loadMoreReview"
                    )
                }
            }
            .accessibilityIdentifier("countdown.ledger.review")
        }
    }

    @ViewBuilder
    private var currentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("CURRENT / 当前")
            if let current {
                Button {
                    presentsEditor = true
                } label: {
                    ledgerRow(
                        title: current.displayTitle,
                        meta: targetText(current),
                        detail: current.showInToday
                            ? "显示在今天页 · 点按管理"
                            : "已从今天页隐藏 · 点按管理",
                        accent: theme.vermilion
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("countdown.ledger.current")
            } else if reviewItems.isEmpty {
                Button {
                    presentsEditor = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.headline.weight(.black))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(theme.paper)
                            .background(theme.indigo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("建立一个目标日")
                                .font(.headline.weight(.black))
                            Text("没有倒计时时，今天页不会出现空卡片。")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                    }
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.indigo).frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("countdown.ledger.create")
            } else {
                Text("请先完成上方旧记录核对，再建立新的目标日。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.indigo.opacity(0.55))
                            .frame(height: 1)
                    }
                    .accessibilityIdentifier(
                        "countdown.ledger.createBlockedByReview"
                    )
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("HISTORY / 历史")
                .padding(.bottom, 10)
            if history.isEmpty {
                Text("完成或选择“未完成，收进旅程”后，会在这里留下路标。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.indigo.opacity(0.55))
                            .frame(height: 1)
                    }
                    .accessibilityIdentifier("countdown.ledger.emptyHistory")
            } else {
                ForEach(history) { entry in
                    NavigationLink {
                        CountdownLedgerDetailView(countdownID: entry.id)
                    } label: {
                        ledgerRow(
                            title: entry.displayTitle,
                            meta: targetText(entry),
                            detail: entry.lifecycle == .completed
                                ? "已经完成，已收进旅程"
                                : "未完成，已收进旅程",
                            accent: entry.lifecycle == .completed
                                ? theme.mustard
                                : theme.rose
                        )
                    }
                    .buttonStyle(.plain)
                }
                if historyNextCursor != nil {
                    Button(isLoadingMore ? "正在读取…" : "加载更早的目标日") {
                        loadMoreHistory()
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .disabled(isLoadingMore)
                    .padding(.top, 12)
                    .accessibilityIdentifier(
                        "countdown.ledger.loadMoreHistory"
                    )
                }
            }
        }
    }

    private func reviewRow(
        _ entry: CountdownCurrentSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ledgerRow(
                title: entry.displayTitle,
                meta: targetText(entry),
                detail: entry.lifecycle == .active
                    ? "旧版本中仍标为进行中"
                    : "旧版本中的归档状态需要确认",
                accent: theme.vermilion
            )
            if entry.lifecycle == .active {
                Button("保留为当前目标") {
                    resolveReview(entry, resolution: .keepAsCurrent)
                }
                .buttonStyle(V25PrimaryButtonStyle())
                .disabled(
                    activeReviewCount != 1
                        || reviewMutationID != nil
                )
                .accessibilityIdentifier(
                    "countdown.review.keep.\(entry.id)"
                )
                if activeReviewCount > 1 {
                    Text("还有 \(activeReviewCount) 条进行中项目；请先把不保留的项目收进旅程。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("未完成，收进旅程") {
                    resolveReview(entry, resolution: .archive)
                }
                .buttonStyle(V25SecondaryButtonStyle())
                .disabled(reviewMutationID != nil)
                .accessibilityIdentifier(
                    "countdown.review.archive.\(entry.id)"
                )
            } else {
                Button("确认按已归档保留") {
                    resolveReview(entry, resolution: .keepArchived)
                }
                .buttonStyle(V25SecondaryButtonStyle())
                .disabled(reviewMutationID != nil)
                .accessibilityIdentifier(
                    "countdown.review.keepArchived.\(entry.id)"
                )
            }
        }
        .padding(.bottom, 16)
        .opacity(reviewMutationID == entry.id ? 0.6 : 1)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.black))
            .tracking(0.8)
            .foregroundStyle(theme.indigoDeep)
    }

    private func ledgerRow(
        title: String,
        meta: String,
        detail: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(accent)
                .frame(width: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(meta)
                    .font(theme.utility(10))
                    .foregroundStyle(theme.secondaryText)
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(theme.indigoDeep)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .foregroundStyle(theme.indigo)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.55)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func targetText(_ entry: CountdownCurrentSnapshot) -> String {
        "目标日 "
            + entry.displayTargetDate.formatted(
                .dateTime.year().month(.twoDigits).day(.twoDigits)
            )
    }

    private func errorNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("没有把读取错误当成空台账")
                .font(.headline.weight(.black))
            Text(message)
                .font(.subheadline)
            Button("重新读取") { reload() }
                .font(.body.weight(.bold))
                .frame(minHeight: 44)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.rose.opacity(0.28))
        .overlay { Rectangle().stroke(theme.vermilion, lineWidth: 2) }
        .accessibilityIdentifier("countdown.ledger.error")
    }

    private func reload() {
        Task { await load() }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }
        guard let reader else {
            if generation == loadGeneration {
                errorMessage = "本地资料尚未准备好，请稍后重试。"
            }
            return
        }
        do {
            async let loadedCurrent = reader.countdownCurrentSnapshot()
            async let loadedHistory = reader.countdownHistoryPage(
                after: nil,
                limit: 20
            )
            async let loadedReview = reader.countdownReviewPage(
                after: nil,
                limit: 20
            )
            let newCurrent = try await loadedCurrent
            let historyPage = try await loadedHistory
            let reviewPage = try await loadedReview
            guard generation == loadGeneration else { return }
            current = newCurrent
            history = historyPage.items
            historyNextCursor = historyPage.nextCursor
            reviewItems = reviewPage.items
            reviewNextCursor = reviewPage.nextCursor
            activeReviewCount = reviewPage.activeReviewCount
        } catch {
            guard generation == loadGeneration else { return }
            current = nil
            history = []
            reviewItems = []
            activeReviewCount = 0
            historyNextCursor = nil
            reviewNextCursor = nil
            errorMessage = "倒计时资料没有通过完整性检查，原记录没有被修改。"
        }
    }

    private func loadMoreHistory() {
        guard let cursor = historyNextCursor, !isLoadingMore,
              let reader else { return }
        let generation = loadGeneration
        isLoadingMore = true
        Task {
            defer {
                if generation == loadGeneration {
                    isLoadingMore = false
                }
            }
            do {
                let page = try await reader.countdownHistoryPage(
                    after: cursor,
                    limit: 20,
                )
                guard generation == loadGeneration else { return }
                history.append(contentsOf: page.items)
                historyNextCursor = page.nextCursor
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = "更早的倒计时没有通过完整性检查。"
            }
        }
    }

    private func loadMoreReview() {
        guard let cursor = reviewNextCursor, !isLoadingMore,
              let reader else { return }
        let generation = loadGeneration
        isLoadingMore = true
        Task {
            defer {
                if generation == loadGeneration {
                    isLoadingMore = false
                }
            }
            do {
                let page = try await reader.countdownReviewPage(
                    after: cursor,
                    limit: 20,
                )
                guard generation == loadGeneration else { return }
                reviewItems.append(contentsOf: page.items)
                reviewNextCursor = page.nextCursor
                activeReviewCount = page.activeReviewCount
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = "更多待核对项目没有通过完整性检查。"
            }
        }
    }

    private func resolveReview(
        _ entry: CountdownCurrentSnapshot,
        resolution: CountdownReviewResolution
    ) {
        guard reviewMutationID == nil, let writer else {
            errorMessage = "本地资料尚未准备好，请稍后重试。"
            return
        }
        reviewMutationID = entry.id
        Task {
            defer { reviewMutationID = nil }
            do {
                let timestamp = try HistoricalTimestamp.captured(
                    instant: Date(),
                    timeZoneIdentifier:
                        TimeZone.autoupdatingCurrent.identifier,
                    provenance: .userEntered
                )
                _ = try await writer.resolveCountdownReview(
                    ResolveCountdownReviewCommand(
                        operationID: UUID(),
                        eventID: UUID(),
                        countdownID: entry.id,
                        expectedLatestEventID: entry.latestEventID,
                        resolution: resolution,
                        timestamp: timestamp
                    )
                )
                await load()
            } catch {
                errorMessage = "核对结果没有写入；原记录仍保持不变。"
            }
        }
    }
}

@MainActor
private struct CountdownLedgerDetailView: View {
    @Environment(\.appReadActor) private var reader
    @Environment(AppTheme.self) private var theme
    @State private var detail: CountdownDetailSnapshot?
    @State private var errorMessage: String?
    @State private var loadState: CountdownDetailLoadState = .loading
    let countdownID: UUID

    var body: some View {
        let verifiedDetail = CountdownDetailPresentation.verifiedDetail(
            detail,
            loadState: loadState
        )
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "COUNTDOWN / HISTORY",
                    title: verifiedDetail?.current.displayTitle
                        ?? "倒计时详情",
                    subtitle: headerSubtitle(for: verifiedDetail),
                    status: headerStatus(for: verifiedDetail)
                )

                if let verifiedDetail {
                    let current = verifiedDetail.current
                    factRow(
                        "目标日",
                        current.displayTargetDate.formatted(
                            .dateTime.year().month(.twoDigits).day(.twoDigits)
                        )
                    )
                    .padding(.top, 18)
                    factRow(
                        current.lifecycle == .completed
                            ? "完成时间"
                            : "归档时间",
                        CountdownDetailTerminalText.make(
                            timestamp:
                                CountdownDetailPresentation.terminalTimestamp(
                                in: verifiedDetail
                            ),
                            loadState: loadState
                        )
                    )
                    if let reminder = current.terminalReminder {
                        factRow(
                            "当时提醒",
                            reminder.wasEnabled
                                ? "开启 · 提前 \(reminder.leadDays) 天 · "
                                    + String(
                                        format: "%02d:%02d",
                                        reminder.localHour,
                                        reminder.localMinute
                                    )
                                : "关闭"
                        )
                    }
                }

                if let errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(theme.vermilionText)
                        Button("重新读取") {
                            Task { await load() }
                        }
                        .font(.body.weight(.bold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(
                            "countdown.detail.retryRead"
                        )
                    }
                    .padding(.top, 20)
                    .accessibilityIdentifier(
                        "countdown.detail.readError"
                    )
                } else if let verifiedDetail {
                    Text("DATE CHAIN / 日期链")
                        .font(.caption.weight(.black))
                        .tracking(0.8)
                        .padding(.top, 28)
                    ForEach(verifiedDetail.events) { event in
                        eventRow(event)
                    }
                } else {
                    ProgressView("正在读取日期链")
                        .padding(.top, 24)
                }

                V25PrivacyFooter(
                    text: "历史路标来自 append-only 生命周期事件；已删除项不会出现在这里。"
                )
                .padding(.top, 28)
            }
        }
        .navigationTitle("倒计时详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.indigoDeep)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.45)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func eventRow(_ event: CountdownEventSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eventLabel(event.kind))
                .font(.body.weight(.black))
            if event.oldTargetDate != event.newTargetDate,
               let newTargetDate = event.newTargetDate {
                Text("目标日改为 \(newTargetDate.iso8601)")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Text(
                event.timestamp.recordedCivilMinuteLabel
            )
            .font(theme.utility(10))
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.45)).frame(height: 1)
        }
    }

    private func eventLabel(_ kind: CountdownLifecycleEventKind) -> String {
        switch kind {
        case .migratedSnapshot: "从旧版本迁入"
        case .created: "建立目标日"
        case .edited: "修改目标日、名称或多项设置"
        case .visibilityChanged: "修改今天页显示"
        case .reminderChanged: "修改设备提醒"
        case .reviewResolved: "完成旧记录核对"
        case .continuedCountingUp: "继续计算已经过的时间"
        case .completed: "标记完成"
        case .archived: "未完成，收进旅程"
        case .deleted: "删除"
        case .replaced: "删除并建立新目标"
        }
    }

    private func headerSubtitle(
        for detail: CountdownDetailSnapshot?
    ) -> String {
        if let detail {
            return detail.current.lifecycle == .completed
                ? "已经完成，已收进旅程。"
                : "未完成，已收进旅程。"
        }
        return switch loadState {
        case .loading:
            "正在核对本地历史事实。"
        case .failed:
            "这条历史记录没有通过完整性核对。"
        case .loaded:
            "没有可显示的已核对历史事实。"
        }
    }

    private func headerStatus(
        for detail: CountdownDetailSnapshot?
    ) -> String {
        if let detail {
            return detail.current.lifecycle == .completed
                ? "已完成"
                : "已归档"
        }
        return switch loadState {
        case .loading: "读取中"
        case .failed: "未能核对"
        case .loaded: "未能核对"
        }
    }

    private func load() async {
        loadState = .loading
        errorMessage = nil
        detail = nil
        guard let reader else {
            errorMessage = "本地资料尚未准备好。"
            loadState = .failed
            return
        }
        do {
            guard let loaded = try await reader.countdownDetail(
                id: countdownID
            ) else {
                throw AppDataFailure.corruptionSuspected
            }
            detail = loaded
            loadState = .loaded
        } catch {
            detail = nil
            errorMessage = "日期链没有通过完整性检查，原记录没有被修改。"
            loadState = .failed
        }
    }
}
