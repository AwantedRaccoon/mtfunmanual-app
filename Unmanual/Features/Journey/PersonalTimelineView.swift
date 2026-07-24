import QuickLook
import SwiftUI

struct TimelineRequestEpochGate {
    private(set) var currentToken = 0

    mutating func beginRefresh() -> Int {
        currentToken &+= 1
        return currentToken
    }

    func isCurrent(_ token: Int) -> Bool {
        token == currentToken
    }
}

enum TimelineReadContext {
    case firstPage
    case olderPage
}

enum TimelineReadFailureAction: Equatable {
    case ignore
    case retryable(String)
    case requireRecovery(String)
}

enum TimelineReadFailurePolicy {
    static func action(
        for error: Error,
        context: TimelineReadContext,
        requestIsCurrent: Bool
    ) -> TimelineReadFailureAction {
        guard requestIsCurrent else { return .ignore }
        if error as? AppDataFailure == .corruptionSuspected {
            return .requireRecovery(
                "时间线没有通过本地完整性检查。App 将进入恢复模式，不会把损坏资料显示成空状态。"
            )
        }
        switch context {
        case .firstPage:
            return .retryable("暂时无法读取时间线，原记录没有被修改。")
        case .olderPage:
            return .retryable("暂时无法读取更早的记录，请稍后重试。")
        }
    }
}

struct AttachmentPreviewRequestGate {
    private var currentToken = 0
    private var isActive = true

    mutating func begin() -> Int {
        currentToken &+= 1
        return currentToken
    }

    mutating func activate() {
        currentToken &+= 1
        isActive = true
    }

    mutating func invalidate() {
        currentToken &+= 1
        isActive = false
    }

    func mayPresent(_ token: Int) -> Bool {
        isActive && token == currentToken
    }
}

enum AttachmentPreviewRequestResolution {
    static func presentableURL(
        _ auditedURL: URL,
        attachmentID: UUID,
        requestToken: Int,
        gate: AttachmentPreviewRequestGate,
        isCancelled: Bool = Task.isCancelled,
        releaseLease: @escaping @Sendable (UUID) async -> Void
    ) async -> URL? {
        guard !isCancelled, gate.mayPresent(requestToken) else {
            await releaseLease(attachmentID)
            return nil
        }
        return auditedURL
    }
}

enum AttachmentPreviewAdmission {
    static func canBegin(
        isRequestInFlight: Bool,
        presentedAttachmentID: UUID?
    ) -> Bool {
        !isRequestInFlight && presentedAttachmentID == nil
    }
}

