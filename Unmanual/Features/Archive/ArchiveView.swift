import SwiftUI

@MainActor
struct ArchiveView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var appReadActor
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appPrivacyCoordinator)
    private var appPrivacyCoordinator

    @State private var destination: ArchiveDestination?
    @State private var snapshot = AppArchiveSnapshot.empty
    @State private var archiveIsLoading = true
    @State private var archiveIsAvailable = false
    @State private var archiveErrorMessage: String?
    @State private var gentleModeEnabled = false
    @State private var gentleModeIsAvailable = false
    @State private var isLoadingGentleMode = true
    @State private var isSavingGentleMode = false
    @State private var gentleModeErrorMessage: String?
    @State private var privacySnapshot: PrivacyControlSnapshot?
    @State private var isLoadingAppLock = true
    @State private var isChangingAppLock = false
    @State private var appLockAvailabilityMessage: String?
    @State private var appLockErrorMessage: String?
    @State private var onboardingPresentation:
        ArchiveOnboardingPresentation?
    @State private var onboardingErrorMessage: String?

    var body: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "LOCAL / ARCHIVE",
                    title: "档案",
                    subtitle: "整理、带走，也决定留下什么。",
                    status: SystemBackupDisclosure.statusLabel
                )

                if archiveIsLoading {
                    ProgressView("正在读取本地档案")
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .accessibilityIdentifier("archive.loading")
                } else if let archiveErrorMessage {
                    archiveReadError(archiveErrorMessage)
                } else if archiveIsAvailable {
                    V25SectionHeader(
                        title: "这台设备里的记录",
                        detail: snapshot.latestActivityLabel
                    )

                    ArchiveDossierCover(snapshot: snapshot)

                    V25SectionHeader(
                        title: "整理并带走",
                        detail: "先预览，再生成"
                    )
#if DEBUG
                    ArchiveExportDesk(
                        snapshot: snapshot,
                        summaryAction: { destination = .visitSummary },
                        exportAction: { destination = .rawExport },
                        importAction: { destination = .rawImport }
                    )
#else
                    ArchiveExportDesk(
                        snapshot: snapshot,
                        summaryAction: { destination = .visitSummary },
                        exportAction: {},
                        importAction: {}
                    )
#endif
                }

                V25SectionHeader(title: "数据与隐私", detail: "你来决定")

                ArchiveControlLedger(
                    gentleModeEnabled: gentleModeEnabled,
                    gentleModeIsAvailable: gentleModeIsAvailable,
                    isLoadingGentleMode: isLoadingGentleMode,
                    isSavingGentleMode: isSavingGentleMode,
                    gentleModeAction: setGentleMode,
                    appLockEnabled:
                        privacySnapshot?.appLockEnabled == true,
                    appLockIsAvailable:
                        privacySnapshot != nil
                            && appLockAvailabilityMessage == nil,
                    isLoadingAppLock: isLoadingAppLock,
                    isChangingAppLock: isChangingAppLock,
                    appLockAction: changeAppLock,
                    setupAction: openOnboardingSettings,
                    storageAction: { destination = .localStorage },
                    deleteAction: { destination = .deleteAndReset }
                )
                if let gentleModeErrorMessage {
                    Text(gentleModeErrorMessage)
                        .font(.caption)
                        .foregroundStyle(theme.vermilionText)
                        .padding(.top, 10)
                        .accessibilityIdentifier(
                            "archive.gentleModeError"
                        )
                }
                if let appLockErrorMessage {
                    Text(appLockErrorMessage)
                        .font(.caption)
                        .foregroundStyle(theme.vermilionText)
                        .padding(.top, 10)
                        .accessibilityIdentifier(
                            "archive.appLockError"
                        )
                } else if let appLockAvailabilityMessage {
                    Text(appLockAvailabilityMessage)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 10)
                        .accessibilityIdentifier(
                            "archive.appLockAvailability"
                        )
                }
                if let onboardingErrorMessage {
                    Text(onboardingErrorMessage)
                        .font(.caption)
                        .foregroundStyle(theme.vermilionText)
                        .padding(.top, 10)
                        .accessibilityIdentifier(
                            "archive.onboardingError"
                        )
                }

                V25SectionHeader(title: "随身附页", detail: "需要时再打开")

                ArchiveSupplementIndex(
                    unitAction: { destination = .unitConversion },
                    knowledgeAction: { destination = .knowledgeSearch }
                )

#if DEBUG
                V25PrivacyFooter(
                    text:
                        "\(SystemBackupDisclosure.compact)；Readable JSON v2、完整备份导出及恢复仅供 internal 验证；Legacy v1 合并器保持隔离。"
                )
#else
                V25PrivacyFooter(text: SystemBackupDisclosure.compact)
