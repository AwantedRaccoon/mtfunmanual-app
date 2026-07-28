import SwiftUI

enum OnboardingMode: Equatable, Sendable {
    case firstRun
    case revisit
}

private enum OnboardingDestination: Identifiable {
    case startDate
    case regimen(UUID?)
    case reminder
    case countdown

    var id: String {
        switch self {
        case .startDate: "start-date"
        case let .regimen(id): "regimen-" + (id?.uuidString ?? "new")
        case .reminder: "reminder"
        case .countdown: "countdown"
        }
    }
}

@MainActor
struct OnboardingGateView: View {
    @Environment(\.appReadActor) private var appReadActor
    @Environment(AppTheme.self) private var theme

    private enum Route {
        case loading
        case onboarding(OnboardingSnapshot)
        case shell
        case failed
    }

    @State private var route: Route = .loading
    @State private var requestID = 0

    var body: some View {
        Group {
            switch route {
            case .loading:
                loadingView
            case let .onboarding(snapshot):
                OnboardingFlowView(
                    mode: .firstRun,
                    initialSnapshot: snapshot,
                    close: {},
                    onCompleted: { route = .shell }
                )
            case .shell:
                AppShellView()
            case .failed:
                failedView
            }
        }
        .task { await refresh() }
    }

    private var loadingView: some View {
        ZStack {
            theme.rice.ignoresSafeArea()
            ProgressView("正在核对首次设置")
                .foregroundStyle(theme.indigoDeep)
                .accessibilityIdentifier("onboarding.gate.loading")
        }
    }

    private var failedView: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 14) {
                Text("首次设置需要重新读取")
                    .font(theme.display(30, relativeTo: .title))
                    .foregroundStyle(theme.indigoDeep)
                Text("本地资料没有通过完整性检查。App 不会把它猜成空白资料，也不会绕过首次设置。")
                    .font(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新读取") {
                    Task { await refresh() }
                }
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.gate.retry")
            }
        }
        .accessibilityIdentifier("onboarding.gate.error")
    }

    private func refresh() async {
        requestID += 1
        let currentRequest = requestID
        route = .loading
        guard let appReadActor else {
            route = .failed
            return
        }
        do {
            let snapshot = try await appReadActor.onboardingSnapshot()
            guard currentRequest == requestID else { return }
            route = snapshot.isCompleted
                ? .shell
                : .onboarding(snapshot)
        } catch {
            guard currentRequest == requestID else { return }
            route = .failed
        }
    }
}

@MainActor
struct OnboardingFlowView: View {
    @Environment(\.appReadActor) private var appReadActor
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(AppTheme.self) private var theme

    let mode: OnboardingMode
    let close: () -> Void
    let onCompleted: () -> Void

    @State private var snapshot: OnboardingSnapshot
    @State private var destination: OnboardingDestination?
    @State private var isWorking = false
    @State private var isRefreshing = false
    @State private var refreshFailed = false
    @State private var errorMessage: String?

    init(
        mode: OnboardingMode,
        initialSnapshot: OnboardingSnapshot,
        close: @escaping () -> Void,
        onCompleted: @escaping () -> Void = {}
    ) {
        self.mode = mode
        self.close = close
        self.onCompleted = onCompleted
        _snapshot = State(initialValue: initialSnapshot)
    }

