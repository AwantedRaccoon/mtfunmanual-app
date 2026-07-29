import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
extension UTType {
    static let unmanualCompleteBackup = UTType(
        exportedAs:
            "com.mtfbook.unmanual.complete-backup",
        conformingTo: .package
    )
}

enum ArchiveDataExportKind:
    String, CaseIterable, Identifiable, Sendable {
    case readableJSON
    case completeBackup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readableJSON:
            "Readable JSON v2"
        case .completeBackup:
            "完整备份"
        }
    }

    var detail: String {
        switch self {
        case .readableJSON:
            "可阅读、可审计的逻辑数据；列出附件清单，但不包含附件文件。"
        case .completeBackup:
            "目录 package；包含 Readable JSON v2 和当前 active 附件。"
        }
    }

    var badge: String {
        switch self {
        case .readableJSON: "JSON V2"
        case .completeBackup: "PACKAGE"
        }
    }

    var contentType: UTType {
        switch self {
        case .readableJSON: .json
        case .completeBackup: .unmanualCompleteBackup
        }
    }
}

struct ArchiveDataExportPreview: Equatable {
    let kind: ArchiveDataExportKind
    let capturedAt: Date
    let schemaVersion: String
    let recordCount: Int
    let controlCount: Int
    let attachmentCount: Int
    let byteCount: Int64
    let integrityDigest: String

    init(
        readableDocument: PortableDataV2Document,
        encodedByteCount: Int
    ) {
        let payload = readableDocument.payload
        kind = .readableJSON
        capturedAt = Date(
            timeIntervalSince1970:
                TimeInterval(payload.capturedAtMicroseconds)
                / 1_000_000
        )
        schemaVersion = payload.schemaVersion
        recordCount = payload.records.count
        controlCount = payload.controls.count
        attachmentCount = payload.activeAttachments.count
        byteCount = Int64(encodedByteCount)
        integrityDigest = readableDocument.transportSHA256
    }

    init(completeBackup: AuditedPortableBackup) {
        let payload = completeBackup.readableDocument.payload
        kind = .completeBackup
        capturedAt = Date(
            timeIntervalSince1970:
                TimeInterval(payload.capturedAtMicroseconds)
                / 1_000_000
        )
        schemaVersion = payload.schemaVersion
        recordCount = payload.records.count
        controlCount = payload.controls.count
        attachmentCount = payload.activeAttachments.count
        byteCount =
            completeBackup.manifest.payload.totalByteCount
        integrityDigest = completeBackup.packageSHA256
    }

    var shortIntegrityDigest: String {
        String(integrityDigest.prefix(16))
    }
}

struct ArchiveDataExportDocument: FileDocument {
    enum Storage: @unchecked Sendable {
        case regularFile(Data)
        case directoryPackage(FileWrapper)
    }

    static var readableContentTypes: [UTType] {
        [.json, .unmanualCompleteBackup]
    }

    let storage: Storage

    init(data: Data) {
        storage = .regularFile(data)
    }

    init(snapshot: PortableBackupExportSnapshot) {
        storage = .directoryPackage(
            snapshot.fileWrapper
        )
    }

    init(frozenPackageWrapper: FileWrapper) {
        storage = .directoryPackage(
            frozenPackageWrapper
        )
    }

    init(configuration: ReadConfiguration) throws {
        guard let data =
                configuration.file.regularFileContents else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        storage = .regularFile(data)
    }

    func fileWrapper(
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        switch storage {
        case let .regularFile(data):
            FileWrapper(regularFileWithContents: data)
        case let .directoryPackage(wrapper):
            wrapper
        }
    }
}

private struct PreparedArchiveDataExport {
    let preview: ArchiveDataExportPreview
    let document: ArchiveDataExportDocument?
    let stateIdentity: PortableExportStateIdentity
    let transientPackageURL: URL?
    let defaultFilename: String

    var contentType: UTType {
        preview.kind.contentType
    }
}

