import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentPhotoTransfer: Transferable, Sendable {
    let data: Data
    let typeIdentifier: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let payload = try AttachmentImportFacts.loadBoundedFile(
                at: received.file
            )
            guard UTType(payload.typeIdentifier)?.conforms(to: .image)
                    == true else {
                throw AttachmentFileStoreFailure.invalidInput
            }
            return AttachmentPhotoTransfer(
                data: payload.data,
                typeIdentifier: payload.typeIdentifier
            )
        }
    }
}

struct AttachmentPhotoImportResult: Sendable {
    let drafts: [AttachmentDraft]
    let failureCount: Int
}

@MainActor
func importAttachmentPhotos(
    _ items: [PhotosPickerItem],
    existingAttachments: [AttachmentDraft],
    batchIsCurrent: @escaping @MainActor () -> Bool,
    filenamePrefix: String
) async -> AttachmentPhotoImportResult? {
    let remainingSlots = AttachmentSelectionCapacity.remainingSlots(
        existingCount: existingAttachments.count
    )
    let acceptedItems = Array(items.prefix(remainingSlots))
    var failureCount = AttachmentSelectionCapacity.rejectedSelectionCount(
        selectedCount: items.count,
        existingCount: existingAttachments.count
    )
    var imported: [AttachmentDraft] = []

    for item in acceptedItems {
        guard !Task.isCancelled else { return nil }
        let transferred: AttachmentPhotoTransfer
        do {
            guard let loaded = try await item.loadTransferable(
                type: AttachmentPhotoTransfer.self
            ) else {
                failureCount += 1
                continue
            }
            transferred = loaded
        } catch {
            failureCount += 1
            continue
        }
        guard !Task.isCancelled else { return nil }
        guard batchIsCurrent() else {
            return AttachmentPhotoImportResult(
                drafts: [],
                failureCount: items.count
            )
        }
        let currentDrafts = existingAttachments + imported
        guard canAppendAttachment(
            byteCount: Int64(transferred.data.count),
            to: currentDrafts
        ) else {
            failureCount += 1
            continue
        }
        imported.append(
            AttachmentDraft(
                data: transferred.data,
                filename:
                    "\(filenamePrefix)-\(existingAttachments.count + imported.count + 1)",
                typeIdentifier: transferred.typeIdentifier
            )
        )
    }
    guard !Task.isCancelled else { return nil }
    guard batchIsCurrent() else {
        return AttachmentPhotoImportResult(
            drafts: [],
            failureCount: items.count
        )
    }
    return AttachmentPhotoImportResult(
        drafts: imported,
        failureCount: failureCount
    )
}

@MainActor
func importAttachmentFiles(
    _ urls: [URL],
    existingAttachments: [AttachmentDraft],
    batchIsCurrent: @escaping @MainActor () -> Bool
) async -> AttachmentPhotoImportResult? {
    guard !Task.isCancelled else { return nil }
    let result = await AttachmentFileImportWorker.shared.load(
        urls: urls,
        existingByteCounts:
            existingAttachments.map { Int64($0.data.count) }
    )
    guard !Task.isCancelled else { return nil }
    guard batchIsCurrent() else {
        return AttachmentPhotoImportResult(
            drafts: [],
            failureCount: urls.count
        )
    }
    return AttachmentPhotoImportResult(
        drafts: result.items.map {
            AttachmentDraft(
                data: $0.data,
                filename: $0.filename,
                typeIdentifier: $0.typeIdentifier
            )
        },
        failureCount: result.failureCount
    )
}

struct LabResultDraft: Identifiable {
    let id = UUID()
    var definitionID: UUID?
    var name = ""
    var code = ""
    var value = ""
    var unit = ""
    var reference = ""
    var variant = ""

    var isEmpty: Bool {
        [name, code, value, unit, reference, variant].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (try? LabDecimalValue.parse(value)) != nil
    }
}