    var body: some View {
        NavigationStack {
            Group {
                if refreshFailed {
                    refreshErrorPage
                } else if isRefreshing {
                    refreshPage
                } else if mode == .revisit {
                    revisitPage
                } else {
                    firstRunPage
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(
            item: $destination,
            onDismiss: { Task { await refresh() } }
        ) { destination in
            switch destination {
            case .startDate:
                StartDateEditor(purpose: .firstStart)
            case let .regimen(draftID):
                RegimenVersionEditor(existingDraftID: draftID)
            case .reminder:
                OnboardingReminderSetupView(
                    options: snapshot.reminderOptions,
                    coverage: snapshot.reminderCoverage
                )
            case .countdown:
                CountdownEditor()
            }
        }
        .localSaveErrorAlert(message: $errorMessage)
        .accessibilityIdentifier("onboarding.flow")
    }

    @ViewBuilder
    private var firstRunPage: some View {
        switch snapshot.progress.step {
        case .privacy:
            privacyPage
        case .startDate:
            startDatePage
        case .regimen:
            regimenPage
        case .reminder:
            reminderPage
        case .countdown:
            countdownPage
        case .ready:
            readyPage
        case .completed:
            completionTransition
        }
    }

    private var privacyPage: some View {
        OnboardingStagePage(
            register: "SETUP / 01",
            step: 1,
            title: "先说明资料会去哪里",
            subtitle: "不需要账号，也不要求你先证明任何身份。"
        ) {
            disclosure(
                title: "保存在 App 私有存储",
                text: SystemBackupDisclosure.summary
            )
            disclosure(
                title: "没有 App 主动同步",
                text: SystemBackupDisclosure.networkBoundary
            )
            disclosure(
                title: "系统备份由 iOS 管理",
                text: SystemBackupDisclosure.systemBackupBoundary
            )
            disclosure(
                title: "当前保护边界",
                text:
                    "最近任务预览会使用不透明遮挡；你也可以稍后在“档案”中主动启用 App Lock。温和模式只替换部分敏感措辞；关闭 App 不会删除记录，也不等于无痕。"
            )
            setupPersistenceNote
        } actions: {
            OnboardingActionBar(
                primaryTitle: "读完，开始设置",
                primaryIdentifier: "onboarding.privacy.continue",
                isEnabled: !isWorking,
                primaryAction: {
                    advance(.reviewPrivacy)
                }
            )
        }
    }

    private var startDatePage: some View {
        OnboardingStagePage(
            register: "SETUP / 02",
            step: 2,
            title: "建立时间坐标",
            subtitle: "开始日可选；它只用于按自然日整理记录。"
        ) {
            setupStatusRow(
                number: "01",
                title: "HRT 开始日",
                detail: snapshot.profile.map {
                    "已设置："
                        + $0.startDate.formatted(
                            .dateTime.year().month().day()
                        )
                } ?? "尚未填写",
                actionTitle:
                    snapshot.profile == nil ? "填写日期" : "查看或修改",
                action: { destination = .startDate }
            )
            setupPersistenceNote
        } actions: {
            OnboardingActionBar(
                primaryTitle:
                    snapshot.profile == nil
                        ? "暂不填写"
                        : "保存并继续",
                primaryIdentifier: "onboarding.startDate.continue",
                secondaryTitle: "返回隐私说明",
                secondaryIdentifier: "onboarding.back",
                isEnabled: !isWorking,
                primaryAction: {
                    advance(
                        .continueStartDate(
                            skipped: snapshot.profile == nil
                        )
                    )
                },
                secondaryAction: { advance(.moveBack) }
            )
        }
    }

    private var regimenPage: some View {
        OnboardingStagePage(
            register: "SETUP / 03",
            step: 3,
            title: "建立当前方案",
            subtitle: "先保存校样，再核对并封存；只有封存版本会参与今天和提醒。"
        ) {
            if snapshot.regimenNeedsReview {
                disclosure(
                    title: "方案时间线需要先核对",
                    text:
                        "现有版本存在重叠或迁移待复核项。首次设置不会猜测哪一版有效。"
                )
            } else if snapshot.hasEligibleRegimen {
                disclosure(
                    title: "当前方案已建立",
                    text: "已有封存的当前或即将生效版本，可以继续。"
                )
            } else {
                V25EmptyState(
                    eyebrow: "REQUIRED",
                    title: "还没有封存方案",
                    detail:
                        "建立一个基础方案并完成核对后，才能进入“今天”。"
                )
            }

            Button("新建方案校样") {
                destination = .regimen(nil)
            }
            .buttonStyle(V25SecondaryButtonStyle())
            .accessibilityIdentifier("onboarding.regimen.new")

            if !snapshot.drafts.isEmpty {
                V25SectionHeader(
                    title: "未封存校样",
                    detail: "\(snapshot.drafts.count) 份"
                )
                ForEach(snapshot.drafts) { draft in
                    setupStatusRow(
                        number: "D",
                        title: draft.title,
                        detail:
                            "计划生效 "
                            + draft.effectiveStartDate.unmanualShortDateText,
                        actionTitle: "继续编辑",
                        action: { destination = .regimen(draft.id) }
                    )
                }
            }
            setupPersistenceNote
        } actions: {
            OnboardingActionBar(
                primaryTitle: "方案已核对，继续",
                primaryIdentifier: "onboarding.regimen.continue",
                secondaryTitle: "返回开始日",
                secondaryIdentifier: "onboarding.back",
                isEnabled:
                    snapshot.hasEligibleRegimen
                        && !snapshot.regimenNeedsReview
                        && !isWorking,
                primaryAction: { advance(.continueRegimen) },
                secondaryAction: { advance(.moveBack) }
            )
        }
    }

    private var reminderPage: some View {
        OnboardingStagePage(
            register: "SETUP / 04",
            step: 4,
            title: "选择是否提醒",
            subtitle: "这是可选项。只有你主动打开的具体时段会请求系统通知权限。"
        ) {
            if snapshot.reminderOptions.isEmpty {
                V25EmptyState(
                    eyebrow: "OPTIONAL",
                    title: "当前方案没有可提醒时段",
                    detail:
                        "你可以先继续；之后修改方案时再设置提醒。"
                )
            } else {
                ForEach(snapshot.reminderOptions) { option in
                    setupStatusRow(
                        number: option.isEnabled ? "ON" : "—",
                        title: option.displayName,
                        detail:
                            option.scheduleSummary
                            + " · "
                            + (
                                option.isEnabled
                                    ? snapshot.reminderStatusText
                                    : "未选择"
                            ),
                        actionTitle: "设置提醒",
                        action: { destination = .reminder }
                    )
                }
            }
            setupPersistenceNote
        } actions: {
            OnboardingActionBar(
                primaryTitle:
                    snapshot.hasEnabledReminder
                        ? "已选择提醒时段，继续"
                        : "暂不设置提醒",
                primaryIdentifier: "onboarding.reminder.continue",
                secondaryTitle: "返回当前方案",
                secondaryIdentifier: "onboarding.back",
                isEnabled: !isWorking,
                primaryAction: {
                    advance(
                        .continueReminder(
                            skipped: !snapshot.hasEnabledReminder
                        )
                    )
                },
                secondaryAction: { advance(.moveBack) }
            )
        }
    }

    private var countdownPage: some View {
        OnboardingStagePage(
            register: "SETUP / 05",
            step: 5,
            title: "留一个想记住的日期",
            subtitle: "Countdown 可选；它不是医疗提醒，也不会改变方案。"
        ) {
            setupStatusRow(
                number: snapshot.countdown == nil ? "—" : "01",
                title: snapshot.countdown?.displayTitle ?? "尚未建立 Countdown",
                detail:
                    snapshot.countdown.map {
                        "目标 "
                            + $0.targetDate.unmanualShortDateText
                    } ?? "可以暂时跳过，之后再建立",
                actionTitle:
                    snapshot.countdown == nil
                        ? "建立 Countdown"
                        : "查看或修改",
                action: { destination = .countdown }
            )
            setupPersistenceNote
        } actions: {
            OnboardingActionBar(
                primaryTitle:
                    snapshot.countdown == nil
                        ? "暂不建立"
                        : "保存并继续",
                primaryIdentifier: "onboarding.countdown.continue",
                secondaryTitle: "返回提醒",
                secondaryIdentifier: "onboarding.back",
                isEnabled: !isWorking,
                primaryAction: {
                    advance(
                        .continueCountdown(
                            skipped: snapshot.countdown == nil
                        )
                    )
                },
                secondaryAction: { advance(.moveBack) }
            )
        }
    }

    private var readyPage: some View {
        OnboardingStagePage(
            register: "SETUP / 06",
            step: 6,
            title: "设置已经可以使用",
            subtitle: "先不要急着给自己下结论。接下来只从今天能完成的一件事开始。"
        ) {
            setupStatusRow(
                number: snapshot.profile == nil ? "—" : "✓",
                title: "HRT 开始日",
                detail:
                    snapshot.profile == nil
                        ? "已选择暂不填写"
                        : "已保存",
                actionTitle: "返回修改",
                actionIdentifier:
                    "onboarding.ready.editStartDate",
                action: { advance(.reopen(.startDate)) }
            )
            setupStatusRow(
                number: snapshot.hasEligibleRegimen ? "✓" : "!",
                title: "当前方案",
                detail:
                    snapshot.hasEligibleRegimen
                        ? "已封存"
                        : "需要先建立",
                actionTitle: "查看方案",
                actionIdentifier:
                    "onboarding.ready.editRegimen",
                action: { advance(.reopen(.regimen)) }
            )
            setupStatusRow(
                number: snapshot.hasEnabledReminder ? "✓" : "—",
                title: "本地提醒",
                detail:
                    snapshot.hasEnabledReminder
                        ? snapshot.reminderStatusText
                        : "已选择暂不设置",
                actionTitle: "返回修改",
                actionIdentifier:
                    "onboarding.ready.editReminder",
                action: { advance(.reopen(.reminder)) }
            )
            setupStatusRow(
                number: snapshot.countdown == nil ? "—" : "✓",
                title: "Countdown",
                detail:
                    snapshot.countdown == nil
                        ? "已选择暂不建立"
                        : "已建立",
                actionTitle: "返回修改",
                actionIdentifier:
                    "onboarding.ready.editCountdown",
                action: { advance(.reopen(.countdown)) }
            )
            V25PrivacyFooter(text: SystemBackupDisclosure.compact)
        } actions: {
            OnboardingActionBar(
                primaryTitle: "进入今天",
                primaryIdentifier: "onboarding.complete",
                secondaryTitle: "返回上一项",
                secondaryIdentifier: "onboarding.back",
                isEnabled:
                    snapshot.hasEligibleRegimen
                        && !snapshot.regimenNeedsReview
                        && !isWorking,
                primaryAction: complete,
                secondaryAction: { advance(.moveBack) }
            )
        }
    }

    private var revisitPage: some View {
        OnboardingStagePage(
            register: "SETTINGS / LOCAL",
            step: nil,
            title: "首次设置与提醒",
            subtitle: "重新查看这些设置不会重置资料，也不会把完成状态改回未完成。"
        ) {
            setupStatusRow(
                number: snapshot.profile == nil ? "—" : "✓",
                title: "HRT 开始日",
                detail: snapshot.profile == nil ? "未填写" : "已保存",
                actionTitle: "查看或修改",
                action: { destination = .startDate }
            )
            setupStatusRow(
                number: snapshot.hasEligibleRegimen ? "✓" : "!",
                title: "当前方案",
                detail:
                    snapshot.hasEligibleRegimen
                        ? "已封存"
                        : "尚未建立",
                actionTitle: "新建方案校样",
                action: { destination = .regimen(nil) }
            )
            ForEach(snapshot.drafts) { draft in
                setupStatusRow(
                    number: "D",
                    title: draft.title,
                    detail: "未封存校样",
                    actionTitle: "继续编辑",
                    action: { destination = .regimen(draft.id) }
                )
            }
            setupStatusRow(
                number: snapshot.hasEnabledReminder ? "✓" : "—",
                title: "本地提醒",
                detail:
                    snapshot.hasEnabledReminder
                        ? snapshot.reminderStatusText
                        : "未启用",
                actionTitle: "设置提醒",
                action: { destination = .reminder }
            )
            setupStatusRow(
                number: snapshot.countdown == nil ? "—" : "✓",
                title: "Countdown",
                detail:
                    snapshot.countdown?.displayTitle ?? "尚未建立",
                actionTitle: "查看或修改",
                action: { destination = .countdown }
            )
            V25PrivacyFooter(text: SystemBackupDisclosure.compact)
        } actions: {
            OnboardingActionBar(
                primaryTitle: "返回档案",
                primaryIdentifier: "onboarding.revisit.done",
                isEnabled: !isWorking,
                primaryAction: close
            )
        }
    }

    private var refreshPage: some View {
        ZStack {
            theme.rice.ignoresSafeArea()
            ProgressView("正在重新读取首次设置")
                .accessibilityIdentifier("onboarding.refreshing")
        }
    }

    private var refreshErrorPage: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 14) {
                Text("设置状态需要重新读取")
                    .font(theme.display(30, relativeTo: .title))
                Text("当前页面不会把读取失败当作未填写，也不会覆盖原记录。")
                    .font(.body)
                    .foregroundStyle(theme.secondaryText)
                Button("重新读取") {
                    Task { await refresh() }
                }
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.retryRead")
                if mode == .revisit {
                    Button("返回档案", action: close)
                        .buttonStyle(V25SecondaryButtonStyle())
                }
            }
        }
        .accessibilityIdentifier("onboarding.readError")
    }