@MainActor
struct PersonalTimelineView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var reader
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @State private var items: [PersonalTimelineItem] = []
    @State private var nextCursor: PersonalTimelineCursor?
    @State private var isLoading = false
    @State private var requestEpoch = TimelineRequestEpochGate()
    @State private var errorMessage: String?
    @State private var hasIntegrityFailure = false
    @State private var selectedDetail: PersonalTimelineItem?

    let refreshToken: Int
    @Binding private var requestedItem: PersonalTimelineItem?
    let recordAction: () -> Void

    init(
        refreshToken: Int,
        requestedItem: Binding<PersonalTimelineItem?> = .constant(nil),
        recordAction: @escaping () -> Void
    ) {
        self.refreshToken = refreshToken
        _requestedItem = requestedItem
        self.recordAction = recordAction
    }

    var body: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "JOURNEY / TIMELINE",
                    title: "旅程",
                    subtitle: "化验、状态、执行与片段，按事实发生的时间放在一起。",
                    status: hasIntegrityFailure
                        ? "需要检查"
                        : (
                            items.isEmpty
                                ? "尚无记录"
                                : (
                                    nextCursor == nil
                                        ? "\(items.count) 条记录"
                                        : "最近 \(items.count) 条"
                                )
                        )
                )
                if !hasIntegrityFailure {
                    JourneyPageRecordAction(action: recordAction)
                        .padding(.top, 14)
                }

                if items.isEmpty, !isLoading, !hasIntegrityFailure {
                    emptyState
                        .padding(.top, 18)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.rowIdentity) { item in
                            NavigationLink {
                                PersonalTimelineDetailView(item: item)
                            } label: {
                                PersonalTimelineRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 18)
                }

                if nextCursor != nil {
                    Button(isLoading ? "正在读取…" : "加载更早记录") {
                        loadMore()
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .disabled(isLoading)
                    .padding(.top, 18)
                    .accessibilityIdentifier("timeline.loadOlder")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilionText)
                        .padding(.top, 12)
                }
                V25PrivacyFooter(text: "记录保存在 App 私有存储；时间线是读取投影，不另存一份副本")
                    .padding(.bottom, 42)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(
            isPresented: Binding(
                get: { selectedDetail != nil },
                set: { if !$0 { selectedDetail = nil } }
            )
        ) {
            if let selectedDetail {
                PersonalTimelineDetailView(item: selectedDetail)
            }
        }
        .task(id: refreshToken) {
            await refreshFirstPage()
            openRequestedDetail()
        }
        .onChange(of: requestedItem?.id) { _, _ in
            openRequestedDetail()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有时间线")
                .font(theme.display(24, relativeTo: .title3))
            Text("添加化验、状态或普通记录后，它会按发生时间出现在这里。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func refreshFirstPage() async {
        guard let reader else { return }
        let requestToken = requestEpoch.beginRefresh()
        isLoading = true
        defer {
            if requestEpoch.isCurrent(requestToken) {
                isLoading = false
            }
        }
        do {
            let page = try await reader.personalTimelinePage(limit: 50)
            guard requestEpoch.isCurrent(requestToken) else { return }
            items = page.items
            nextCursor = page.nextCursor
            errorMessage = nil
            hasIntegrityFailure = false
        } catch {
            applyReadFailure(
                error,
                context: .firstPage,
                requestToken: requestToken
            )
        }
    }

    private func loadMore() {
        guard let reader, let cursor = nextCursor, !isLoading else { return }
        let requestToken = requestEpoch.currentToken
        isLoading = true
        Task {
            defer {
                if requestEpoch.isCurrent(requestToken) {
                    isLoading = false
                }
            }
            do {
                let page = try await reader.personalTimelinePage(after: cursor, limit: 50)
                guard requestEpoch.isCurrent(requestToken) else { return }
                let existing = Set(items.map { "\($0.kind.rawValue):\($0.id)" })
                items.append(contentsOf: page.items.filter {
                    !existing.contains("\($0.kind.rawValue):\($0.id)")
                })
                nextCursor = page.nextCursor
                errorMessage = nil
                hasIntegrityFailure = false
            } catch {
                applyReadFailure(
                    error,
                    context: .olderPage,
                    requestToken: requestToken
                )
            }
        }
    }

    private func applyReadFailure(
        _ error: Error,
        context: TimelineReadContext,
        requestToken: Int
    ) {
        switch TimelineReadFailurePolicy.action(
            for: error,
            context: context,
            requestIsCurrent: requestEpoch.isCurrent(requestToken)
        ) {
        case .ignore:
            return
        case let .retryable(message):
            errorMessage = message
        case let .requireRecovery(message):
            items = []
            nextCursor = nil
            hasIntegrityFailure = true
            errorMessage = message
            integrityFailureHandler?()
        }
    }

    private func openRequestedDetail() {
        guard let requestedItem else { return }
        selectedDetail = requestedItem
        self.requestedItem = nil
    }
}