#endif
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await refreshSnapshot() }
        .fullScreenCover(isPresented: $isSavingGentleMode) {
            ZStack {
                theme.rice
                    .ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在保存温和模式")
                        .font(.headline.weight(.black))
                        .foregroundStyle(theme.indigoDeep)
                    Text("完成前先留在这里，避免其他页面短暂显示旧名称。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(24)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "archive.gentleMode.saving"
                )
            }
            .interactiveDismissDisabled()
        }
        .fullScreenCover(item: $onboardingPresentation) {
            presentation in
            OnboardingFlowView(
                mode: .revisit,
                initialSnapshot: presentation.snapshot,
                close: { onboardingPresentation = nil }
            )
        }
        .sheet(item: $destination) { destination in
            Group {
                switch destination {
                case .localStorage:
                    ArchiveLocalStorageSheet()
                case .deleteAndReset:
                    ArchiveDataControlSheet()
                case .visitSummary:
                    VisitSummaryFlowView()
#if DEBUG
                case .rawExport:
                    ArchiveDataExportSheet()
                case .rawImport:
                    ArchiveDataImportSheet()
#endif
                default:
                    ArchivePreviewSheet(destination: destination, snapshot: snapshot)
                }
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func refreshSnapshot() async {
        archiveIsLoading = true
        archiveIsAvailable = false
        isLoadingGentleMode = true
        gentleModeIsAvailable = false
        isLoadingAppLock = true
        privacySnapshot = nil
        defer {
            archiveIsLoading = false
            isLoadingGentleMode = false
            isLoadingAppLock = false
        }
        guard let appReadActor else {
            snapshot = .empty
            destination = nil
            archiveErrorMessage =
                "本地档案尚未准备好，请稍后重新打开此页。"
            gentleModeErrorMessage =
                "本地资料尚未准备好，温和模式没有改变。"
            appLockErrorMessage =
                "本地资料尚未准备好，App Lock 没有改变。"
            return
        }
        do {
            snapshot = try await appReadActor.archiveSnapshot()
            archiveIsAvailable = true
            archiveErrorMessage = nil
        } catch {
            snapshot = .empty
            destination = nil
            archiveErrorMessage =
                "档案摘要没有通过完整性检查。"
        }
        do {
            let preference = try await appReadActor
                .gentleModeSnapshot()
            gentleModeEnabled = preference.isEnabled
            gentleModeIsAvailable = true
            gentleModeErrorMessage = nil
        } catch {
            gentleModeErrorMessage =
                "温和模式状态没有通过完整性检查。"
        }
        do {
            privacySnapshot = try await appReadActor
                .privacyControlSnapshot()
            appLockAvailabilityMessage =
                appPrivacyCoordinator?.availabilityMessage()
            appLockErrorMessage = nil
        } catch {
            privacySnapshot = nil
            appLockErrorMessage =
                "App Lock 状态没有通过完整性检查。"
        }
    }

    private func setGentleMode(_ isEnabled: Bool) {
        guard gentleModeIsAvailable,
              !isSavingGentleMode,
              let appDataWriter else {
            gentleModeErrorMessage =
                "本地资料尚未准备好，温和模式没有改变。"
            return
        }
        let previous = gentleModeEnabled
        isSavingGentleMode = true
        gentleModeErrorMessage = nil
        Task {
            defer { isSavingGentleMode = false }
            do {
                try await appDataWriter.setGentleMode(
                    SetGentleModeCommand(isEnabled: isEnabled)
                )
                gentleModeEnabled = isEnabled
                NotificationCenter.default.post(
                    name: .unmanualLocalDataChanged,
                    object: nil
                )
            } catch {
                gentleModeEnabled = previous
                gentleModeErrorMessage =
                    "温和模式没有改变；本地资料可能已在另一处更新。"
            }
        }
    }

    private func openOnboardingSettings() {
        guard let appReadActor else {
            onboardingErrorMessage =
                "本地资料尚未准备好，首次设置没有打开。"
            return
        }
        onboardingErrorMessage = nil
        Task {
            do {
                let snapshot = try await appReadActor
                    .onboardingSnapshot()
                onboardingPresentation = ArchiveOnboardingPresentation(
                    snapshot: snapshot
                )
            } catch {
                onboardingPresentation = nil
                onboardingErrorMessage =
                    "首次设置状态没有通过完整性检查。"
            }
        }
    }

    private func changeAppLock() {
        guard !isChangingAppLock,
              let privacySnapshot,
              let appPrivacyCoordinator,
              let appDataWriter,
              let generationID = appPrivacyCoordinator.generationID else {
            appLockErrorMessage =
                "本地资料尚未准备好，App Lock 没有改变。"
            return
        }
        let desiredValue = !privacySnapshot.appLockEnabled
        isChangingAppLock = true
        appLockErrorMessage = nil
        Task {
            defer { isChangingAppLock = false }
            do {
                let grant = try await appPrivacyCoordinator
                    .authorizeSettingChange(
                        reason: desiredValue
                            ? "启用 App Lock"
                            : "关闭 App Lock"
                    )
                guard grant.generationID == generationID else {
                    throw AppPrivacyCoordinatorFailure.staleRequest
                }
                let result = try await appDataWriter.setAppLock(
                    SetAppLockCommand(
                        operationID: grant.operationID,
                        expectedLocalRevision:
                            privacySnapshot.localRevision,
                        expectedDigestHex:
                            privacySnapshot.digestHex,
                        isEnabled: desiredValue
                    )
                )
                try appPrivacyCoordinator.acceptCommitted(
                    result.snapshot,
                    generationID: generationID
                )
                self.privacySnapshot = result.snapshot
                appLockAvailabilityMessage =
                    appPrivacyCoordinator.availabilityMessage()
                NotificationCenter.default.post(
                    name: .unmanualLocalDataChanged,
                    object: nil
                )
            } catch let failure as AppPrivacyCoordinatorFailure {
                switch failure {
                case .unavailable:
                    appLockErrorMessage =
                        "请先在系统设置中启用设备密码，再更改 App Lock。"
                case .authenticationFailed:
                    appLockErrorMessage =
                        "设备认证没有完成，App Lock 没有改变。"
                case .staleRequest:
                    appLockErrorMessage =
                        "本地资料已经变化，请重新读取后再试。"
                }
            } catch {
                appLockErrorMessage =
                    "App Lock 没有改变；本地资料可能已在另一处更新。"
            }
        }
    }

    private func archiveReadError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("档案摘要需要重新读取")
                .font(.headline.weight(.black))
                .accessibilityIdentifier("archive.readError")
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新读取档案") {
                Task { await refreshSnapshot() }
            }
            .font(.body.weight(.bold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("archive.retryRead")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.rose.opacity(0.28))
        .overlay { Rectangle().stroke(theme.vermilion, lineWidth: 2) }
    }
}