@MainActor
struct ArchiveDataExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    @Environment(\.dataInventoryService)
    private var dataInventoryService

    @State private var selection:
        ArchiveDataExportKind = .readableJSON
    @State private var prepared:
        PreparedArchiveDataExport?
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparationToken: UUID?
    @State private var isPreparing = false
    @State private var isExporting = false
    @State private var statusMessage: String?
    @State private var pendingCleanupURLs: [URL] = []

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "DATA / EXPORT",
                eyebrow: "INTERNAL / PREVIEW FIRST",
                title: "数据副本预览",
                detail:
                    "先在 App 内冻结并核对副本，再决定是否交给 Files。此入口仅存在于 DEBUG/internal 构建。",
                cancel: {
                    Task { await close() }
                }
            ) {
                ArchiveDataExportKindPicker(
                    selection: Binding(
                        get: { selection },
                        set: { newValue in
                            Task {
                                await changeSelection(
                                    newValue
                                )
                            }
                        }
                    )
                )

                if isPreparing {
                    V25FieldSurface(
                        "正在冻结副本",
                        note:
                            "会在同一次读取门禁中核对 54 类模型、修订、删除覆盖和 active 附件。"
                    ) {
                        ProgressView()
                            .tint(theme.indigo)
                    }
                    .accessibilityIdentifier(
                        "archive.export.preparing"
                    )
                } else if let prepared {
                    ArchiveDataExportPreviewCard(
                        preview: prepared.preview
                    )

                    V25FieldSurface(
                        "外流边界",
                        note:
                            "点击导出后才会打开系统 Files 位置选择器；目标可能是 iCloud Drive 或第三方文件提供方。"
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 7
                        ) {
                            Text(
                                selection == .readableJSON
                                    ? "JSON v2 不含附件文件；不能单独还原附件。"
                                    : "完整备份含当前 active 附件，可能包含照片、化验单和敏感备注。"
                            )
                            .font(.body.weight(.bold))
                            Text(
                                "导出文件离开 App 后不再受 App Lock、温和模式或 App 内删除控制。"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                theme.secondaryText
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                    }

                    Button("丢弃并重新生成预览") {
                        Task {
                            await startPreparation()
                        }
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .accessibilityIdentifier(
                        "archive.export.regenerate"
                    )
                } else {
                    V25FieldSurface(
                        "尚未生成文件",
                        note: statusMessage
                            ?? "选择一种格式后先生成内部预览；此时不会打开 Files，也不会产生外部副本。"
                    ) {
                        Text(
                            selection.detail
                        )
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                    }
                }

                if let statusMessage,
                   prepared != nil {
                    Text(statusMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.mossText)
                        .accessibilityIdentifier("archive.export.status")
                }
                if !pendingCleanupURLs.isEmpty {
                    Button("重试清理内部临时文件") {
                        Task {
                            _ = await
                                retryPendingCleanup()
                        }
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .accessibilityIdentifier(
                        "archive.export.retryCleanup"
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if prepared != nil {
                    V25SaveBar(
                        title:
                            selection == .readableJSON
                                ? "导出 Readable JSON v2"
                                : "导出完整备份",
                        isEnabled: !isPreparing
                            && !isExporting,
                        accessibilityIdentifier:
                            "archive.export.confirm",
                        action: {
                            presentExporter()
                        }
                    )
                } else {
                    V25SaveBar(
                        title: "生成内部预览",
                        isEnabled: !isPreparing,
                        accessibilityIdentifier:
                            "archive.export.prepare",
                        action: {
                            Task {
                                await startPreparation()
                            }
                        }
                    )
                }
            }
        }
        .tint(theme.indigo)
        .interactiveDismissDisabled(
            isPreparing
                || isExporting
                || prepared?.transientPackageURL != nil
                || !pendingCleanupURLs.isEmpty
        )
        .fileExporter(
            isPresented: $isExporting,
            document: prepared?.document,
            contentType:
                prepared?.contentType ?? .json,
            defaultFilename:
                prepared?.defaultFilename,
            onCompletion: {
                result in
                Task {
                    await finishExport(result)
                }
            }
        )
        .onChange(of: isExporting) { oldValue, newValue in
            guard oldValue, !newValue else { return }
            Task { @MainActor in
                await Task.yield()
                if prepared != nil {
                    await cancelExporter()
                }
            }
        }
        .onDisappear {
            Task {
                await cancelPreparationAndWait()
                _ = await discardPreparedExport()
                _ = await retryPendingCleanup()
            }
        }
    }

    private func startPreparation() async {
        await cancelPreparationAndWait()
        guard await discardPreparedExport() else {
            return
        }
        statusMessage = nil
        guard let dataInventoryService else {
            statusMessage =
                "当前资料会话没有可用的副本生成器。"
            return
        }

        let requestedKind = selection
        let token = UUID()
        preparationToken = token
        isPreparing = true
        preparationTask = Task {
            defer {
                if preparationToken == token {
                    preparationToken = nil
                    preparationTask = nil
                    isPreparing = false
                }
            }
            do {
                let next = try await prepare(
                    requestedKind,
                    using: dataInventoryService
                )
                guard !Task.isCancelled,
                      preparationToken == token else {
                    await discard(
                        next.transientPackageURL,
                        using: dataInventoryService
                    )
                    return
                }
                prepared = next
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      preparationToken == token else {
                    return
                }
                statusMessage =
                    error.localizedDescription.isEmpty
                        ? "副本没有通过完整性核对；没有打开 Files。"
                        : "无法生成可信预览：\(error.localizedDescription)"
            }
        }
    }

    private func prepare(
        _ kind: ArchiveDataExportKind,
        using service: DataInventoryProductionService
    ) async throws -> PreparedArchiveDataExport {
        let capturedAt = Date()
        let date = Self.filenameDate(capturedAt)
        switch kind {
        case .readableJSON:
            let readable = try await service
                .readableJSONV2(capturedAt: capturedAt)
            let data = try await Task.detached {
                try PortableDataV2Codec.encode(readable)
            }.value
            return PreparedArchiveDataExport(
                preview: ArchiveDataExportPreview(
                    readableDocument: readable,
                    encodedByteCount: data.count
                ),
                document:
                    ArchiveDataExportDocument(data: data),
                stateIdentity:
                    try PortableExportStateIdentity(readable),
                transientPackageURL: nil,
                defaultFilename:
                    "Unmanual-Readable-v2-\(date)"
            )
        case .completeBackup:
            let backup = try await service
                .completeBackupPreview(
                    capturedAt: capturedAt
                )
            return PreparedArchiveDataExport(
                preview: ArchiveDataExportPreview(
                    completeBackup: backup
                ),
                document: nil,
                stateIdentity:
                    try PortableExportStateIdentity(
                        backup.readableDocument
                    ),
                transientPackageURL: nil,
                defaultFilename:
                    "Unmanual-Complete-Backup-\(date)"
            )
        }
    }

    private func presentExporter() {
        guard !isPreparing,
              !isExporting,
              let frozen = prepared,
              let dataInventoryService else {
            return
        }
        let token = UUID()
        preparationToken = token
        isPreparing = true
        preparationTask = Task {
            defer {
                if preparationToken == token {
                    preparationToken = nil
                    preparationTask = nil
                    isPreparing = false
                }
            }
            do {
                let confirmed: PreparedArchiveDataExport
                switch frozen.preview.kind {
                case .readableJSON:
                    let result = try await
                        dataInventoryService
                        .confirmedReadableJSONV2(
                            expectedIdentity:
                                frozen.stateIdentity,
                            capturedAt:
                                frozen.preview.capturedAt
                        )
                    confirmed = PreparedArchiveDataExport(
                        preview: ArchiveDataExportPreview(
                            readableDocument:
                                result.document,
                            encodedByteCount:
                                result.encodedData.count
                        ),
                        document: ArchiveDataExportDocument(
                            data: result.encodedData
                        ),
                        stateIdentity:
                            try PortableExportStateIdentity(
                                result.document
                            ),
                        transientPackageURL: nil,
                        defaultFilename:
                            frozen.defaultFilename
                    )
                case .completeBackup:
                    let snapshot = try await
                        dataInventoryService
                        .completeBackupExportSnapshot(
                            capturedAt:
                                frozen.preview.capturedAt,
                            expectedIdentity:
                                frozen.stateIdentity
                        )
                    confirmed = PreparedArchiveDataExport(
                        preview: ArchiveDataExportPreview(
                            completeBackup:
                                snapshot.backup
                        ),
                        document: ArchiveDataExportDocument(
                            snapshot: snapshot
                        ),
                        stateIdentity:
                            try PortableExportStateIdentity(
                                snapshot.backup
                                    .readableDocument
                            ),
                        transientPackageURL: nil,
                        defaultFilename:
                            frozen.defaultFilename
                    )
                }
                guard !Task.isCancelled,
                      preparationToken == token,
                      prepared?.stateIdentity
                        == frozen.stateIdentity else {
                    await discard(
                        confirmed.transientPackageURL,
                        using: dataInventoryService
                    )
                    return
                }
                if let oldURL =
                    frozen.transientPackageURL {
                    await discard(
                        oldURL,
                        using: dataInventoryService
                    )
                    guard !pendingCleanupURLs
                        .contains(oldURL) else {
                        await discard(
                            confirmed.transientPackageURL,
                            using:
                                dataInventoryService
                        )
                        return
                    }
                }
                prepared = confirmed
                isExporting = true
            } catch let error as PortableBackupError
                where error == .stateChanged {
                _ = await discardPreparedExport()
                statusMessage =
                    "预览后本地资料发生了变化；没有打开 Files，请重新生成并核对。"
            } catch {
                statusMessage =
                    "导出确认没有通过：\(error.localizedDescription)"
            }
        }
    }

    private func finishExport(
        _ result: Result<URL, Error>
    ) async {
        let exportedKind = prepared?.preview.kind
        let didCleanInternalPackage =
            await discardPreparedExport()
        switch result {
        case .success:
            if !didCleanInternalPackage {
                statusMessage =
                    "外部副本已生成，但内部临时 package 尚未清理。请留在此页并重试丢弃。"
            } else {
                statusMessage =
                    exportedKind == .completeBackup
                        ? "完整备份已交给所选位置；内部临时 package 已清理。"
                        : "Readable JSON v2 已交给所选位置。"
            }
        case let .failure(error):
            if didCleanInternalPackage {
                statusMessage =
                    "导出没有完成，内部临时 package 已清理：\(error.localizedDescription)"
            }
        }
    }

    private func cancelExporter() async {
        if await discardPreparedExport() {
            statusMessage =
                "已取消导出；本次内部临时 package 已清理。"
        }
    }

    private func close() async {
        await cancelPreparationAndWait()
        guard await discardPreparedExport() else {
            return
        }
        guard await retryPendingCleanup() else {
            return
        }
        dismiss()
    }

    private func changeSelection(
        _ newValue: ArchiveDataExportKind
    ) async {
        guard selection != newValue else { return }
        await cancelPreparationAndWait()
        guard await discardPreparedExport() else {
            return
        }
        selection = newValue
        statusMessage = nil
    }

    private func cancelPreparationAndWait() async {
        let task = preparationTask
        preparationTask = nil
        preparationToken = nil
        isPreparing = false
        task?.cancel()
        await task?.value
    }

    @discardableResult
    private func discardPreparedExport() async -> Bool {
        guard let current = prepared else { return true }
        guard let packageURL =
                current.transientPackageURL else {
            prepared = nil
            return true
        }
        guard let dataInventoryService else {
            statusMessage =
                "内部临时 package 尚未清理；当前会话缺少精确清理器。"
            return false
        }
        do {
            try await dataInventoryService
                .discardTransferPackage(at: packageURL)
            prepared = nil
            return true
        } catch {
            statusMessage =
                "内部临时 package 尚未清理：\(error.localizedDescription)"
            return false
        }
    }

    private func discard(
        _ packageURL: URL?,
        using service: DataInventoryProductionService?
    ) async {
        guard let packageURL, let service else { return }
        do {
            try await service.discardTransferPackage(
                at: packageURL
            )
        } catch {
            if !pendingCleanupURLs.contains(
                packageURL
            ) {
                pendingCleanupURLs.append(packageURL)
            }
            statusMessage =
                "内部临时 package 尚未清理；请重试后再关闭。\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func retryPendingCleanup() async -> Bool {
        guard let dataInventoryService else {
            guard !pendingCleanupURLs.isEmpty else {
                return true
            }
            statusMessage =
                "内部临时 package 尚未清理；当前会话缺少精确清理器。"
            return false
        }
        do {
            pendingCleanupURLs =
                try await dataInventoryService
                .retryPendingPackageCleanup()
            statusMessage =
                "内部临时 package 已清理。"
            return true
        } catch {
            pendingCleanupURLs =
                (try? await dataInventoryService
                    .retryPendingPackageCleanup())
                ?? pendingCleanupURLs
        }
        statusMessage =
            "仍有内部临时 package 未清理；请重试。"
        return false
    }

    private static func filenameDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone =
            TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct ArchiveDataExportKindPicker: View {
    @Environment(AppTheme.self) private var theme

    @Binding var selection: ArchiveDataExportKind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            V25SectionHeader(
                title: "选择副本格式",
                detail: "两者用途不同"
            )
            ForEach(ArchiveDataExportKind.allCases) { kind in
                Button {
                    selection = kind
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Rectangle()
                            .fill(
                                selection == kind
                                    ? theme.vermilion
                                    : theme.blue
                            )
                            .frame(width: 5, height: 46)
                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {
                            Text(kind.title)
                                .font(.body.weight(.black))
                            Text(kind.detail)
                                .font(.caption)
                                .foregroundStyle(
                                    theme.secondaryText
                                )
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                        Spacer(minLength: 8)
                        Text(kind.badge)
                            .font(theme.utility(9))
                            .tracking(0.6)
                        Image(
                            systemName:
                                selection == kind
                                    ? "checkmark.square.fill"
                                    : "square"
                        )
                    }
                    .foregroundStyle(theme.indigoDeep)
                    .padding(13)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 72,
                        alignment: .leading
                    )
                    .background(theme.paper)
                    .overlay {
                        Rectangle().stroke(
                            selection == kind
                                ? theme.vermilion
                                : theme.indigo,
                            lineWidth:
                                selection == kind ? 2 : 1
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(V25PressStyle())
                .accessibilityLabel(
                    "\(kind.title)，\(kind.detail)"
                )
                .accessibilityValue(
                    selection == kind ? "已选择" : "未选择"
                )
                .accessibilityIdentifier(
                    "archive.export.kind.\(kind.rawValue)"
                )
            }
        }
    }
}

private struct ArchiveDataExportPreviewCard: View {
    @Environment(AppTheme.self) private var theme

    let preview: ArchiveDataExportPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("FROZEN PREVIEW")
                        .font(theme.utility(10))
                        .tracking(1)
                        .foregroundStyle(theme.mustard)
                    Text(preview.kind.title)
                        .font(
                            theme.display(
                                27,
                                relativeTo: .title2
                            )
                        )
                }
                Spacer(minLength: 8)
                Text("SCHEMA \(preview.schemaVersion)")
                    .font(theme.utility(9))
                    .tracking(0.5)
                    .padding(.horizontal, 7)
                    .frame(minHeight: 26)
                    .overlay {
                        Rectangle().stroke(
                            theme.paper,
                            lineWidth: 1
                        )
                    }
            }

            Rectangle().fill(theme.paper).frame(height: 1)

            HStack(spacing: 14) {
                metric(preview.recordCount, "事实")
                metric(preview.controlCount, "控制")
                metric(preview.attachmentCount, "附件")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "生成于 "
                        + preview.capturedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                )
                Text(
                    "内容大小 "
                        + ByteCountFormatter.string(
                            fromByteCount: preview.byteCount,
                            countStyle: .file
                        )
                )
                Text(
                    "完整性摘要 "
                        + preview.shortIntegrityDigest
                        + "…"
                )
                .monospaced()
            }
            .font(.caption)
            .foregroundStyle(theme.paper)
        }
        .foregroundStyle(theme.paper)
        .padding(16)
        .background(theme.indigoDeep)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.moss).frame(width: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(preview.kind.title)预览，"
                + "\(preview.recordCount) 条事实，"
                + "\(preview.controlCount) 条控制记录，"
                + "\(preview.attachmentCount) 个附件"
        )
        .accessibilityIdentifier(
            "archive.export.preview"
        )
    }

    private func metric(
        _ value: Int,
        _ label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(
                    theme.display(
                        29,
                        relativeTo: .title2
                    )
                )
                .monospacedDigit()
            Text(label)
                .font(.caption.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct LegacyArchiveDataImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppTheme.self) private var theme

    @State private var isChoosingFile = false
    @State private var selectedFilename: String?
    @State private var backup: AppDataBackup?
    @State private var importResult: AppDataImportResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "LEGACY V1 / IMPORT",
                eyebrow: "DEBUG LAB ONLY",
                title: "Legacy JSON v1 实验室",
                detail:
                    "这是旧版按 ID 合并器，与 Readable JSON v2 和完整备份无关；不得用于恢复真实资料。",
                cancel: dismiss.callAsFunction
            ) {
                if let importResult {
                    ArchiveImportReceipt(result: importResult)
                } else if let backup {
                    ArchiveTransferManifest(backup: backup)

                    V25SectionHeader(title: "文件内容", detail: selectedFilename ?? "JSON")
                    ArchiveTransferSummary(backup: backup)

                    V25SectionHeader(
                        title: "Legacy v1 写入规则",
                        detail: "仅供隔离的 DEBUG 测试"
                    )
                    ArchiveMergeRules()

                    Button("改选其他备份") {
                        isChoosingFile = true
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .accessibilityIdentifier("archive.import.chooseAnother")
                } else {
                    ArchiveImportPicker(action: { isChoosingFile = true })
                }

                V25PrivacyFooter(
                    text:
                        "此入口不会读取 Readable JSON v2 或完整备份，也不代表 Batch 7 恢复路径。请勿放入真实医疗资料。"
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilionText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("archive.import.error")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if importResult != nil {
                    V25SaveBar(
                        title: "完成",
                        isEnabled: true,
                        accessibilityIdentifier: "archive.import.done",
                        action: dismiss.callAsFunction
                    )
                } else if let backup {
                    V25SaveBar(
                        title:
                            "运行 Legacy v1 合并 \(backup.totalRecordCount) 条",
                        isEnabled: backup.totalRecordCount > 0,
                        accessibilityIdentifier: "archive.import.confirm",
                        action: importSelectedBackup
                    )
                }
            }
        }
        .tint(theme.indigo)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleFileSelection
        )
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let decoded = try AppDataBackupService.decode(Data(contentsOf: url))
            guard decoded.totalRecordCount > 0 else {
                throw ArchiveDataTransferError.emptyBackup
            }
            backup = decoded
            selectedFilename = url.lastPathComponent
            errorMessage = nil
        } catch let error as AppDataBackupError {
            backup = nil
            selectedFilename = nil
            errorMessage = error.localizedDescription
        } catch let error as ArchiveDataTransferError {
            backup = nil
            selectedFilename = nil
            errorMessage = error.localizedDescription
        } catch {
            backup = nil
            selectedFilename = nil
            errorMessage =
                "无法读取这个 Legacy v1 文件。Readable JSON v2 和完整备份不会由此入口处理。"
        }
    }

    private func importSelectedBackup() {
        guard let backup else { return }
        do {
            importResult = try AppDataBackupService.importBackup(backup, into: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = "没有导入任何内容。当前页面会保留文件预览，你可以稍后重试。"
        }
    }
}

