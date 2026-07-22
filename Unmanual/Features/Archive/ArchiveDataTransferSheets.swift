import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
@MainActor
struct ArchiveDataExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    @Query(sort: \HRTProfile.startDate) private var profiles: [HRTProfile]
    @Query(sort: \CountdownRecord.targetDate, order: .reverse) private var countdowns: [CountdownRecord]
    @Query(sort: \JourneyEntry.occurredAt, order: .reverse) private var entries: [JourneyEntry]
    @Query(sort: \LabRecord.sampledAt, order: .reverse) private var labRecords: [LabRecord]
    @Query(sort: \RegimenVersion.startedAt, order: .reverse) private var regimens: [RegimenVersion]

    @State private var document: AppDataBackupDocument?
    @State private var isExporting = false
    @State private var statusMessage: String?

    private var backup: AppDataBackup {
        AppDataBackupService.makeBackup(
            profiles: profiles,
            countdowns: countdowns,
            entries: entries,
            labRecords: labRecords,
            regimens: regimens
        )
    }

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "DATA / EXPORT",
                eyebrow: "DEVELOPMENT COPY",
                title: "试验 JSON 导出",
                detail: "生成开发期结构副本；它不是完整或安全备份，也没有通过 Files/iCloud 发行门禁。",
                cancel: dismiss.callAsFunction
            ) {
                ArchiveTransferManifest(backup: backup, mode: .export)

                V25SectionHeader(title: "结构副本范围", detail: "共 \(backup.totalRecordCount) 条")
                ArchiveTransferSummary(backup: backup)

                V25FieldSurface(
                    "文件说明",
                    note: "Files 位置可能包含 iCloud Drive 或第三方提供方；这里只用于开发数据。"
                ) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("JSON · 格式版本 \(backup.schemaVersion)")
                            .font(.body.weight(.black))
                        Text("包含记录原文、日期、单位和方案关联；不包含账号或设备标识。")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.mossText)
                        .accessibilityIdentifier("archive.export.status")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V25SaveBar(
                    title: "生成试验 JSON",
                    isEnabled: backup.totalRecordCount > 0,
                    accessibilityIdentifier: "archive.export.generate",
                    action: prepareExport
                )
            }
        }
        .tint(theme.indigo)
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .json,
            defaultFilename: defaultFilename
        ) { result in
            switch result {
            case .success:
                statusMessage = "试验 JSON 已交给所选位置；它不代表完整或安全备份。"
            case let .failure(error):
                statusMessage = "没有生成文件：\(error.localizedDescription)"
            }
        }
    }

    private func prepareExport() {
        do {
            document = try AppDataBackupDocument(backup: backup)
            isExporting = true
        } catch {
            statusMessage = "暂时无法生成备份，请稍后再试。"
        }
    }

    private var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Unmanual-Backup-\(formatter.string(from: Date()))"
    }
}

@MainActor
struct ArchiveDataImportSheet: View {
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
                register: "DATA / IMPORT",
                eyebrow: "DEVELOPMENT MERGE",
                title: "试验 JSON 导入",
                detail: "当前只按 ID 试验写入，没有 dataset、digest 或正式冲突处理；仅使用开发数据。",
                cancel: dismiss.callAsFunction
            ) {
                if let importResult {
                    ArchiveImportReceipt(result: importResult)
                } else if let backup {
                    ArchiveTransferManifest(backup: backup, mode: .import)

                    V25SectionHeader(title: "文件内容", detail: selectedFilename ?? "JSON")
                    ArchiveTransferSummary(backup: backup)

                    V25SectionHeader(title: "原型写入规则", detail: "仅供 DEBUG")
                    ArchiveMergeRules()

                    Button("改选其他备份") {
                        isChoosingFile = true
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .accessibilityIdentifier("archive.import.chooseAnother")
                } else {
                    ArchiveImportPicker(action: { isChoosingFile = true })
                }

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
                        title: "确认导入 \(backup.totalRecordCount) 条记录",
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
            errorMessage = "无法读取这个文件。请选择由 Unmanual 生成的 JSON 备份。"
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

private enum ArchiveTransferMode {
    case export
    case `import`
}

private struct ArchiveTransferManifest: View {
    @Environment(AppTheme.self) private var theme

    let backup: AppDataBackup
    let mode: ArchiveTransferMode

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(mode == .export ? theme.mustard : theme.rose)
                .offset(x: 6, y: 6)

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mode == .export ? "UNMANUAL BACKUP" : "BACKUP FOUND")
                            .font(theme.utility(10))
                            .tracking(1)
                            .foregroundStyle(theme.mustard)
                        Text(mode == .export ? "可带走的本机副本" : "等待确认的备份")
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
            Text("先找到你的备份")
                .font(theme.display(27, relativeTo: .title2))
                .foregroundStyle(theme.indigoDeep)
            Text("支持由 Unmanual 导出的 JSON 文件。选中后这里只展示清单，不会立即改变本机记录。")
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("选择备份文件", action: action)
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

private struct AppDataBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(backup: AppDataBackup) throws {
        data = try AppDataBackupService.encode(backup)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum ArchiveDataTransferError: LocalizedError {
    case emptyBackup

    var errorDescription: String? {
        "这个备份里没有可导入的记录。"
    }
}
#endif