private struct ArchiveOnboardingPresentation: Identifiable {
    let id = UUID()
    let snapshot: OnboardingSnapshot
}

private struct ArchiveDossierCover: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let snapshot: AppArchiveSnapshot

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.mustard)
                .offset(x: 6, y: 6)

            HStack(spacing: 0) {
                archiveSpine

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PERSONAL RECORD")
                                .font(theme.utility(9))
                                .tracking(1)
                                .foregroundStyle(theme.vermilionText)
                            Text(snapshot.hasContent ? "你的个人记录档案" : "从第一笔开始")
                                .font(theme.display(25, relativeTo: .title2))
                                .foregroundStyle(theme.indigoDeep)
                        }

                        Spacer(minLength: 8)

                        Text("本机")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(theme.paper)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 26)
                            .background(theme.blue)
                    }

                    Text(snapshot.rangeLabel)
                        .font(theme.utility(11))
                        .tracking(0.5)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 10)

                    Rectangle()
                        .fill(theme.indigo)
                        .frame(height: 1)
                        .padding(.vertical, 12)

                    ArchiveCounts(snapshot: snapshot, stacked: dynamicTypeSize.isAccessibilitySize)

                    Text(coverNote)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 13)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
            }
            .background(theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "本机个人档案，旅程 \(snapshot.journeyCount) 笔，检查记录 \(snapshot.labRecordCount) 项，方案 \(snapshot.regimenCount) 版，范围 \(snapshot.rangeLabel)"
        )
    }

    private var archiveSpine: some View {
        ZStack {
            theme.indigoDeep
            Text("LOCAL / 04")
                .font(theme.utility(9))
                .tracking(1.2)
                .foregroundStyle(theme.mustard)
                .rotationEffect(.degrees(-90))
                .fixedSize()
        }
        .frame(width: 38)
    }

    private var coverNote: String {
        guard snapshot.supportingDateCount > 0 else {
            return "所有数量都来自你在这台设备上保存的内容。"
        }
        return "另含 \(snapshot.profileCount) 个开始日与 \(snapshot.countdownCount) 个 Countdown。"
    }
}

private struct ArchiveCounts: View {
    @Environment(AppTheme.self) private var theme

    let snapshot: AppArchiveSnapshot
    let stacked: Bool

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 12) { countItems }
            } else {
                HStack(alignment: .top, spacing: 8) { countItems }
            }
        }
    }

    @ViewBuilder
    private var countItems: some View {
        ArchiveCount(value: snapshot.journeyCount, label: "旅程", color: theme.vermilion)
        ArchiveCount(value: snapshot.labRecordCount, label: "检查项", color: theme.blue)
        ArchiveCount(value: snapshot.regimenCount, label: "方案", color: theme.moss)
    }
}

private struct ArchiveCount: View {
    @Environment(AppTheme.self) private var theme

    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value, format: .number)
                .font(theme.display(29, relativeTo: .title2))
                .monospacedDigit()
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.secondaryText)
        }
        .foregroundStyle(theme.indigoDeep)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(color).frame(width: 24, height: 3).offset(y: 5)
        }
    }
}