private struct PersonalTimelineRow: View {
    @Environment(AppTheme.self) private var theme
    let item: PersonalTimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 3) {
                Text(String(format: "%02d", item.localDate.day))
                    .font(theme.utility(17))
                    .monospacedDigit()
                Text(String(format: "%04d.%02d", item.localDate.year, item.localDate.month))
                    .font(theme.utility(8))
                    .monospacedDigit()
            }
            .frame(width: 58)
            .foregroundStyle(theme.indigo)

            Rectangle()
                .fill(accent)
                .frame(width: 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kindLabel)
                        .font(theme.utility(9))
                        .tracking(0.7)
                        .foregroundStyle(accentText)
                    Spacer()
                    if let timestamp = item.timestamp {
                        Text(
                            String(
                                format: "%02d:%02d",
                                timestamp.localTime.hour,
                                timestamp.localTime.minute
                            )
                        )
                        .font(theme.utility(10))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("仅日期")
                            .font(theme.utility(9))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Text(item.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(theme.indigoDeep)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(3)
                Label("查看详情", systemImage: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.indigo)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.55)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var kindLabel: String {
        switch item.kind {
        case .labSample: "LAB / 化验"
        case .statusObservation: "STATUS / 状态"
        case .journeyEntry: "NOTE / 片段"
        case .administration: "ACTION / 执行"
        case .regimenVersion: "REGIMEN / 方案"
        }
    }

    private var accent: Color {
        switch item.kind {
        case .labSample: theme.blue
        case .statusObservation: theme.moss
        case .journeyEntry: theme.vermilion
        case .administration: theme.mustard
        case .regimenVersion: theme.indigo
        }
    }

    private var accentText: Color {
        switch item.kind {
        case .labSample: theme.blueText
        case .statusObservation: theme.mossText
        case .journeyEntry: theme.vermilionText
        case .administration: theme.mustardText
        case .regimenVersion: theme.indigo
        }
    }
}

