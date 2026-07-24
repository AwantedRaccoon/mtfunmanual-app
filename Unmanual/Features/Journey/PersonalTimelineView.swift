import QuickLook
import SwiftUI

@MainActor
struct PersonalTimelineView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var reader
    @State private var items: [PersonalTimelineItem] = []
    @State private var nextCursor: PersonalTimelineCursor?
    @State private var isLoading = false
    @State private var errorMessage: String?
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
                    status: items.isEmpty
                        ? "尚无记录"
                        : (nextCursor == nil ? "\(items.count) 条记录" : "最近 \(items.count) 条")
                )
                JourneyPageRecordAction(action: recordAction)
                    .padding(.top, 14)

                if items.isEmpty, !isLoading {
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
            await loadFirst()
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

    private func loadFirst() async {
        guard let reader, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await reader.personalTimelinePage(limit: 50)
            items = page.items
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            errorMessage = "暂时无法读取时间线，原记录没有被修改。"
        }
    }

    private func loadMore() {
        guard let reader, let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let page = try await reader.personalTimelinePage(after: cursor, limit: 50)
                let existing = Set(items.map { "\($0.kind.rawValue):\($0.id)" })
                items.append(contentsOf: page.items.filter {
                    !existing.contains("\($0.kind.rawValue):\($0.id)")
                })
                nextCursor = page.nextCursor
                errorMessage = nil
            } catch {
                errorMessage = "暂时无法读取更早的记录，请稍后重试。"
            }
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
    @Environment(\.appDataWriter) private var writer
    @Environment(\.attachmentFileStore) private var attachmentStore
    @Environment(\.attachmentIntegrityFailureHandler)
    private var attachmentIntegrityFailureHandler
    @State private var lab: LabSampleSnapshot?
    @State private var status: StatusObservationSnapshot?
    @State private var attachments: [AttachmentSnapshot] = []
    @State private var previewURL: URL?
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

                if let lab {
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
                            if let range = result.referenceRangeOriginal {
                                factRow("报告参考区间", range)
                            }
                            if let variant = result.assayOrVariantOriginal {
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
                    factRow("指标", status.metricNameSnapshot)
                    factRow("记录级别", status.levelDisplayText)
                    if !status.note.isEmpty { factRow("备注", status.note) }
                    Text(StatusScaleCopy.detailGuidance)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    factRow("记录", item.detail)
                }

                if !attachments.isEmpty {
                    V25SectionHeader(title: "附件", detail: "\(attachments.count) 个")
                    ForEach(attachments) { attachment in
                        HStack {
                            Button {
                                guard let attachmentStore else {
                                    attachmentError =
                                        "本地附件服务尚未准备好。"
                                    return
                                }
                                do {
                                    previewURL = try attachmentStore
                                        .auditedFileURL(for: attachment)
                                    attachmentError = nil
                                } catch {
                                    attachmentIntegrityFailureHandler?()
                                    attachmentError =
                                        "附件没有通过打开前的完整性检查。App 已暂停本地资料访问。"
                                }
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
                            Button(role: .destructive) {
                                delete(attachment)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("删除附件 \(attachment.originalFilename)")
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
        .task { await load() }
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

    private func load() async {
        guard let reader else { return }
        do {
            switch item.kind {
            case .labSample:
                lab = try await reader.labSample(id: item.id)
                attachments = try await reader.attachments(
                    ownerType: .labSample,
                    ownerID: item.id
                )
            case .statusObservation:
                status = try await reader.statusObservation(id: item.id)
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
        } catch {
            attachments = []
        }
    }

    private func delete(_ attachment: AttachmentSnapshot) {
        guard let writer, let attachmentStore else {
            attachmentError = "本地附件服务尚未准备好。"
            return
        }
        Task {
            let operationID = UUID()
            var databaseCommitted = false
            do {
                let deletion = try attachmentStore.stageDeletion(
                    attachment: attachment,
                    operationID: operationID
                )
                _ = try await writer.deleteAttachment(
                    DeleteAttachmentCommand(
                        operationID: operationID,
                        attachmentID: attachment.id
                    )
                )
                databaseCommitted = true
                try attachmentStore.finalizeDeletion(deletion)
                attachments.removeAll { $0.id == attachment.id }
                attachmentError = nil
            } catch {
                if databaseCommitted {
                    attachmentIntegrityFailureHandler?()
                    attachmentError =
                        "删除记录已写入，但本地文件没有完成安全收尾。App 已暂停本地资料访问。"
                } else {
                    try? attachmentStore.rollbackDeletion(
                        operationID: operationID
                    )
                    attachmentError = (error as? PersonalTimelineWriteFailure)
                        == .lastAttachmentRequired
                        ? "这条化验只有附件而没有结果，需至少保留一个附件。"
                        : "附件没有删除，请稍后重试。"
                }
            }
        }
    }
}