private struct ArchiveExportDesk: View {
    let snapshot: AppArchiveSnapshot
    let summaryAction: () -> Void
    let exportAction: () -> Void
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArchiveActionRow(
                kicker: "一页摘要",
                title: "整理就诊材料",
                detail: "选择时间范围和内容，先生成一份可核对的预览。",
                badge: "PDF",
                symbol: "arrow.up.right",
                style: .primary,
                action: summaryAction
            )

#if DEBUG
            ArchiveActionRow(
                kicker: "Internal · 先预览",
                title: "Readable JSON v2 / 完整备份",
                detail:
                    "冻结 54 类本地模型并核对完整性；完整备份另含当前 active 附件，确认后才打开 Files。",
                badge: "V2",
                symbol: "arrow.up.right",
                style: .secondary,
                action: exportAction
            )
            .accessibilityIdentifier(
                "archive.export.data"
            )

            ArchiveActionRow(
                kicker: "Internal · 两次确认",
                title: "采用完整备份",
                detail:
                    "先核对 package 与本机状态，再选择恢复到空白设备或替换本机资料；不会静默合并两条历史。",
                badge: "V2",
                symbol: "arrow.down.left",
                style: .secondary,
                action: importAction
            )
            .accessibilityIdentifier(
                "archive.import.completeBackup"
            )
#endif
        }
    }
}

private struct ArchiveActionRow: View {
    enum Style { case primary, secondary }

    @Environment(AppTheme.self) private var theme

    let kicker: String
    let title: String
    let detail: String
    let badge: String
    let symbol: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kicker.uppercased())
                        .font(theme.utility(9))
                        .tracking(0.8)
                        .foregroundStyle(
                            style == .primary ? theme.mustard : theme.vermilionText
                        )
                    Text(title)
                        .font(theme.display(23, relativeTo: .title3))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 14) {
                    Text(badge)
                        .font(theme.utility(10))
                        .tracking(0.8)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 24)
                        .overlay { Rectangle().stroke(foreground, lineWidth: 1) }

                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .black))
                }
            }
            .foregroundStyle(foreground)
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(style == .primary ? theme.vermilion : theme.blue)
                    .frame(width: 5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityHint("打开内容预览")
    }

    private var foreground: Color {
        style == .primary ? theme.paper : theme.indigoDeep
    }

    private var background: Color {
        style == .primary ? theme.indigoDeep : theme.paper
    }
}

private struct ArchiveControlLedger: View {
    @Environment(AppTheme.self) private var theme
    @State private var localGentleModeEnabled: Bool

    let gentleModeEnabled: Bool
    let gentleModeIsAvailable: Bool
    let isLoadingGentleMode: Bool
    let isSavingGentleMode: Bool
    let gentleModeAction: (Bool) -> Void
    let appLockEnabled: Bool
    let appLockIsAvailable: Bool
    let isLoadingAppLock: Bool
    let isChangingAppLock: Bool
    let appLockAction: () -> Void
    let setupAction: () -> Void
    let storageAction: () -> Void
    let deleteAction: () -> Void