@MainActor
private struct PersonalTimelineDetailView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var reader
    @Environment(\.attachmentMutationService) private var attachmentService
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @State private var lab: LabSampleSnapshot?
    @State private var status: StatusObservationSnapshot?
    @State private var attachments: [AttachmentSnapshot] = []
    @State private var hasLoaded = false
    @State private var detailError: String?
    @State private var previewURL: URL?
    @State private var previewAttachmentID: UUID?
    @State private var isPreviewRequestInFlight = false
    @State private var previewRequestGate = AttachmentPreviewRequestGate()
    @State private var previewRequestTask: Task<Void, Never>?
    @State private var previewReleaseTask: Task<Void, Never>?
    @State private var deletingAttachmentIDs: Set<UUID> = []
    @State private var attachmentError: String?
    let item: PersonalTimelineItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.title)
                    .font(theme.display(32, relativeTo: .title))
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                Rectangle().fill(theme.indigo).frame(height: 2)

                if let detailError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(detailError)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.vermilionText)
                        Button("重新读取") {
                            Task { await load() }
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.paper)
                    .overlay {
                        Rectangle().stroke(theme.vermilion, lineWidth: 1.5)
                    }
                } else if !hasLoaded {
                    ProgressView("正在读取本地记录…")
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else if let lab {
                    if let notice = lab.associationState.reviewNotice {
                        associationReviewNotice(notice)
                    }
                    if !lab.specimenOriginal.isEmpty {
                        factRow("样本", lab.specimenOriginal)
                    }
                    if !lab.contextNote.isEmpty {
                        factRow("情境备注", lab.contextNote)
                    }
                    ForEach(lab.results) { result in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(result.itemNameSnapshot)
                                .font(.headline.weight(.black))
                            if !result.itemCodeSnapshot.isEmpty {
                                factRow("项目代码", result.itemCodeSnapshot)
                            }
                            Text("\(result.rawValueOriginal) \(result.unitOriginal)")
                                .font(theme.display(22, relativeTo: .title3))
                            if let range = result.referenceRangeOriginal,
                               !range.trimmingCharacters(
                                   in: .whitespacesAndNewlines
                               ).isEmpty {
                                factRow("报告参考区间", range)
                            }
                            if let variant = result.assayOrVariantOriginal,
                               !variant.trimmingCharacters(
                                   in: .whitespacesAndNewlines
                               ).isEmpty {
                                factRow("检测方法 / 变体", variant)
                            }
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.indigo.opacity(0.5)).frame(height: 1)
                        }
                    }
                    Text("数值按原报告保存。App 不判断正常或异常，也不自动换算单位。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                } else if let status {
                    if let notice = status.associationState.reviewNotice {
                        associationReviewNotice(notice)
                    }
                    factRow("指标", status.metricNameSnapshot)
                    factRow("记录级别", status.levelDisplayText)
                    if !status.note.isEmpty { factRow("备注", status.note) }
                    Text(StatusScaleCopy.detailGuidance)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    factRow("记录", item.detail)
                }

                if detailError == nil, !attachments.isEmpty {
                    V25SectionHeader(title: "附件", detail: "\(attachments.count) 个")
                    ForEach(attachments) { attachment in
                        HStack {
                            Button {
                                guard let attachmentService else {
                                    attachmentError =
                                        "本地附件服务尚未准备好。"
                                    return
                                }
                                requestPreview(
                                    attachment,
                                    using: attachmentService
                                )
                            } label: {
                                HStack {
                                    Image(systemName: "doc")
                                    Text(attachment.originalFilename)
                                        .lineLimit(2)
                                    Spacer()
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: attachment.byteCount,
                                        countStyle: .file
                                    ))
                                    .font(.caption)
                                }
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                deletingAttachmentIDs.contains(attachment.id)
                                    || !AttachmentPreviewAdmission.canBegin(
                                        isRequestInFlight:
                                            isPreviewRequestInFlight,
                                        presentedAttachmentID:
                                            previewAttachmentID
                                    )
                            )
                            Button(role: .destructive) {
                                delete(attachment)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("删除附件 \(attachment.originalFilename)")
                            .disabled(
                                deletingAttachmentIDs.contains(attachment.id)
                                    || isPreviewRequestInFlight
                                    || previewAttachmentID != nil
                            )
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.indigo.opacity(0.4)).frame(height: 1)
                        }
                    }
                }
                if let attachmentError {
                    Text(attachmentError)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilionText)
                }
                V25PrivacyFooter(text: SystemBackupDisclosure.compact)
            }
            .padding(V25Theme.pagePadding)
            .frame(maxWidth: V25Theme.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(theme.rice.ignoresSafeArea())
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, newValue in
            guard newValue == nil, let attachmentService else { return }
            releasePreviewLease(using: attachmentService)
        }
        .onDisappear {
            previewRequestGate.invalidate()
            previewRequestTask?.cancel()
            previewRequestTask = nil
            guard let attachmentService else {
                isPreviewRequestInFlight = false
                return
            }
            if previewAttachmentID == nil {
                isPreviewRequestInFlight = false
            }
            releasePreviewLease(using: attachmentService)
        }
        .onAppear {
            previewRequestGate.activate()
        }
        .task { await load() }
    }

    private func requestPreview(
        _ attachment: AttachmentSnapshot,
        using attachmentService: AttachmentMutationService
    ) {
        guard AttachmentPreviewAdmission.canBegin(
            isRequestInFlight: isPreviewRequestInFlight,
            presentedAttachmentID: previewAttachmentID
        ) else { return }
        isPreviewRequestInFlight = true
        let requestToken = previewRequestGate.begin()
        previewRequestTask = Task {
            do {
                let auditedURL = try await attachmentService.beginPreview(
                    attachment
                )
                guard let presentableURL =
                        await AttachmentPreviewRequestResolution.presentableURL(
                            auditedURL,
                            attachmentID: attachment.id,
                            requestToken: requestToken,
                            gate: previewRequestGate,
                            releaseLease: { attachmentID in
                                await attachmentService.endPreview(
                                    attachmentID: attachmentID
                                )
                            }
                        ) else {
                    return
                }
                previewAttachmentID = attachment.id
                previewURL = presentableURL
                isPreviewRequestInFlight = false
                previewRequestTask = nil
                attachmentError = nil
            } catch {
                guard previewRequestGate.mayPresent(requestToken) else {
                    return
                }
                isPreviewRequestInFlight = false
                previewRequestTask = nil
                attachmentError =
                    error as? AttachmentMutationFailure == .recoveryRequired
                    ? "附件没有通过打开前的完整性检查。App 已暂停本地资料访问。"
                    : "附件正在执行另一项操作，请稍后再试。"
            }
        }
    }

    private func releasePreviewLease(
        using attachmentService: AttachmentMutationService
    ) {
        guard previewReleaseTask == nil,
              let attachmentID = previewAttachmentID else {
            return
        }
        isPreviewRequestInFlight = true
        previewReleaseTask = Task {
            await attachmentService.endPreview(
                attachmentID: attachmentID
            )
            guard previewAttachmentID == attachmentID else { return }
            previewAttachmentID = nil
            isPreviewRequestInFlight = false
            previewReleaseTask = nil
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(theme.utility(9))
                .tracking(0.7)
                .foregroundStyle(theme.vermilionText)
            Text(value)
                .font(.body)
                .foregroundStyle(theme.indigoDeep)
        }
    }

    private func associationReviewNotice(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.mustard.opacity(0.22))
        .overlay {
            Rectangle().stroke(theme.mustardText, lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let reader else { return }
        hasLoaded = false
        detailError = nil
        do {
            switch item.kind {
            case .labSample:
                guard let loaded = try await reader.labSample(id: item.id) else {
                    throw AppDataFailure.corruptionSuspected
                }
                lab = loaded
                attachments = try await reader.attachments(
                    ownerType: .labSample,
                    ownerID: item.id
                )
            case .statusObservation:
                guard let loaded = try await reader.statusObservation(
                    id: item.id
                ) else {
                    throw AppDataFailure.corruptionSuspected
                }
                status = loaded
                attachments = try await reader.attachments(
                    ownerType: .statusObservation,
                    ownerID: item.id
                )
            case .journeyEntry:
                attachments = try await reader.attachments(
                    ownerType: .journeyEntry,
                    ownerID: item.id
                )
            case .administration, .regimenVersion:
                break
            }
            hasLoaded = true
        } catch {
            lab = nil
            status = nil
            attachments = []
            hasLoaded = true
            if error as? AppDataFailure == .corruptionSuspected {
                detailError =
                    "本地记录没有通过完整性检查。App 将进入恢复模式，不会把损坏资料显示成普通空状态。"
                integrityFailureHandler?()
            } else {
                detailError =
                    "暂时无法读取这条本地记录，原资料没有被修改。"
            }
        }
    }

    private func delete(_ attachment: AttachmentSnapshot) {
        guard let attachmentService else {
            attachmentError = "本地附件服务尚未准备好。"
            return
        }
        guard deletingAttachmentIDs.insert(attachment.id).inserted else {
            return
        }
        Task {
            defer {
                deletingAttachmentIDs.remove(attachment.id)
            }
            do {
                try await attachmentService.deleteAttachment(attachment)
                attachments.removeAll { $0.id == attachment.id }
                attachmentError = nil
            } catch {
                switch error as? AttachmentMutationFailure {
                case .recoveryRequired:
                    attachmentError =
                        "附件删除没有完成安全收尾。App 已暂停本地资料访问。"
                case .previewInProgress:
                    attachmentError = "请先关闭附件预览，再执行删除。"
                case .mutationInProgress:
                    attachmentError = "附件正在执行另一项操作，请稍后再试。"
                case .none:
                    attachmentError = (error as? PersonalTimelineWriteFailure)
                        == .lastAttachmentRequired
                        ? "这条化验只有附件而没有结果，需至少保留一个附件。"
                        : "附件没有删除，请稍后重试。"
                }
            }
        }
    }
}