@MainActor
struct LabSampleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var reader
    @Environment(\.attachmentMutationService) private var attachmentService
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @Environment(AppTheme.self) private var theme

    @State private var specimen = ""
    @State private var note = ""
    @State private var occurredAt = Date()
    @State private var results = [LabResultDraft()]
    @State private var definitions: [LabItemDefinitionSnapshot] = []
    @State private var attachments: [AttachmentDraft] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoImportState = AttachmentImportBatchState()
    @State private var photoImportTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var importsFiles = false

    private var canSave: Bool {
        AttachmentImportGate.allowsSave(
            baseConditionsMet: !isSaving
                && results.allSatisfy { $0.isEmpty || $0.isComplete }
                && (
                    results.contains(where: \.isComplete)
                        || !attachments.isEmpty
                ),
            isImporting: photoImportState.isImporting,
            hasUnresolvedFailures: photoImportState.hasUnresolvedFailures
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorHeader(register: "LOCAL / LAB", title: "添加化验")
                    Text("一张报告是一条样本；同一项目重复出现时，会按原顺序分别保存。")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)

                    dateSection
                    labeledField("样本类型（可选）", text: $specimen, prompt: "例如：血清")
                    labeledField("情境备注（可选）", text: $note, prompt: "例如：空腹；报告原注")

                    V25SectionHeader(title: "化验结果", detail: "\(results.filter(\.isComplete).count) 项")
                    ForEach($results) { $result in
                        labResultBlock(result: $result)
                    }
                    Button {
                        results.append(LabResultDraft())
                    } label: {
                        Label("再添加一个结果", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(V25SecondaryButtonStyle())

                    AttachmentPickerSection(
                        attachments: $attachments,
                        photoItems: $photoItems,
                        isImporting: photoImportState.isImporting,
                        unresolvedFailureCount:
                            photoImportState.unresolvedFailureCount,
                        resolveImportFailures: {
                            photoImportState.resolveFailures()
                        },
                        importFiles: { importsFiles = true }
                    )

                    Text("App 保存你选择的原始字节，不做 OCR、转码或 EXIF 清理。单个附件最多 20 MiB；本条最多 6 个、合计 60 MiB。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    V25PrivacyFooter(
                        text: SystemBackupDisclosure.attachmentSelection
                    )
                        .padding(.bottom, 80)
                }
                .padding(V25Theme.pagePadding)
                .frame(maxWidth: V25Theme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.rice.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                V25SaveBar(
                    title: "保存化验",
                    isEnabled: canSave,
                    accessibilityIdentifier: "labSample.save",
                    action: save
                )
            }
        }
        .tint(theme.indigo)
        .localSaveErrorAlert(message: $errorMessage)
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            photoImportTask?.cancel()
            let batchID = photoImportState.begin(
                selectedCount: newItems.count
            )
            let existingAttachments = attachments
            photoImportTask = Task {
                guard let result = await importAttachmentPhotos(
                    newItems,
                    existingAttachments: existingAttachments,
                    batchIsCurrent: {
                        photoImportState.isCurrent(batchID)
                    },
                    filenamePrefix: "照片"
                ) else { return }
                guard photoImportState.isCurrent(batchID) else { return }
                photoImportState.recordFailures(result.failureCount)
                _ = photoImportState.finish(batchID)
                attachments.append(contentsOf: result.drafts)
                photoItems = []
                if result.failureCount > 0 {
                    errorMessage =
                        "有 \(result.failureCount) 个所选照片没有导入。记录尚未保存；请检查后重新选择。"
                }
            }
        }
        .onDisappear {
            photoImportTask?.cancel()
        }
        .task { await loadDefinitions() }