    init(
        gentleModeEnabled: Bool,
        gentleModeIsAvailable: Bool,
        isLoadingGentleMode: Bool,
        isSavingGentleMode: Bool,
        gentleModeAction: @escaping (Bool) -> Void,
        appLockEnabled: Bool,
        appLockIsAvailable: Bool,
        isLoadingAppLock: Bool,
        isChangingAppLock: Bool,
        appLockAction: @escaping () -> Void,
        setupAction: @escaping () -> Void,
        storageAction: @escaping () -> Void,
        deleteAction: @escaping () -> Void
    ) {
        self.gentleModeEnabled = gentleModeEnabled
        self.gentleModeIsAvailable = gentleModeIsAvailable
        self.isLoadingGentleMode = isLoadingGentleMode
        self.isSavingGentleMode = isSavingGentleMode
        self.gentleModeAction = gentleModeAction
        self.appLockEnabled = appLockEnabled
        self.appLockIsAvailable = appLockIsAvailable
        self.isLoadingAppLock = isLoadingAppLock
        self.isChangingAppLock = isChangingAppLock
        self.appLockAction = appLockAction
        self.setupAction = setupAction
        self.storageAction = storageAction
        self.deleteAction = deleteAction
        _localGentleModeEnabled = State(
            initialValue: gentleModeEnabled
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Rectangle().fill(theme.mustard).frame(width: 4, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("温和模式")
                        .font(.body.weight(.black))
                    Text("在 App 内使用温和名称；不会隐藏系统备份、最近任务或导出文件。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(
                    "温和模式",
                    isOn: $localGentleModeEnabled
                )
                .labelsHidden()
                .disabled(
                    isSavingGentleMode
                        || !gentleModeIsAvailable
                )
                .accessibilityIdentifier(
                    "archive.gentleMode.toggle"
                )
                .onChange(of: localGentleModeEnabled) {
                    _, newValue in
                    if newValue != gentleModeEnabled {
                        gentleModeAction(newValue)
                    }
                }
                Text(
                    isLoadingGentleMode
                        ? "正在读取温和模式"
                        : !gentleModeIsAvailable
                        ? "温和模式状态不可用"
                        : isSavingGentleMode
                        ? "正在保存"
                        : (
                            gentleModeEnabled
                                ? "温和模式已开启"
                                : "温和模式已关闭"
                        )
                )
                .font(theme.utility(9))
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier(
                    "archive.gentleMode.status"
                )
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(theme.paper)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("archive.gentleMode")
            ArchiveLedgerRow(
                title: "App Lock",
                detail:
                    "使用 Face ID、Touch ID 或设备密码打开本地资料；"
                        + "不会改变温和模式或系统备份。",
                status: isLoadingAppLock
                    ? "正在读取"
                    : isChangingAppLock
                    ? "正在认证"
                    : appLockEnabled
                    ? "已开启"
                    : "已关闭",
                color: theme.mustard,
                accessibilityIdentifier: "archive.appLock",
                isDisabled:
                    isLoadingAppLock
                        || isChangingAppLock
                        || !appLockIsAvailable,
                action: appLockAction
            )
            ArchiveLedgerRow(
                title: "首次设置与提醒",
                detail: "重新查看开始日、方案、提醒和 Countdown；不会重置完成状态。",
                status: "可再次修改",
                color: theme.mustard,
                accessibilityIdentifier: "archive.onboarding",
                action: setupAction
            )
            ArchiveLedgerRow(
                title: "本地存储说明",
                detail: "看看哪些内容留在设备里，导出后又会发生什么。",
                status: "当前：\(SystemBackupDisclosure.statusLabel)",
                color: theme.blue,
                accessibilityIdentifier: "archive.localStorage",
                action: storageAction
            )
            ArchiveLedgerRow(
                title: "删除与重置",
                detail: "逐项检查记录，不提供含糊的“一键无痕”承诺。",
                status: "逐项处理",
                color: theme.vermilion,
                accessibilityIdentifier: "archive.deleteAndReset",
                action: deleteAction
            )
        }
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .onChange(of: gentleModeEnabled) { _, newValue in
            if localGentleModeEnabled != newValue {
                localGentleModeEnabled = newValue
            }
        }
        .onChange(of: isSavingGentleMode) { _, isSaving in
            if !isSaving,
               localGentleModeEnabled != gentleModeEnabled {
                localGentleModeEnabled = gentleModeEnabled
            }
        }
    }
}

private struct ArchiveLedgerRow: View {
    @Environment(AppTheme.self) private var theme

    let title: String
    let detail: String
    let status: String
    let color: Color
    let accessibilityIdentifier: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Rectangle().fill(color).frame(width: 4, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.black))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(status)
                        .font(theme.utility(9))
                        .tracking(0.4)
                        .foregroundStyle(theme.secondaryText)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.black))
                }
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .background(theme.paper)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(status)
    }
}

private struct ArchiveSupplementIndex: View {
    @Environment(AppTheme.self) private var theme

    let unitAction: () -> Void
    let knowledgeAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            supplementRow(
                label: "换算",
                title: "单位换算",
                detail: "保留原始值，换算结果单独标记",
                action: unitAction
            )
            supplementRow(
                label: "资料",
                title: "查找 MTF不全书",
                detail: "完整内容仍由网站承担",
                action: knowledgeAction
            )
        }
        .overlay(alignment: .top) { Rectangle().fill(theme.indigo).frame(height: 1.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.indigo).frame(height: 1.5) }
    }

    private func supplementRow(
        label: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(theme.utility(9))
                    .tracking(0.6)
                    .foregroundStyle(theme.vermilionText)
                    .frame(width: 34, alignment: .leading)
                Text(title)
                    .font(.subheadline.weight(.black))
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.black))
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.secondaryText).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
    }
}

