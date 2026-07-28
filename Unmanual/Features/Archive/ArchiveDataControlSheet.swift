import SwiftUI

private struct DataControlDeletionChoice:
    Identifiable,
    Equatable,
    Sendable {
    let id: String
    let target: DataControlDeletionTarget
    let title: String
    let detail: String
}

enum ArchiveDataControlInteractionPolicy {
    static func canDismiss(
        isWorking: Bool,
        isResetWorking: Bool
    ) -> Bool {
        !isWorking && !isResetWorking
    }

    static func regimenDeletionCandidates(
        in overview: CoreRegimenOverviewSnapshot
    ) -> [CoreRegimenVersionSnapshot] {
        overview.allVersions.filter {
            !overview.terminalDeletedVersionIDs.contains($0.id)
        }
    }
}

@MainActor
struct ArchiveDataControlSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var reader
    @Environment(\.appDataWriter) private var writer
    @Environment(\.dataControlDeletionService)
    private var deletionService
    @Environment(\.localReminderRuntime) private var reminderRuntime
    @Environment(\.appDataControlCoordinator)
    private var dataControlCoordinator
    @Environment(\.dataInventoryService)
    private var dataInventoryService
    @Environment(\.appDataResetAction)
    private var resetAction

    @State private var choices: [DataControlDeletionChoice] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var preview: DataControlDeletionPreview?
    @State private var selectedChoice: DataControlDeletionChoice?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showsConfirmation = false
    @State private var resetManifest: DataInventoryManifest?
    @State private var resetErrorMessage: String?
    @State private var isResetWorking = false
    @State private var showsResetConfirmation = false

    var body: some View {
        V25EditorPage(
            register: "DATA / CONTROL",
            eyebrow: "档案附页",
            title: "删除与重置",
            detail:
                "先查看影响，再决定是否从普通页面移除。历史校验副本不会被伪装成已经擦除。",
            isCancelEnabled: canDismiss,
            cancel: dismiss.callAsFunction
        ) {
            if isLoading {
                ProgressView("正在读取可处理的记录")
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .accessibilityIdentifier(
                        "archive.dataControl.loading"
                    )
            } else {
                deletionContent
                resetBoundary
            }
        }
        .interactiveDismissDisabled(
            !canDismiss
        )
        .task { await loadChoices() }
        .alert(
            "再次确认移除？",
            isPresented: $showsConfirmation
        ) {
            Button("取消", role: .cancel) {}
            Button("从普通页面移除", role: .destructive) {
                Task { await confirmDeletion() }
            }
        } message: {
            Text(
                "此操作会保留历史校验副本，也不能删除系统备份、Files/Photos 原件或已经分享的副本。"
            )
        }
        .alert(
            "清空全部 App 数据？",
            isPresented: $showsResetConfirmation
        ) {
            Button("取消", role: .cancel) {}
            Button("隔离并准备清空", role: .destructive) {
                startResetFromConfirmation()
            }
        } message: {
            Text(
                "当前进程只会隔离旧资料；完全退出并重新打开后才会清理隔离区、建立空白资料库并核对通知。系统备份、外部原件、截图和已分享副本不受影响。"
            )
        }
    }

    @ViewBuilder
    private var deletionContent: some View {
        if let preview, let selectedChoice {
            impactPreview(
                preview,
                choice: selectedChoice
            )
        } else {
            V25SectionHeader(
                title: "逐项移除",
                detail: "逻辑删除 · 先预览"
            )
            if choices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前没有可逐项移除的记录")
                        .font(.headline.weight(.black))
                    Text("化验、状态与 Countdown 继续使用各自详情页中的删除入口。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.paper)
                .overlay {
                    Rectangle().stroke(theme.indigo, lineWidth: 1.5)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        Button {
                            Task { await loadPreview(choice) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Rectangle()
                                    .fill(theme.vermilion)
                                    .frame(width: 4, height: 42)
                                VStack(
                                    alignment: .leading,
                                    spacing: 4
                                ) {
                                    Text(choice.title)
                                        .font(.body.weight(.black))
                                        .foregroundStyle(
                                            theme.indigoDeep
                                        )
                                    Text(choice.detail)
                                        .font(.caption)
                                        .foregroundStyle(
                                            theme.secondaryText
                                        )
                                        .multilineTextAlignment(
                                            .leading
                                        )
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(theme.blueText)
                            }
                            .padding(14)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: 64,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(theme.indigo)
                                .frame(height: 1)
                        }
                        .accessibilityIdentifier(
                            "archive.dataControl.target."
                                + choice.id
                        )
                    }
                }
                .background(theme.paper)
                .overlay {
                    Rectangle().stroke(theme.indigo, lineWidth: 1.5)
                }
            }
        }
        if isWorking {
            ProgressView("正在核对，完成前请留在这里")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityIdentifier(
                    "archive.dataControl.working"
                )
        }
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(theme.vermilionText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    "archive.dataControl.error"
                )
        }
        if let successMessage {
            Text(successMessage)
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.mossText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    "archive.dataControl.success"
                )
        }
    }

    private func impactPreview(
        _ preview: DataControlDeletionPreview,
        choice: DataControlDeletionChoice
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            V25SectionHeader(
                title: "影响预览",
                detail: choice.title
            )
            VStack(spacing: 0) {
                impactRow(
                    title: "普通页面",
                    detail: "确认后不再展示这项内容。"
                )
                impactRow(
                    title: "历史校验副本",
                    detail:
                        "仍保留 \(preview.plan.impact.retainedRecordCount) 行目标相关事实、修订与收据，用于一致性校验。"
                )
                let sharedControlCount =
                    preview.manifest.categories
                    .filter {
                        $0.key == "db.audit"
                            || $0.key == "db.system"
                    }
                    .compactMap(\.itemCount)
                    .reduce(0, +)
                impactRow(
                    title: "共享校验与系统资料",
                    detail:
                        "\(sharedControlCount) 项 db.audit / db.system 资料属于整个资料库，不会随这一项逐项移除。"
                )
                impactRow(
                    title: "App 私有附件",
                    detail:
                        "\(preview.plan.impact.deletedAttachmentCount) 个，"
                            + ByteCountFormatter.string(
                                fromByteCount:
                                    preview.plan.impact
                                        .deletedAttachmentBytes,
                                countStyle: .file
                            )
                            + "；不会删除 Files 或 Photos 原件。"
                )
                impactRow(
                    title: "待发送提醒",
                    detail:
                        preview.plan.impact.affectedReminderCount == 0
                            ? "这项记录不会改动提醒。"
                            : "会清除并按剩余资料重排全部 App 待发送提醒；已送达历史不删除。"
                )
                let inactiveGenerationCount =
                    preview.manifest.categories
                    .filter {
                        $0.key
                            == "storage.generation.inactive-proven"
                            || $0.key
                                == "storage.generation.unproven"
                    }
                    .compactMap(\.itemCount)
                    .reduce(0, +)
                impactRow(
                    title: "旧 generation",
                    detail:
                        inactiveGenerationCount == 0
                            ? "当前清单没有旧 generation。"
                            : "\(inactiveGenerationCount) 个旧 generation 仍可能保留历史 payload；逐项移除不会改写它们，完整重置才会清理整个受管 root。"
                )
            }
            .background(theme.paper)
            .overlay {
                Rectangle().stroke(theme.indigo, lineWidth: 1.5)
            }

            Button("再次确认并移除") {
                showsConfirmation = true
            }
            .buttonStyle(V25PrimaryButtonStyle())
            .disabled(isWorking)
            .accessibilityIdentifier(
                "archive.dataControl.confirm"
            )
            Button("返回选择") {
                self.preview = nil
                selectedChoice = nil
                errorMessage = nil
            }
            .buttonStyle(V25SecondaryButtonStyle())
            .disabled(isWorking)
        }
    }

    private func impactRow(
        title: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.black))
            Text(detail)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }

    private var resetBoundary: some View {
        VStack(alignment: .leading, spacing: 8) {
            V25SectionHeader(
                title: "全部数据重置",
                detail: "完整清单 · 冷启动续做"
            )
            if let manifest = resetManifest,
               manifest.destructiveActionsEnabled {
                let databaseItems = manifest.categories
                    .filter { $0.kind == .database }
                    .compactMap(\.itemCount)
                    .reduce(0, +)
                let attachmentBytes = manifest.categories
                    .filter {
                        $0.key.hasPrefix(
                            "files.attachments."
                        )
                    }
                    .compactMap(\.byteCount)
                    .reduce(0, +)
                let inactiveGenerationCount =
                    manifest.categories
                    .filter {
                        $0.key
                            == "storage.generation.inactive-proven"
                            || $0.key
                                == "storage.generation.unproven"
                    }
                    .compactMap(\.itemCount)
                    .reduce(0, +)
                impactRow(
                    title: "资料库与校验记录",
                    detail:
                        "\(databaseItems) 项；包括共享的 db.audit、db.system 与普通页面资料。"
                )
                impactRow(
                    title: "App 私有附件",
                    detail: ByteCountFormatter.string(
                        fromByteCount: attachmentBytes,
                        countStyle: .file
                    )
                )
                impactRow(
                    title: "旧 generation",
                    detail:
                        "\(inactiveGenerationCount) 个；逐项删除可能保留的历史 payload 也会随整个受管 root 一起进入隔离并在冷启动清理。"
                )
                impactRow(
                    title: "App 通知",
                    detail: "会清除两个 App 专属 namespace 的待发送与已送达通知；其他 App 的通知不动。"
                )
                Text(
                    "边界：系统备份、Files/Photos 原件、截图和已经导出或分享的副本不由 App 删除。"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                Button("再次确认清空全部 App 数据") {
                    showsResetConfirmation = true
                }
                .buttonStyle(V25PrimaryButtonStyle())
                .disabled(isWorking || isResetWorking)
                .accessibilityIdentifier(
                    "archive.dataControl.resetConfirm"
                )
            } else if isResetWorking {
                ProgressView("正在冻结完整清单")
                    .frame(maxWidth: .infinity)
            } else {
                Text(
                    resetErrorMessage
                        ?? "完整清单尚未通过核对，因此不能开始重置。"
                )
                .font(.caption)
                .foregroundStyle(theme.vermilionText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                Button("重新核对完整清单") {
                    Task { await loadResetManifest() }
                }
                .buttonStyle(V25SecondaryButtonStyle())
                .disabled(isWorking || isResetWorking)
            }
        }
        .padding(14)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 1.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "archive.dataControl.resetBoundary"
        )
    }

    private func loadChoices() async {
        isLoading = true
        defer { isLoading = false }
        await loadResetManifest()
        guard let reader else {
            errorMessage = "本地资料尚未准备好。"
            return
        }
        do {
            let today = Date()
            let timeZone = TimeZone.autoupdatingCurrent
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: today
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                throw DataControlDeletionServiceFailure.unavailable
            }
            let civilToday = try CivilDateFact(
                year: year,
                month: month,
                day: day
            )
            async let journey =
                loadAllJourneyEntries(reader)
            async let regimens = reader.coreRegimenOverview(
                asOf: civilToday
            )
            async let hrt = reader.hrtJourneySnapshot(
                asOf: civilToday
            )
            async let administration = reader
                .dataControlAdministrationDeletionCandidates(
                    now: today,
                    displayTimeZoneIdentifier:
                        timeZone.identifier
                )
            let (
                journeyEntries,
                regimenOverview,
                hrtSnapshot,
                administrationCandidates
            ) = try await (
                journey,
                regimens,
                hrt,
                administration
            )
            var values = journeyEntries.map {
                DataControlDeletionChoice(
                    id: "journey-"
                        + $0.id.uuidString.lowercased(),
                    target: .journeyEntry($0.id),
                    title: $0.kind == .feeling
                        ? "感受记录"
                        : "片段记录",
                    detail: $0.recordedFullDateText
                )
            }
            values += ArchiveDataControlInteractionPolicy
                .regimenDeletionCandidates(
                    in: regimenOverview
                ).map { version in
                return DataControlDeletionChoice(
                    id: "regimen-"
                        + version.id.uuidString.lowercased(),
                    target: version.editState == .draft
                        ? .draftRegimenVersion(version.id)
                        : .sealedRegimenVersion(version.id),
                    title: version.editState == .draft
                        ? "方案草稿 · \(version.title)"
                        : "方案版本 · \(version.title)",
                    detail:
                        version.effectiveStartDate
                            .unmanualFullDateText
                )
            }
            values += administrationCandidates.map {
                candidate in
                guard case let .administrationOccurrence(
                    occurrence
                ) = candidate.target else {
                    preconditionFailure(
                        "Administration catalog target drift"
                    )
                }
                return DataControlDeletionChoice(
                    id: "occurrence-"
                        + occurrence.key,
                    target: candidate.target,
                    title: "执行记录 · "
                        + candidate.displayName,
                    detail:
                        candidate.timestamp.localDate
                            .unmanualFullDateText
                            + " "
                            + String(
                                format: "%02d:%02d",
                                candidate.timestamp
                                    .localTime.hour,
                                candidate.timestamp
                                    .localTime.minute
                            )
                )
            }
            if hrtSnapshot != nil {
                values.append(
                    DataControlDeletionChoice(
                        id: "hrt-journey",
                        target: .hrtJourney,
                        title: "整段 HRT 历程",
                        detail:
                            "方案、执行、化验和状态不会级联删除。"
                    )
                )
            }
            choices = values
            errorMessage = nil
        } catch {
            choices = []
            errorMessage =
                "可处理记录没有通过完整性检查；没有执行删除。"
        }
    }

    private func loadResetManifest() async {
        guard let dataInventoryService else {
            resetManifest = nil
            resetErrorMessage =
                "完整清单服务尚未准备好。"
            return
        }
        isResetWorking = true
        resetErrorMessage = nil
        defer { isResetWorking = false }
        do {
            let manifest = try await dataInventoryService
                .manifest()
            guard manifest.destructiveActionsEnabled else {
                throw DataResetServiceFailure
                    .incompleteManifest
            }
            resetManifest = manifest
        } catch {
            resetManifest = nil
            resetErrorMessage =
                "完整清单没有通过核对；未执行任何重置。"
        }
    }

    private func loadAllJourneyEntries(
        _ reader: AppDataReader
    ) async throws -> [JourneyEntrySnapshot] {
        var result: [JourneyEntrySnapshot] = []
        var cursor: JourneyPageCursor?
        repeat {
            let page = try await reader.journeyPage(
                after: cursor,
                limit: 100
            )
            guard result.count
                    + page.entries.count
                    <= DataInventoryTaxonomy
                        .maximumRowsPerModel,
                  page.nextCursor == nil
                    || page.nextCursor != cursor else {
                throw DataResetServiceFailure.unavailable
            }
            result.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    private func beginReset() async {
        guard let manifest = resetManifest,
              manifest.destructiveActionsEnabled,
              let resetAction else {
            resetErrorMessage =
                "完整清单或重置服务尚未准备好。"
            isResetWorking = false
            return
        }
        resetErrorMessage = nil
        do {
            try await resetAction.begin(
                manifest.stateDigest
            )
        } catch let failure as DataResetServiceFailure
            where failure == .impactChanged {
            resetManifest = nil
            resetErrorMessage =
                "资料在确认前发生了变化。请重新核对完整清单。"
            isResetWorking = false
        } catch {
            resetManifest = nil
            resetErrorMessage =
                "重置没有开始；旧资料仍保留。请重新打开后再核对。"
            isResetWorking = false
        }
    }

    private func startResetFromConfirmation() {
        guard !isResetWorking else { return }
        isResetWorking = true
        Task { await beginReset() }
    }

    private var canDismiss: Bool {
        ArchiveDataControlInteractionPolicy
            .canDismiss(
                isWorking: isWorking,
                isResetWorking: isResetWorking
            )
    }

    private func loadPreview(
        _ choice: DataControlDeletionChoice
    ) async {
        guard let deletionService else {
            errorMessage = "删除服务尚未准备好。"
            return
        }
        isWorking = true
        errorMessage = nil
        successMessage = nil
        defer { isWorking = false }
        do {
            preview = try await deletionService.preview(
                target: choice.target
            )
            selectedChoice = choice
        } catch {
            preview = nil
            selectedChoice = nil
            errorMessage =
                "影响范围没有通过完整核对；没有执行删除。请重新读取后再试。"
        }
    }

    private func confirmDeletion() async {
        guard let preview,
              let deletionService,
              let reader,
              let writer else {
            errorMessage = "删除服务尚未准备好。"
            return
        }
        isWorking = true
        errorMessage = nil
        successMessage = nil
        defer { isWorking = false }
        do {
            _ = try await deletionService.confirm(preview) {
                guard let reminderRuntime else { return false }
                return await reminderRuntime.reconcile(
                    reader: reader,
                    writer: writer,
                    dataControlCoordinator:
                        dataControlCoordinator
                )
            }
            self.preview = nil
            selectedChoice = nil
            successMessage =
                "已从普通页面移除；历史校验副本仍按说明保留。"
            NotificationCenter.default.post(
                name: .unmanualLocalDataChanged,
                object: nil
            )
            await loadChoices()
        } catch {
            errorMessage =
                "删除没有完成闭环；App 已停止继续操作，请重新打开并核对本地资料。"
        }
    }
}