#if DEBUG
        .fileImporter(
            isPresented: $importsFiles,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
#endif
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("采样时间")
                .font(.caption.weight(.black))
            DatePicker(
                "采样时间",
                selection: $occurredAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
        }
    }

    private func labResultBlock(result: Binding<LabResultDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RESULT / 结果")
                    .font(theme.utility(9))
                    .foregroundStyle(theme.blueText)
                Spacer()
                if results.count > 1 {
                    Button("移除", role: .destructive) {
                        results.removeAll { $0.id == result.wrappedValue.id }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            if !definitions.filter({ !$0.isArchived }).isEmpty {
                Picker("项目来源", selection: result.definitionID) {
                    Text("新建自定义项目").tag(UUID?.none)
                    ForEach(definitions.filter { !$0.isArchived }) { definition in
                        Text(definition.displayName).tag(UUID?.some(definition.id))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: result.wrappedValue.definitionID) { _, selectedID in
                    if let definition = definitions.first(where: { $0.id == selectedID }) {
                        result.wrappedValue.name = definition.displayName
                        result.wrappedValue.code = definition.code
                    }
                }
            }
            labeledField("项目名称", text: result.name, prompt: "按报告原文填写")
                .disabled(result.wrappedValue.definitionID != nil)
            labeledField("项目代码（可选）", text: result.code, prompt: "按报告原文填写")
                .disabled(result.wrappedValue.definitionID != nil)
            labeledField("结果", text: result.value, prompt: "例如：< 172.50")
                .keyboardType(.numbersAndPunctuation)
            labeledField("单位", text: result.unit, prompt: "按报告原文填写")
            labeledField("参考区间（可选）", text: result.reference, prompt: "不据此自动判定")
            labeledField("检测方法 / 变体（可选）", text: result.variant, prompt: "例如：方法 A")
            if !result.wrappedValue.value.isEmpty,
               (try? LabDecimalValue.parse(result.wrappedValue.value)) == nil {
                Text("请输入有限十进制；可以带 <、≤、> 或 ≥。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.vermilionText)
            }
        }
        .padding(15)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func save() {
        guard canSave, let attachmentService else {
            errorMessage = "本地资料尚未准备好，或还有未填写完整的结果。"
            return
        }
        let completed = results.filter(\.isComplete)
        let prepared = completed.map { draft in
            (draft: draft, definitionID: draft.definitionID ?? UUID())
        }
        let sampleID = UUID()
        let timestamp: HistoricalTimestamp
        do {
            timestamp = try HistoricalTimestamp.captured(
                instant: occurredAt,
                timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                precision: .minute,
                provenance: .userEntered
            )
        } catch {
            errorMessage = "采样时间无法保存，请重新选择。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await attachmentService.createLabSample(
                    CreateLabSampleCommand(
                        operationID: UUID(),
                        sampleID: sampleID,
                        timestamp: timestamp,
                        specimenOriginal: specimen,
                        contextNote: note,
                        newDefinitions: prepared.compactMap {
                            guard $0.draft.definitionID == nil else { return nil }
                            return LabItemDefinitionInput(
                                id: $0.definitionID,
                                displayName: $0.draft.name,
                                code: $0.draft.code
                            )
                        },
                        results: prepared.map {
                            LabResultInput(
                                itemDefinitionID: $0.definitionID,
                                rawValueOriginal: $0.draft.value,
                                unitOriginal: $0.draft.unit,
                                referenceRangeOriginal: $0.draft.reference,
                                assayOrVariantOriginal: $0.draft.variant
                            )
                        },
                        committedAt: Date()
                    ),
                    attachmentDrafts: attachments
                )
                dismiss()
            } catch {
                if error as? AttachmentMutationFailure == .recoveryRequired {
                    errorMessage =
                        "附件没有完成安全收尾。App 已暂停本地资料访问。"
                } else {
                    errorMessage =
                        "记录仍保留在当前页面，请检查后再保存。"
                }
            }
        }
    }

    private func loadDefinitions() async {
        guard let reader else { return }
        do {
            definitions = try await reader.labItemDefinitions()
        } catch {
            if error as? AppDataFailure == .corruptionSuspected {
                integrityFailureHandler?()
                errorMessage =
                    "化验项目没有通过本地完整性检查。App 将进入恢复模式。"
            } else {
                errorMessage =
                    "暂时无法读取化验项目；原资料没有被修改。"
            }
        }
    }

#if DEBUG
    private func importFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else {
            photoImportState.recordFailures(1)
            errorMessage =
                "无法读取所选文件。记录尚未保存；请检查文件后重新选择。"
            return
        }
        photoImportTask?.cancel()
        let batchID = photoImportState.begin(selectedCount: urls.count)
        let existingAttachments = attachments
        photoImportTask = Task {
            guard let result = await importAttachmentFiles(
                urls,
                existingAttachments: existingAttachments,
                batchIsCurrent: {
                    photoImportState.isCurrent(batchID)
                }
            ) else { return }
            guard photoImportState.isCurrent(batchID) else { return }
            photoImportState.recordFailures(result.failureCount)
            _ = photoImportState.finish(batchID)
            attachments.append(contentsOf: result.drafts)
            if result.failureCount > 0 {
                errorMessage =
                    "有 \(result.failureCount) 个所选文件没有导入。记录尚未保存；单个附件最多 20 MiB，本条最多 6 个、合计 60 MiB。"
            }
        }
    }
#endif
}