private enum ArchiveDestination: String, Identifiable {
    case visitSummary
#if DEBUG
    case rawExport
    case rawImport
#endif
    case localStorage
    case deleteAndReset
    case unitConversion
    case knowledgeSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visitSummary: "整理就诊材料"
#if DEBUG
        case .rawExport: "预览数据副本"
        case .rawImport: "Legacy v1 实验室"
#endif
        case .localStorage: "本地存储说明"
        case .deleteAndReset: "删除与重置"
        case .unitConversion: "单位换算"
        case .knowledgeSearch: "查找资料"
        }
    }

    var eyebrow: String {
        switch self {
        case .visitSummary: "SUMMARY / PREVIEW"
#if DEBUG
        case .rawExport: "DATA / EXPORT"
        case .rawImport: "DATA / RESTORE"
#endif
        case .localStorage: "LOCAL / PRIVACY"
        case .deleteAndReset: "DATA / CONTROL"
        case .unitConversion: "UTILITY / CONVERT"
        case .knowledgeSearch: "MTFBOOK / SEARCH"
        }
    }

    var detail: String {
        switch self {
        case .visitSummary: "选择时间范围和内容，整理成一页摘要。"
#if DEBUG
        case .rawExport:
            "先预览 Readable JSON v2 或包含 active 附件的完整目录备份。"
        case .rawImport:
            "核对完整 package 后，恢复到空白设备或替换本机资料；不执行自动合并。"
#endif
        case .localStorage: "这里会逐项说明本机数据、系统备份和导出文件之间的边界。"
        case .deleteAndReset: "删除前先列出准确对象和影响范围，并再次确认。"
        case .unitConversion: "输入数值与单位，查看并保存换算结果。"
        case .knowledgeSearch: "App 只提供场景入口；文章正文、来源和更新仍由 mtfbook.com 承担。"
        }
    }
}