    private var completionTransition: some View {
        ZStack {
            theme.rice.ignoresSafeArea()
            ProgressView("正在进入今天")
                .task { onCompleted() }
        }
    }

    private var setupPersistenceNote: some View {
        V25PrivacyFooter(
            text:
                "每次保存都会立即写入本地。你可以直接关闭 App；重新打开会回到尚未完成的步骤。"
        )
    }

    private func disclosure(
        title: String,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline.weight(.black))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func setupStatusRow(
        number: String,
        title: String,
        detail: String,
        actionTitle: String,
        actionIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        OnboardingStatusRow(
            number: number,
            title: title,
            detail: detail,
            actionTitle: actionTitle,
            actionIdentifier: actionIdentifier,
            action: action
        )
    }

    private func advance(_ action: OnboardingProgressAction) {
        guard !isWorking, let appDataWriter else {
            errorMessage =
                "本地资料尚未准备好，当前步骤没有改变。"
            return
        }
        let expectedStep = snapshot.progress.step
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await appDataWriter.updateOnboardingProgress(
                    UpdateOnboardingProgressCommand(
                        expectedStep: expectedStep,
                        action: action
                    )
                )
                await refresh()
            } catch {
                errorMessage =
                    "当前步骤没有保存；请重新读取后再试。"
            }
        }
    }

    private func complete() {
        guard !isWorking,
              snapshot.hasEligibleRegimen,
              !snapshot.regimenNeedsReview,
              let appDataWriter,
              let appReadActor else {
            errorMessage =
                "需要先建立并核对当前方案。"
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await appDataWriter.completeOnboarding(
                    CompleteOnboardingCommand()
                )
                let confirmed = try await appReadActor
                    .onboardingSnapshot()
                guard confirmed.isCompleted else {
                    throw AppDataFailure.corruptionSuspected
                }
                snapshot = confirmed
                onCompleted()
            } catch {
                errorMessage =
                    "首次设置没有完成；原资料仍保留在当前步骤。"
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshFailed = false
        defer { isRefreshing = false }
        guard let appReadActor else {
            refreshFailed = true
            return
        }
        do {
            snapshot = try await appReadActor.onboardingSnapshot()
            if mode == .firstRun, snapshot.isCompleted {
                onCompleted()
            }
        } catch {
            refreshFailed = true
        }
    }
}