@MainActor
struct StatusObservationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var reader
    @Environment(\.appDataWriter) private var writer
    @Environment(\.attachmentMutationService) private var attachmentService
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @Environment(AppTheme.self) private var theme

    @State private var metrics: [StatusMetricSnapshot] = []
    @State private var selectedMetricID: UUID?
    @State private var newMetricName = ""
    @State private var level = 2
    @State private var note = ""
    @State private var occurredAt = Date()
    @State private var attachments: [AttachmentDraft] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoImportState = AttachmentImportBatchState()
    @State private var photoImportTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var importsFiles = false
    @State private var metricPendingArchive: UUID?

    private var canSave: Bool {
        AttachmentImportGate.allowsSave(
            baseConditionsMet: !isSaving && (
                selectedMetricID != nil
                    || (
                        !newMetricName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            && metrics.filter { !$0.isArchived }.count < 5
                    )
            ),
            isImporting: photoImportState.isImporting,
            hasUnresolvedFailures: photoImportState.hasUnresolvedFailures
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorHeader(register: "LOCAL / STATUS", title: "记录状态")
                    Text(StatusScaleCopy.editorGuidance)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)

                    if !metrics.filter({ !$0.isArchived }).isEmpty {
                        Picker("指标", selection: $selectedMetricID) {
                            Text("新建指标").tag(UUID?.none)
                            ForEach(metrics.filter { !$0.isArchived }) { metric in
                                Text(metric.displayName).tag(UUID?.some(metric.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                    }
                    if let selectedMetricID {
                        Button("归档这个指标", role: .destructive) {
                            metricPendingArchive = selectedMetricID
                        }
                        .frame(minHeight: 44)
                    }
                    if selectedMetricID == nil {
                        labeledField(
                            "新指标名称",
                            text: $newMetricName,
                            prompt: metrics.filter { !$0.isArchived }.count >= 5
                                ? "已达到 5 项上限"
                                : "例如：精力"
                        )
                        .disabled(metrics.filter { !$0.isArchived }.count >= 5)
                    }

                    V25SectionHeader(title: "级别", detail: "第 \(level) 级，共 4 级")
                    HStack(spacing: 8) {
                        ForEach(1...4, id: \.self) { value in
                            Button {
                                level = value
                            } label: {
                                VStack(spacing: 4) {
                                    Text("\(value)").font(.headline.weight(.black))
                                    Text("第 \(value) 级").font(.caption2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .foregroundStyle(level == value ? theme.paper : theme.indigo)
                                .background(level == value ? theme.indigo : theme.paper)
                                .overlay {
                                    Rectangle().stroke(theme.indigo, lineWidth: level == value ? 3 : 1.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("第 \(value) 级，共 4 级")
                            .accessibilityHint(StatusScaleCopy.accessibilityHint)
                            .accessibilityAddTraits(level == value ? .isSelected : [])
                        }
                    }
                    labeledField("备注（可选）", text: $note, prompt: "这一刻有什么上下文")
                    DatePicker(
                        "记录时间",
                        selection: $occurredAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)

                    AttachmentPickerSection(
                        attachments: $attachments,
                        photoItems: $photoItems,
                        isImporting: photoImportState.isImporting,
                        unresolvedFailureCount:
                            photoImportState.unresolvedFailureCount,
                        resolveImportFailures: {
                            photoImportState.resolveFailures()
                        },
                        importFiles: { importsFiles = true }
                    )
                    Text("App 保存你选择的原始字节，不做 OCR、转码或 EXIF 清理。单个附件最多 20 MiB；本条最多 6 个、合计 60 MiB。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    V25PrivacyFooter(
                        text: SystemBackupDisclosure.attachmentSelection
                    )
                        .padding(.bottom, 80)
                }
                .padding(V25Theme.pagePadding)
                .frame(maxWidth: V25Theme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(theme.rice.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                V25SaveBar(
                    title: "保存状态",
                    isEnabled: canSave,
                    accessibilityIdentifier: "status.save",
                    action: save
                )
            }
        }
        .localSaveErrorAlert(message: $errorMessage)
        .task { await loadMetrics() }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoImportTask?.cancel()
            let batchID = photoImportState.begin(
                selectedCount: items.count
            )
            let existingAttachments = attachments
            photoImportTask = Task {
                guard let result = await importAttachmentPhotos(
                    items,
                    existingAttachments: existingAttachments,
                    batchIsCurrent: {
                        photoImportState.isCurrent(batchID)
                    },
                    filenamePrefix: "状态附件"
                ) else { return }
                guard photoImportState.isCurrent(batchID) else { return }
                photoImportState.recordFailures(result.failureCount)
                _ = photoImportState.finish(batchID)
                attachments.append(contentsOf: result.drafts)
                photoItems = []
                if result.failureCount > 0 {
                    errorMessage =
                        "有 \(result.failureCount) 个所选照片没有导入。状态尚未保存；请检查后重新选择。"
                }
            }
        }
        .onDisappear {
            photoImportTask?.cancel()
        }
        .confirmationDialog(
            "归档后，旧记录仍会保留；这个指标不再出现在新记录选项中。",
            isPresented: Binding(
                get: { metricPendingArchive != nil },
                set: { if !$0 { metricPendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("归档指标", role: .destructive) {
                archivePendingMetric()
            }
            Button("取消", role: .cancel) {
                metricPendingArchive = nil
            }
        }
#if DEBUG
        .fileImporter(
            isPresented: $importsFiles,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: true,
            onCompletion: importStatusFiles
        )
#endif
    }

    private func save() {
        guard canSave, let attachmentService else {
            errorMessage = "请选择或新建一个状态指标。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let metricID: UUID
                let newMetric: NewStatusMetricInput?
                if let selectedMetricID {
                    metricID = selectedMetricID
                    newMetric = nil
                } else {
                    metricID = UUID()
                    newMetric = NewStatusMetricInput(
                        operationID: UUID(),
                        metricID: metricID,
                        displayName: newMetricName
                    )
                }
                let timestamp = try HistoricalTimestamp.captured(
                    instant: occurredAt,
                    timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                    precision: .minute,
                    provenance: .userEntered
                )
                let observationID = UUID()
                _ = try await attachmentService.recordStatusObservation(
                    RecordStatusObservationCommand(
                        operationID: UUID(),
                        observationID: observationID,
                        metricDefinitionID: metricID,
                        newMetric: newMetric,
                        ordinalLevel: level,
                        note: note,
                        timestamp: timestamp
                    ),
                    attachmentDrafts: attachments
                )
                dismiss()
            } catch {
                if error as? AttachmentMutationFailure == .recoveryRequired {
                    errorMessage =
                        "附件没有完成安全收尾。App 已暂停本地资料访问。"
                } else {
                    errorMessage = "状态仍保留在当前页面，请检查后再保存。"
                }
            }
        }
    }

    private func archivePendingMetric() {
        guard let metricID = metricPendingArchive, let writer else { return }
        metricPendingArchive = nil
        Task {
            do {
                _ = try await writer.archiveStatusMetric(
                    ArchiveStatusMetricCommand(
                        operationID: UUID(),
                        metricID: metricID
                    )
                )
                await loadMetrics()
            } catch {
                errorMessage = "这个指标没有归档，请稍后重试。"
            }
        }
    }

    private func loadMetrics() async {
        guard let reader else { return }
        do {
            let loaded = try await reader.statusMetrics()
            metrics = loaded
            selectedMetricID = loaded.first(where: { !$0.isArchived })?.id
        } catch {
            if error as? AppDataFailure == .corruptionSuspected {
                integrityFailureHandler?()
                errorMessage =
                    "状态指标没有通过本地完整性检查。App 将进入恢复模式。"
            } else {
                errorMessage =
                    "暂时无法读取状态指标；原资料没有被修改。"
            }
        }
    }

#if DEBUG
    private func importStatusFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else {
            photoImportState.recordFailures(1)
            errorMessage =
                "无法读取所选文件。状态尚未保存；请检查文件后重新选择。"
            return
        }
        photoImportTask?.cancel()
        let batchID = photoImportState.begin(selectedCount: urls.count)
        let existingAttachments = attachments
        photoImportTask = Task {
            guard let result = await importAttachmentFiles(
                urls,
                existingAttachments: existingAttachments,
                batchIsCurrent: {
                    photoImportState.isCurrent(batchID)
                }
            ) else { return }
            guard photoImportState.isCurrent(batchID) else { return }
            photoImportState.recordFailures(result.failureCount)
            _ = photoImportState.finish(batchID)
            attachments.append(contentsOf: result.drafts)
            if result.failureCount > 0 {
                errorMessage =
                    "有 \(result.failureCount) 个所选文件没有导入。状态尚未保存；单个附件最多 20 MiB，本条最多 6 个、合计 60 MiB。"
            }
        }
    }
#endif
}

struct AttachmentPickerSection: View {
    @Environment(AppTheme.self) private var theme
    @Binding var attachments: [AttachmentDraft]
    @Binding var photoItems: [PhotosPickerItem]
    let isImporting: Bool
    let unresolvedFailureCount: Int
    let resolveImportFailures: () -> Void
    let importFiles: () -> Void

    var body: some View {
        let selectionLabel = attachmentSelectionLabel
        VStack(alignment: .leading, spacing: 10) {
            V25SectionHeader(title: "附件", detail: "\(attachments.count) / 6")
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: AttachmentSelectionCapacity.pickerLimit(
                    existingCount: attachments.count
                ),
                matching: .images,
                preferredItemEncoding: .current
            ) {
                Label(
                    selectionLabel,
                    systemImage: "photo.on.rectangle"
                )
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(V25SecondaryButtonStyle())
            .disabled(!canSelectAttachments)
#if DEBUG
            Button(action: importFiles) {
                Label("从“文件”导入（开发门禁）", systemImage: "doc")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(V25SecondaryButtonStyle())
            .disabled(!canSelectAttachments)
#endif
            if unresolvedFailureCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "还有 \(unresolvedFailureCount) 个所选附件未导入。解决前不能保存这条记录。"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.vermilionText)
                    Button(
                        "确认不再使用未导入附件",
                        action: resolveImportFailures
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(V25SecondaryButtonStyle())
                }
                .accessibilityElement(children: .contain)
            }
            ForEach(attachments) { attachment in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.filename)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(attachment.data.count),
                            countStyle: .file
                        ))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Button("移除", role: .destructive) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.indigo.opacity(0.4)).frame(height: 1)
                }
            }
        }
    }

    private var canSelectAttachments: Bool {
        AttachmentSelectionCapacity.canSelect(
            existingCount: attachments.count,
            isImporting: isImporting
        )
    }

    private var attachmentSelectionLabel: String {
        if isImporting {
            return "正在导入照片"
        }
        if AttachmentSelectionCapacity.remainingSlots(
            existingCount: attachments.count
        ) == 0 {
            return "附件已满"
        }
        return "从照片中选择"
    }
}

private func canAppendAttachment(
    byteCount: Int64,
    to drafts: [AttachmentDraft]
) -> Bool {
    AttachmentOwnerCapacity.canAppend(
        byteCount: byteCount,
        to: drafts.map { Int64($0.data.count) }
    )
}

enum AttachmentImportGate {
    static func allowsSave(
        baseConditionsMet: Bool,
        isImporting: Bool,
        hasUnresolvedFailures: Bool
    ) -> Bool {
        baseConditionsMet && !isImporting && !hasUnresolvedFailures
    }
}

enum AttachmentSelectionCapacity {
    static func remainingSlots(existingCount: Int) -> Int {
        max(0, AttachmentFileStore.maximumOwnerFiles - existingCount)
    }

    static func pickerLimit(existingCount: Int) -> Int {
        max(1, remainingSlots(existingCount: existingCount))
    }

    static func canSelect(
        existingCount: Int,
        isImporting: Bool
    ) -> Bool {
        !isImporting && remainingSlots(existingCount: existingCount) > 0
    }

    static func rejectedSelectionCount(
        selectedCount: Int,
        existingCount: Int
    ) -> Int {
        max(0, selectedCount - remainingSlots(existingCount: existingCount))
    }
}

struct AttachmentImportBatchState {
    private(set) var activeID: UUID?
    private(set) var unresolvedFailureCount = 0
    private var activeSelectionCount = 0

    var isImporting: Bool {
        activeID != nil
    }

    var hasUnresolvedFailures: Bool {
        unresolvedFailureCount > 0
    }

    mutating func begin(selectedCount: Int = 0) -> UUID {
        if activeID != nil {
            unresolvedFailureCount += max(0, activeSelectionCount)
        }
        let id = UUID()
        activeID = id
        activeSelectionCount = max(0, selectedCount)
        return id
    }

    func isCurrent(_ id: UUID) -> Bool {
        activeID == id
    }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        activeSelectionCount = 0
        return true
    }

    mutating func recordFailures(_ count: Int) {
        unresolvedFailureCount += max(0, count)
    }

    mutating func resolveFailures() {
        unresolvedFailureCount = 0
    }
}

private func editorHeader(register: String, title: String) -> some View {
    StructuredEditorHeader(register: register, title: title)
}

private struct StructuredEditorHeader: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    let register: String
    let title: String

    var body: some View {
        HStack(alignment: .top) {
            Button("取消") { dismiss() }
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(register)
                    .font(theme.utility(9))
                    .tracking(0.7)
                Text(title)
                    .font(theme.display(28, relativeTo: .title2))
            }
        }
        .foregroundStyle(theme.indigo)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

private func labeledField(
    _ label: String,
    text: Binding<String>,
    prompt: String
) -> some View {
    LabeledEditorField(label: label, text: text, prompt: prompt)
}

private struct LabeledEditorField: View {
    @Environment(AppTheme.self) private var theme
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.indigo)
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityLabel(label)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(theme.paper)
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        }
    }
}