private struct ArchiveLocalStorageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    @Environment(\.dataInventoryService)
    private var dataInventoryService

    @State private var manifest: DataInventoryManifest?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        V25EditorPage(
            register: "LOCAL / PRIVACY",
            eyebrow: "档案附页",
            title: "本地存储说明",
            detail:
                "逐项核对 App 能读取的本机资料，也说明 App 无法枚举的外部副本。",
            cancel: dismiss.callAsFunction
        ) {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在核对本机资料")
                        .font(.body.weight(.bold))
                    Text("会检查资料库、附件、保留的历史版本和通知记录。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "archive.localStorage.loading"
                )
            } else if let manifest {
                manifestContent(manifest)
            } else {
                unavailableContent
            }
        }
        .interactiveDismissDisabled(isLoading)
        .task { await loadManifest() }
    }

    @ViewBuilder
    private func manifestContent(
        _ manifest: DataInventoryManifest
    ) -> some View {
        let isComplete = manifest.completeness == .complete
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(isComplete ? theme.moss : theme.vermilion)
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isComplete ? "清单核对完整" : "清单尚未完整")
                        .font(.headline.weight(.black))
                    Text(
                        isComplete
                            ? "以下数量来自同一次本机核对。"
                            : "有一项或多项没有通过核对；这里不会把失败显示成零，删除与重置入口保持不可执行。"
                    )
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "核对时间："
                            + manifest.capturedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                    )
                    .font(theme.utility(10))
                    .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(14)
            .background(theme.paper)
            .overlay {
                Rectangle().stroke(
                    isComplete ? theme.moss : theme.vermilion,
                    lineWidth: 2
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                "archive.localStorage.integrity"
            )

            categorySection(
                title: "资料库与保留审计",
                detail:
                    "当前事实、历史修订、纠错、收据与控制记录",
                categories: manifest.categories.filter {
                    $0.kind == .database
                }
            )
            categorySection(
                title: "附件与事务痕迹",
                detail:
                    "App 私有目录中的 active、staging、trash 与 journal",
                categories: manifest.categories.filter {
                    $0.kind == .fileTree
                }
            )
            categorySection(
                title: "资料库世代",
                detail:
                    "active 与所有保留的 inactive generation；App 1.0 不自动清理旧世代",
                categories: manifest.categories.filter {
                    $0.kind == .generation
                }
            )
            categorySection(
                title: "通知投影",
                detail:
                    "只统计 unmanual.exec.v1. 与 unmanual.countdown.v1.；其他 App 的通知不会纳入",
                categories: manifest.categories.filter {
                    $0.kind == .notification
                }
            )
            categorySection(
                title: "存储控制",
                detail:
                    "当前 pointer、迁移记录与保留的 legacy 文件",
                categories: manifest.categories.filter {
                    $0.kind == .control
                }
            )

            V25SectionHeader(
                title: "App 无法枚举的边界",
                detail: "不等于零，也不受 App 内删除控制"
            )
            VStack(spacing: 0) {
                ForEach(manifest.unmanagedBoundaries, id: \.key) {
                    boundary in
                    inventoryRow(
                        title: boundaryTitle(boundary.key),
                        detail: boundaryDetail(boundary.key),
                        value: "无法枚举",
                        isFailure: false
                    )
                }
            }
            .overlay {
                Rectangle().stroke(theme.indigo, lineWidth: 1.5)
            }

            if !isComplete {
                Button("重新核对") {
                    Task { await loadManifest() }
                }
                .font(.body.weight(.black))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(theme.paper)
                .background(theme.indigo)
                .buttonStyle(V25PressStyle())
                .accessibilityIdentifier(
                    "archive.localStorage.retry"
                )
            }
            Text(SystemBackupDisclosure.systemBackupBoundary)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            V25PrivacyFooter(
                text:
                    "系统备份由设备设置管理；Photos、Files、分享、截图和已导出的副本离开 App 后，不再受 App 内保护。App 1.0 不会主动上传或同步这份清单。"
            )
            .accessibilityIdentifier("archive.preview.footer")
        }
    }

    private func categorySection(
        title: String,
        detail: String,
        categories: [DataInventoryCategory]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            V25SectionHeader(title: title, detail: detail)
            VStack(spacing: 0) {
                ForEach(categories, id: \.key) { category in
                    let failed = category.status == .failed
                    inventoryRow(
                        title: categoryTitle(category.key),
                        detail: failed
                            ? "没有通过完整性核对；未显示部分结果。"
                            : categoryDetail(category),
                        value: failed
                            ? "需重试"
                            : countLabel(category.itemCount),
                        isFailure: failed
                    )
                }
            }
            .overlay {
                Rectangle().stroke(theme.indigo, lineWidth: 1.5)
            }
        }
    }

    private func inventoryRow(
        title: String,
        detail: String,
        value: String,
        isFailure: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(isFailure ? theme.vermilion : theme.blue)
                .frame(width: 4, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.black))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(theme.utility(10))
                .foregroundStyle(
                    isFailure
                        ? theme.vermilionText
                        : theme.indigoDeep
                )
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("暂时无法生成可信清单")
                .font(.headline.weight(.black))
                .accessibilityIdentifier(
                    "archive.localStorage.unavailable"
                )
            Text(
                errorMessage
                    ?? "本地资料尚未准备好；这里不会用估算值代替。"
            )
            .font(.subheadline)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Button("重新核对") {
                Task { await loadManifest() }
            }
            .font(.body.weight(.black))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(theme.paper)
            .background(theme.indigo)
            .buttonStyle(V25PressStyle())
            .accessibilityIdentifier(
                "archive.localStorage.retry"
            )
            Text(SystemBackupDisclosure.systemBackupBoundary)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            V25PrivacyFooter(
                text:
                    "核对失败时，删除与重置入口保持不可执行；现有资料不会被自动删除。"
            )
            .accessibilityIdentifier("archive.preview.footer")
        }
        .padding(16)
        .background(theme.rose.opacity(0.28))
        .overlay {
            Rectangle().stroke(theme.vermilion, lineWidth: 2)
        }
    }

    private func loadManifest() async {
        isLoading = true
        manifest = nil
        errorMessage = nil
        defer { isLoading = false }
        guard let dataInventoryService else {
            errorMessage =
                "当前资料会话没有可用的本地清单读取器。"
            return
        }
        do {
            let loaded = try await dataInventoryService.manifest()
            guard !Task.isCancelled else { return }
            manifest = loaded
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage =
                "本地资料没有通过同一次完整核对，请稍后重试。"
        }
    }

    private func countLabel(_ count: Int64?) -> String {
        guard let count else { return "未确认" }
        return "\(count) 项"
    }

    private func categoryDetail(
        _ category: DataInventoryCategory
    ) -> String {
        var parts = [
            "保留审计 \(category.retainedSensitiveCount ?? 0) 项"
        ]
        if let byteCount = category.byteCount {
            parts.append(
                ByteCountFormatter.string(
                    fromByteCount: byteCount,
                    countStyle: .file
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func categoryTitle(_ key: String) -> String {
        let titles: [String: String] = [
            "db.attachments": "附件 metadata",
            "db.audit": "历史、收据与审计",
            "db.countdown": "Countdown",
            "db.execution": "执行与提醒偏好",
            "db.hrt": "HRT 旅程结构",
            "db.journey": "旅程记录",
            "db.labs": "化验与纠错历史",
            "db.preferences": "偏好与隐私设置",
            "db.regimen": "方案版本与日程规则",
            "db.status": "状态观察与纠错历史",
            "db.system": "资料库控制记录",
            "files.attachments.active": "当前附件文件",
            "files.attachments.journal": "附件事务 journal",
            "files.attachments.staging": "附件 staging",
            "files.attachments.trash": "附件可恢复 trash",
            "notification.countdown.delivered": "Countdown 已送达通知",
            "notification.countdown.pending": "Countdown 待发送通知",
            "notification.execution.delivered": "执行提醒已送达通知",
            "notification.execution.pending": "执行提醒待发送通知",
            "storage.control": "当前 pointer 与迁移控制",
            "storage.generation.active": "当前 active generation",
            "storage.generation.inactive-proven": "来源可证明的 inactive generation",
            "storage.generation.invalid": "无效 generation",
            "storage.generation.unproven": "来源未证明的 inactive generation",
            "storage.legacy": "保留的 legacy 文件"
        ]
        return titles[key] ?? key
    }

    private func boundaryTitle(_ key: String) -> String {
        let titles = [
            "exports": "已导出的副本",
            "filesSource": "Files 原件",
            "photosSource": "Photos 原件",
            "screenshots": "系统截图",
            "shares": "分享后的副本",
            "systemBackup": "系统备份"
        ]
        return titles[key] ?? key
    }

    private func boundaryDetail(_ key: String) -> String {
        let details = [
            "exports": "导出离开 App 后，App 无法继续追踪或删除。",
            "filesSource": "用户选择导入的 Files 原件不会由 App 清理。",
            "photosSource": "用户选择导入的 Photos 原件不会由 App 清理。",
            "screenshots": "截图由系统相册与设备策略管理。",
            "shares": "分享给其他 App 或联系人后的副本不受 App 控制。",
            "systemBackup": "是否进入设备备份由系统设置和备份策略管理。"
        ]
        return details[key] ?? "这个边界不由 App 枚举或删除。"
    }
}

private struct ArchivePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme

    let destination: ArchiveDestination
    let snapshot: AppArchiveSnapshot

    var body: some View {
        V25EditorPage(
            register: destination.eyebrow,
            eyebrow: "档案附页",
            title: destination.title,
            detail: destination.detail,
            cancel: dismiss.callAsFunction
        ) {
            V25SectionHeader(title: sectionTitle, detail: "结构预览")

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(format: "%02d", index + 1))
                            .font(theme.utility(10))
                            .foregroundStyle(
                                index == 0 ? theme.vermilionText : theme.blueText
                            )
                            .frame(width: 25, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                                .font(.body.weight(.black))
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.paper)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.indigo).frame(height: 1)
                    }
                }
            }
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }

            V25PrivacyFooter(text: footerText)
                .accessibilityIdentifier("archive.preview.footer")
        }
    }

    private var sectionTitle: String {
        switch destination {
        case .visitSummary: "将怎样处理"
#if DEBUG
        case .rawExport, .rawImport: "将怎样处理"
#endif
        case .localStorage, .deleteAndReset: "边界与确认"
        case .unitConversion, .knowledgeSearch: "这个附页负责"
        }
    }

    private var rows: [(title: String, detail: String)] {
        switch destination {
        case .visitSummary:
            return [
                ("选择时间范围", "最近 30、90、180 天或自定义范围。"),
                ("选择包含内容", "当前方案、检查、旅程记录和仍想询问的问题。"),
                ("查看完整预览", "确认所选内容后，再生成 PDF。")
            ]
#if DEBUG
        case .rawExport:
            return [
                ("旅程", "当前有 \(snapshot.journeyCount) 笔。"),
                ("检查", "当前有 \(snapshot.labRecordCount) 项原始结果。"),
                ("方案", "当前有 \(snapshot.regimenCount) 个历史版本。"),
                ("日期", "当前有 \(snapshot.profileCount) 个开始日与 \(snapshot.countdownCount) 个 Countdown。")
            ]
        case .rawImport:
            return [
                ("选择测试文件", "只接受当前原型生成的兼容 JSON。"),
                ("核对清单", "写入前展示每一类记录数量。"),
                ("原型限制", "当前按 ID 写入；dataset、digest 和正式冲突处理尚未实现。")
            ]
#endif
        case .localStorage:
            return [
                ("App 内记录", SystemBackupDisclosure.summary),
                ("上传与同步", SystemBackupDisclosure.networkBoundary),
                ("系统备份", SystemBackupDisclosure.systemBackupBoundary),
                ("导出文件", "离开 App 后，不再受 App 内保护。")
            ]
        case .deleteAndReset:
            return [
                ("先选对象", "记录、检查、方案版本和全部数据分别处理。"),
                ("查看影响", "删除前列出关联内容，不隐藏后果。"),
                ("再次确认", "没有预览和确认时，不执行删除。")
            ]
        case .unitConversion:
            return [
                ("保留原始值", "录入内容不会被换算值覆盖。"),
                ("说明换算关系", "显示输入单位、输出单位和规则版本。"),
                ("保存换算结果", "原始记录与换算结果分别显示。")
            ]
        case .knowledgeSearch:
            return [
                ("从当前任务进入", "优先呈现与记录、检查或方案有关的内容。"),
                ("显示来源版本", "保留机构、发布日期和查阅日期。"),
                ("打开完整文章", "需要深入阅读时进入 mtfbook.com。")
            ]
        }
    }

    private var footerText: String {
        switch destination {
        case .visitSummary:
            "把选定范围内的记录整理到同一页"
#if DEBUG
        case .rawExport:
            "仅供 DEBUG 验证结构，不作为恢复承诺"
        case .rawImport:
            "仅使用开发数据；正式冲突处理尚未实现"
#endif
        case .localStorage:
            "系统备份由设备管理，不等于 App 主动上传或同步"
        case .deleteAndReset:
            "普通删除会保留历史校验副本；完整重置仍需冷启动恢复合同"
        case .unitConversion:
            "换算结果与原始记录分开保存"
        case .knowledgeSearch:
            "完整资料、来源和更新由 mtfbook.com 承担"
        }
    }
}