private struct OnboardingStagePage<
    Content: View,
    Actions: View
>: View {
    @Environment(AppTheme.self) private var theme

    let register: String
    let step: Int?
    let title: String
    let subtitle: String
    let content: Content
    let actions: Actions

    init(
        register: String,
        step: Int?,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.register = register
        self.step = step
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: register,
                    title: title,
                    subtitle: subtitle,
                    status: step.map { "\($0) / 6" } ?? "可再次修改"
                )
                if let step {
                    OnboardingProgressStrip(currentStep: step)
                        .padding(.top, 14)
                }
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(.top, 18)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .background(theme.rice)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.indigo).frame(height: 1)
                }
        }
    }
}

private struct OnboardingProgressStrip: View {
    @Environment(AppTheme.self) private var theme

    let currentStep: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("步骤 \(currentStep)，共 6 步")
                .font(.caption.weight(.bold))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.indigo.opacity(0.18))
                    Rectangle()
                        .fill(theme.mustard)
                        .frame(
                            width:
                                geometry.size.width
                                * CGFloat(currentStep) / 6
                        )
                }
            }
            .frame(height: 6)
        }
        .foregroundStyle(theme.indigoDeep)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.progress")
    }
}

private struct OnboardingStatusRow: View {
    @Environment(AppTheme.self) private var theme