private struct ArchiveTransferManifest: View {
    @Environment(AppTheme.self) private var theme

    let backup: AppDataBackup

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.rose)
                .offset(x: 6, y: 6)

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LEGACY V1 FOUND")
                            .font(theme.utility(10))
                            .tracking(1)
                            .foregroundStyle(theme.mustard)
                        Text("等待确认的旧版测试文件")
                            .font(theme.display(24, relativeTo: .title2))
                    }
                    Spacer(minLength: 8)
                    Text("V\(backup.schemaVersion)")
                        .font(theme.utility(11))
                        .tracking(0.8)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 28)
                        .overlay { Rectangle().stroke(theme.paper, lineWidth: 1) }
                }

                Rectangle().fill(theme.paper).frame(height: 1)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(backup.totalRecordCount, format: .number)
                        .font(theme.display(40, relativeTo: .largeTitle))
                        .monospacedDigit()
                    Text("条记录")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Text(backup.exportedAt, format: .dateTime.year().month().day())
                        .font(theme.utility(10))
                        .tracking(0.5)
                }
            }
            .foregroundStyle(theme.paper)
            .padding(16)
            .background(theme.indigoDeep)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unmanual 备份，版本 \(backup.schemaVersion)，共 \(backup.totalRecordCount) 条记录")
    }
}

private struct ArchiveTransferSummary: View {
    @Environment(AppTheme.self) private var theme

    let backup: AppDataBackup

    var body: some View {
        VStack(spacing: 0) {
            row(
                code: "01",
                title: "旅程",
                count: backup.entries.count,
                color: theme.vermilion,
                textColor: theme.vermilionText
            )
            row(
                code: "02",
                title: "检查项目",
                count: backup.labRecords.count,
                color: theme.blue,
                textColor: theme.blueText
            )
            row(
                code: "03",
                title: "方案版本",
                count: backup.regimens.count,
                color: theme.moss,
                textColor: theme.mossText
            )
            row(
                code: "04",
                title: "开始日与 Countdown",
                count: backup.profiles.count + backup.countdowns.count,
                color: theme.mustard,
                textColor: theme.mustardText
            )
        }
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func row(
        code: String,
        title: String,
        count: Int,
        color: Color,
        textColor: Color
    ) -> some View {
        HStack(spacing: 12) {
            Text(code)
                .font(theme.utility(10))
                .foregroundStyle(textColor)
                .frame(width: 24, alignment: .leading)
            Rectangle().fill(color).frame(width: 4, height: 28)
            Text(title)
                .font(.body.weight(.black))
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(theme.display(23, relativeTo: .title3))
                .monospacedDigit()
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.secondaryText).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ArchiveMergeRules: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            rule("同一 ID 的记录", "当前原型使用文件内容；正式冲突策略未实现", color: theme.blue)
            rule("文件中的新记录", "当前原型添加到本机；dataset 语义未实现", color: theme.moss)
            rule("只在本机的记录", "当前原型继续保留；这不是同步协议", color: theme.mustard)
        }
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func rule(_ title: String, _ result: String, color: Color) -> some View {
        HStack(spacing: 11) {
            Rectangle().fill(color).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.black))
                Text(result)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.caption.weight(.black))
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.secondaryText).frame(height: 1)
        }
    }
}