    let number: String
    let title: String
    let detail: String
    let actionTitle: String
    let actionIdentifier: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.vermilionText)
                .frame(width: 28, alignment: .topLeading)
                .frame(minHeight: 44, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                actionButton
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.65)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let button = Button(actionTitle, action: action)
            .font(.body.weight(.bold))
            .frame(minHeight: 44)
        if let actionIdentifier {
            button.accessibilityIdentifier(actionIdentifier)
        } else {
            button
        }
    }
}

private struct OnboardingActionBar: View {
    @Environment(AppTheme.self) private var theme

    let primaryTitle: String
    let primaryIdentifier: String
    let secondaryTitle: String?
    let secondaryIdentifier: String?
    let isEnabled: Bool
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?

    init(
        primaryTitle: String,
        primaryIdentifier: String,
        secondaryTitle: String? = nil,
        secondaryIdentifier: String? = nil,
        isEnabled: Bool,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.primaryTitle = primaryTitle
        self.primaryIdentifier = primaryIdentifier
        self.secondaryTitle = secondaryTitle
        self.secondaryIdentifier = secondaryIdentifier
        self.isEnabled = isEnabled
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(spacing: 8) {
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(V25SecondaryButtonStyle())
                    .accessibilityIdentifier(
                        secondaryIdentifier ?? "onboarding.secondary"
                    )
            }
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(V25PrimaryButtonStyle())
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.46)
                .accessibilityIdentifier(primaryIdentifier)
        }
        .padding(.horizontal, V25Theme.pagePadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(theme.rice)
    }
}