private struct ArchiveImportPicker: View {
    @Environment(AppTheme.self) private var theme

    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("01 / 选择文件")
                .font(theme.utility(10))
                .tracking(0.9)
                .foregroundStyle(theme.vermilionText)
            Text("选择 Legacy v1 测试文件")
                .font(theme.display(27, relativeTo: .title2))
                .foregroundStyle(theme.indigoDeep)
            Text("仅支持旧版开发期 JSON v1。Readable JSON v2 和完整备份不会进入这个写入器；选中后先展示清单，不会立即改变记录。")
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("选择 Legacy v1 文件", action: action)
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("archive.import.chooseFile")
        }
        .padding(16)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.vermilion).frame(width: 5)
        }
    }
}

private struct ArchiveImportReceipt: View {
    @Environment(AppTheme.self) private var theme

    let result: AppDataImportResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("IMPORT COMPLETE")
                .font(theme.utility(10))
                .tracking(1)
                .foregroundStyle(theme.mustard)
            Text("数据已经合并")
                .font(theme.display(31, relativeTo: .title))
            Rectangle().fill(theme.paper).frame(height: 1)
            HStack(spacing: 18) {
                receiptCount(result.insertedCount, label: "新增")
                receiptCount(result.updatedCount, label: "更新")
            }
            Text("本机中没有出现在备份里的记录仍然保留。")
                .font(.caption)
                .foregroundStyle(theme.paper)
        }
        .foregroundStyle(theme.paper)
        .padding(17)
        .background(theme.indigoDeep)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.moss).frame(width: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archive.import.receipt")
    }

    private func receiptCount(_ count: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(count, format: .number)
                .font(theme.display(31, relativeTo: .title))
                .monospacedDigit()
            Text(label).font(.caption.weight(.bold))
        }
    }
}

private enum ArchiveDataTransferError: LocalizedError {
    case emptyBackup

    var errorDescription: String? {
        "这个备份里没有可导入的记录。"
    }
}
#endif
