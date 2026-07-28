import SwiftUI

struct ParentRecordDeletionAttachmentPresentation:
    Identifiable, Equatable
{
    let id: UUID
    let ordinal: Int
    let originalFilename: String
    let typeIdentifier: String
    let byteCount: Int64

    var fileTypeLabel: String {
        let pathExtension = URL(
            fileURLWithPath: originalFilename
        ).pathExtension
        if !pathExtension.isEmpty {
            return "文件类型："
                + pathExtension.uppercased()
        }
        return "文件类型：\(typeIdentifier)"
    }

    var formattedByteCount: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var accessibilityLabel: String {
        "附件 \(ordinal)，"
            + "\(originalFilename)，"
            + formattedByteCount
            + "，\(fileTypeLabel)"
    }
}

func parentRecordDeletionAttachmentPresentations(
    _ attachments: [AttachmentSnapshot]
) -> [ParentRecordDeletionAttachmentPresentation] {
    attachments.enumerated().map { index, attachment in
        ParentRecordDeletionAttachmentPresentation(
            id: attachment.id,
            ordinal: index + 1,
            originalFilename: attachment.originalFilename,
            typeIdentifier: attachment.typeIdentifier,
            byteCount: attachment.byteCount
        )
    }
}

struct CorrectionOptionalTextDraft: Equatable {
    private(set) var text: String
    private var preservesNilWhenEmpty: Bool

    init(_ value: String?) {
        text = value ?? ""
        preservesNilWhenEmpty = value == nil
    }

    var persistedValue: String? {
        preservesNilWhenEmpty && text.isEmpty ? nil : text
    }

    mutating func replaceWithUserInput(_ value: String) {
        text = value
        preservesNilWhenEmpty = false
    }
}

struct LabCorrectionResultDraft: Identifiable, Equatable {
    let id: UUID
    var itemDefinitionID: UUID
    var itemName: String
    var itemCode: String
    var value: String
    var unit: String
    var reference: CorrectionOptionalTextDraft
    var variant: CorrectionOptionalTextDraft

    init(_ result: LabResultSnapshot) {
        id = result.id
        itemDefinitionID = result.itemDefinitionID
        itemName = result.itemNameSnapshot
        itemCode = result.itemCodeSnapshot
        value = result.rawValueOriginal
        unit = result.unitOriginal
        reference = CorrectionOptionalTextDraft(
            result.referenceRangeOriginal
        )
        variant = CorrectionOptionalTextDraft(
            result.assayOrVariantOriginal
        )
    }

    init(definition: LabItemDefinitionSnapshot) {
        id = UUID()
        itemDefinitionID = definition.id
        itemName = definition.displayName
        itemCode = definition.code
        value = ""
        unit = ""
        reference = CorrectionOptionalTextDraft(nil)
        variant = CorrectionOptionalTextDraft(nil)
    }

    var isValid: Bool {
        !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (try? LabDecimalValue.parse(value)) != nil
    }

    var auditText: String {
        [
            itemName,
            "项目代码 " + displayValue(itemCode),
            "项目识别码 "
                + LabDefinitionIdentityPresentation.marker(
                    id: itemDefinitionID
                ),
            value + " " + unit,
            "参考区间 " + optionalAuditValue(reference.persistedValue),
            "检测方法 " + optionalAuditValue(variant.persistedValue)
        ].joined(separator: " · ")
    }
}

enum LabCorrectionResultMoveDirection {
    case up
    case down
}

func canMoveLabCorrectionResult(
    in results: [LabCorrectionResultDraft],
    id: UUID,
    direction: LabCorrectionResultMoveDirection
) -> Bool {
    guard let index = results.firstIndex(where: { $0.id == id }) else {
        return false
    }
    switch direction {
    case .up:
        return index > results.startIndex
    case .down:
        return index < results.index(before: results.endIndex)
    }
}

@discardableResult
func moveLabCorrectionResult(
    in results: inout [LabCorrectionResultDraft],
    id: UUID,
    direction: LabCorrectionResultMoveDirection
) -> Bool {
    guard canMoveLabCorrectionResult(
        in: results,
        id: id,
        direction: direction
    ),
    let index = results.firstIndex(where: { $0.id == id }) else {
        return false
    }
    let destination: Int
    switch direction {
    case .up:
        destination = results.index(before: index)
    case .down:
        destination = results.index(after: index)
    }
    results.swapAt(index, destination)
    return true
}

@MainActor
struct LabSampleCorrectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var reader
    @Environment(\.attachmentMutationService) private var mutationService
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @Environment(AppTheme.self) private var theme

    @State private var baseline: LabSampleSnapshot
    @State private var head: ParentRecordHeadToken
    @State private var occurredAt: Date
    @State private var specimen: String
    @State private var note: String
    @State private var results: [LabCorrectionResultDraft]
    @State private var definitions: [LabItemDefinitionSnapshot] = []
    @State private var isReviewing = false
    @State private var isSaving = false
    @State private var isReloading = false
    @State private var needsReload = false
    @State private var errorMessage: String?

    let attachmentCount: Int
    let onSaved: () -> Void

    init(
        snapshot: LabSampleSnapshot,
        head: ParentRecordHeadToken,
        attachmentCount: Int,
        onSaved: @escaping () -> Void
    ) {
        _baseline = State(initialValue: snapshot)
        _head = State(initialValue: head)
        _occurredAt = State(initialValue: snapshot.timestamp.instant)
        _specimen = State(initialValue: snapshot.specimenOriginal)
        _note = State(initialValue: snapshot.contextNote)
        _results = State(
            initialValue: snapshot.results.map(LabCorrectionResultDraft.init)
        )
        self.attachmentCount = attachmentCount
        self.onSaved = onSaved
    }

    private var canReview: Bool {
        !isSaving
            && !isReloading
            && results.allSatisfy(\.isValid)
            && (!results.isEmpty || attachmentCount > 0)
            && hasChanges
    }

    private var hasChanges: Bool {
        occurredAt != baseline.timestamp.instant
            || specimen != baseline.specimenOriginal
            || note != baseline.contextNote
            || results != baseline.results.map(LabCorrectionResultDraft.init)
    }

    private var changeSummary: [String] {
        var changes: [String] = []
        if occurredAt != baseline.timestamp.instant {
            changes.append("采样时间：\(dateText(baseline.timestamp.instant)) → \(dateText(occurredAt))")
        }
        if specimen != baseline.specimenOriginal {
            changes.append(
                "样本：\(displayValue(baseline.specimenOriginal)) → \(displayValue(specimen))"
            )
        }
        if note != baseline.contextNote {
            changes.append(
                "备注：\(displayValue(baseline.contextNote)) → \(displayValue(note))"
            )
        }
        let oldResults = baseline.results.map(LabCorrectionResultDraft.init)
        changes.append(
            contentsOf: labCorrectionResultChanges(
                baseline: oldResults,
                current: results
            )
        )
        return changes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    mutationHeader(
                        register: "CORRECTION / LAB",
                        title: isReviewing ? "核对更正" : "更正化验"
                    )
                    if isReviewing {
                        reviewContent
                    } else {
                        editContent
                    }
                    if let errorMessage {
                        mutationError(errorMessage)
                    }
                    if needsReload {
                        Button(
                            isReloading ? "正在重新载入…" : "保留草稿并重新载入当前版本"
                        ) {
                            reloadBaseline()
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .disabled(isReloading || isSaving)
                        .accessibilityIdentifier("labCorrection.reloadHead")
                    }
                    V25PrivacyFooter(
                        text: "更正会追加一个新版本；原始记录不会被覆盖。附件保持不变。"
                    )
                        .padding(.bottom, 86)
                }
                .padding(V25Theme.pagePadding)
                .frame(maxWidth: V25Theme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.rice.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if isReviewing {
                    HStack(spacing: 10) {
                        Button("返回修改") {
                            isReviewing = false
                            errorMessage = nil
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .disabled(isSaving)
                        Button(isSaving ? "正在保存…" : "确认追加更正") {
                            save()
                        }
                        .buttonStyle(V25PrimaryButtonStyle())
                        .disabled(isSaving || needsReload || !canReview)
                        .accessibilityIdentifier("labCorrection.confirm")
                    }
                    .padding(.horizontal, V25Theme.pagePadding)
                    .padding(.vertical, 10)
                    .background(theme.paper)
                } else {
                    V25SaveBar(
                        title: "查看更正内容",
                        isEnabled: canReview,
                        accessibilityIdentifier: "labCorrection.review"
                    ) {
                        errorMessage = nil
                        isReviewing = true
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task { await loadDefinitions() }
    }

    private var editContent: some View {
        Group {
            Text("先修改当前有效版本，再在下一步核对前后差异。原始录入会保留在本地审计链中。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            DatePicker(
                "采样时间",
                selection: $occurredAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            correctionField("样本类型（可选）", text: $specimen)
            correctionField("情境备注（可选）", text: $note)
            V25SectionHeader(
                title: "有效结果",
                detail: "\(results.count) 项"
            )
            ForEach($results) { $result in
                labResultEditor(result: $result)
            }
            Button {
                guard let definition =
                        definitions.first(where: { !$0.isArchived })
                        ?? definitions.first else {
                    errorMessage = "没有可用的化验项目，暂时不能新增结果。"
                    return
                }
                results.append(
                    LabCorrectionResultDraft(definition: definition)
                )
            } label: {
                Label("添加一个结果", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(V25SecondaryButtonStyle())
            if results.isEmpty {
                Text(
                    attachmentCount > 0
                        ? "这条化验将只保留 \(attachmentCount) 个附件。"
                        : "没有结果且没有附件时不能保存化验。"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    attachmentCount > 0
                        ? theme.secondaryText
                        : theme.vermilionText
                )
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请确认这些变化")
                .font(theme.display(24, relativeTo: .title2))
            Text("保存后会生成新的有效版本，旧版本不被改写。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            ForEach(Array(changeSummary.enumerated()), id: \.offset) {
                index,
                change in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%02d", index + 1))
                        .font(theme.utility(10))
                        .foregroundStyle(theme.vermilionText)
                    Text(change)
                        .font(.body)
                        .foregroundStyle(theme.indigoDeep)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.indigo.opacity(0.35))
                        .frame(height: 1)
                }
            }
        }
        .padding(15)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func labResultEditor(
        result: Binding<LabCorrectionResultDraft>
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 4) {
                Text("RESULT / 结果")
                    .font(theme.utility(9))
                    .foregroundStyle(theme.blueText)
                Spacer()
                Button {
                    moveResult(
                        id: result.wrappedValue.id,
                        direction: .up
                    )
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 44, height: 44)
                }
                .disabled(
                    !canMoveLabCorrectionResult(
                        in: results,
                        id: result.wrappedValue.id,
                        direction: .up
                    )
                )
                .accessibilityLabel(
                    "上移结果 "
                        + LabDefinitionIdentityPresentation.label(
                            id: result.wrappedValue.itemDefinitionID,
                            displayName: result.wrappedValue.itemName,
                            code: result.wrappedValue.itemCode
                        )
                )
                .accessibilityHint("调整更正后的结果顺序")
                .accessibilityIdentifier(
                    "labCorrection.result."
                        + result.wrappedValue.id.uuidString.lowercased()
                        + ".moveUp"
                )
                Button {
                    moveResult(
                        id: result.wrappedValue.id,
                        direction: .down
                    )
                } label: {
                    Image(systemName: "arrow.down")
                        .frame(width: 44, height: 44)
                }
                .disabled(
                    !canMoveLabCorrectionResult(
                        in: results,
                        id: result.wrappedValue.id,
                        direction: .down
                    )
                )
                .accessibilityLabel(
                    "下移结果 "
                        + LabDefinitionIdentityPresentation.label(
                            id: result.wrappedValue.itemDefinitionID,
                            displayName: result.wrappedValue.itemName,
                            code: result.wrappedValue.itemCode
                        )
                )
                .accessibilityHint("调整更正后的结果顺序")
                .accessibilityIdentifier(
                    "labCorrection.result."
                        + result.wrappedValue.id.uuidString.lowercased()
                        + ".moveDown"
                )
                Button("移除", role: .destructive) {
                    results.removeAll { $0.id == result.wrappedValue.id }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            if !definitions.isEmpty {
                Picker(
                    "化验项目",
                    selection: result.itemDefinitionID
                ) {
                    ForEach(definitions) { definition in
                        Text(
                            LabDefinitionIdentityPresentation.label(
                                id: definition.id,
                                displayName: definition.displayName,
                                code: definition.code
                            )
                        )
                        .tag(definition.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(
                    of: result.wrappedValue.itemDefinitionID
                ) { _, selectedID in
                    guard let definition = definitions.first(
                        where: { $0.id == selectedID }
                    ) else { return }
                    result.wrappedValue.itemName =
                        definition.displayName
                    result.wrappedValue.itemCode = definition.code
                }
            } else {
                Text(result.wrappedValue.itemName)
                    .font(.headline.weight(.black))
            }
            correctionField("结果", text: result.value)
                .keyboardType(.numbersAndPunctuation)
            correctionField("单位", text: result.unit)
            correctionField(
                "参考区间（可选）",
                text: referenceTextBinding(result: result)
            )
            correctionField(
                "检测方法 / 变体（可选）",
                text: variantTextBinding(result: result)
            )
            if !result.wrappedValue.value.isEmpty,
               (try? LabDecimalValue.parse(
                   result.wrappedValue.value
               )) == nil {
                Text("请输入有限十进制；可以带 <、≤、> 或 ≥。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.vermilionText)
            }
        }
        .padding(15)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func moveResult(
        id: UUID,
        direction: LabCorrectionResultMoveDirection
    ) {
        _ = moveLabCorrectionResult(
            in: &results,
            id: id,
            direction: direction
        )
        errorMessage = nil
    }

    private func save() {
        guard canReview, let mutationService else {
            errorMessage = "本地资料尚未准备好，或更正内容不完整。"
            return
        }
        let timestamp: HistoricalTimestamp
        do {
            timestamp = try correctionTimestamp(
                baseline: baseline.timestamp,
                selectedInstant: occurredAt
            )
        } catch {
            errorMessage = "采样时间无法保存，请重新选择。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await mutationService.correctLabSample(
                    CorrectLabSampleCommand(
                        parentID: baseline.id,
                        expectedHead: head,
                        timestamp: timestamp,
                        specimenOriginal: specimen,
                        contextNote: note,
                        results: results.map {
                            CorrectedLabResultInput(
                                logicalResultID: $0.id,
                                itemDefinitionID:
                                    $0.itemDefinitionID,
                                rawValueOriginal: $0.value,
                                unitOriginal: $0.unit,
                                referenceRangeOriginal:
                                    $0.reference.persistedValue,
                                assayOrVariantOriginal:
                                    $0.variant.persistedValue
                            )
                        }
                    )
                )
                onSaved()
                dismiss()
            } catch {
                applyMutationError(error)
            }
        }
    }

    private func reloadBaseline() {
        guard let reader else { return }
        isReloading = true
        Task {
            defer { isReloading = false }
            do {
                guard let latest = try await reader.labSample(
                    id: baseline.id
                ),
                let latestHead = try await reader.parentRecordHeadToken(
                    type: .labSample,
                    id: baseline.id
                ) else {
                    errorMessage = "这条记录已被删除，草稿没有被提交。"
                    return
                }
                baseline = latest
                head = latestHead
                needsReload = false
                errorMessage =
                    "已载入当前版本；你的草稿仍在，请重新核对差异。"
            } catch {
                applyMutationError(error)
            }
        }
    }

    private func applyMutationError(_ error: Error) {
        if error as? ParentRecordMutationFailure == .staleHead {
            needsReload = true
            errorMessage =
                "这条记录在别处发生了变化。草稿仍保留；请重新载入当前版本后再次核对。"
        } else if error as? ParentRecordMutationFailure
                    == .noEffectiveChange {
            errorMessage = "当前内容没有产生新的有效变化。"
        } else if error as? ParentRecordMutationFailure
                    == .alreadyDeleted {
            errorMessage = "这条记录已经删除，草稿没有被提交。"
        } else if error as? ParentRecordMutationFailure
                    == .correctionLimitReached {
            errorMessage =
                "这条记录的更正历史已达到当前版本上限。原记录和草稿都没有改变。"
        } else if error as? AttachmentMutationFailure
                    == .previewInProgress {
            errorMessage = "请先关闭附件预览，再保存更正。"
        } else if error as? AttachmentMutationFailure
                    == .recoveryRequired
            || error as? AppDataFailure == .corruptionSuspected {
            errorMessage =
                "本地资料没有通过完整性检查。App 将进入恢复模式。"
            integrityFailureHandler?()
        } else {
            errorMessage = "更正没有保存；草稿仍在当前页面。"
        }
    }

    private func loadDefinitions() async {
        guard let reader else { return }
        do {
            definitions = try await reader.labItemDefinitions()
        } catch {
            applyMutationError(error)
        }
    }
}

@MainActor
struct StatusObservationCorrectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var reader
    @Environment(\.attachmentMutationService) private var mutationService
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @Environment(AppTheme.self) private var theme

    @State private var baseline: StatusObservationSnapshot
    @State private var head: ParentRecordHeadToken
    @State private var metricID: UUID
    @State private var level: Int
    @State private var note: String
    @State private var occurredAt: Date
    @State private var metrics: [StatusMetricSnapshot] = []
    @State private var isReviewing = false
    @State private var isSaving = false
    @State private var isReloading = false
    @State private var needsReload = false
    @State private var errorMessage: String?

    let onSaved: () -> Void

    init(
        snapshot: StatusObservationSnapshot,
        head: ParentRecordHeadToken,
        onSaved: @escaping () -> Void
    ) {
        _baseline = State(initialValue: snapshot)
        _head = State(initialValue: head)
        _metricID = State(initialValue: snapshot.metricDefinitionID)
        _level = State(initialValue: snapshot.ordinalLevel)
        _note = State(initialValue: snapshot.note)
        _occurredAt = State(initialValue: snapshot.timestamp.instant)
        self.onSaved = onSaved
    }

    private var hasChanges: Bool {
        metricID != baseline.metricDefinitionID
            || level != baseline.ordinalLevel
            || note != baseline.note
            || occurredAt != baseline.timestamp.instant
    }

    private var changeSummary: [String] {
        var changes: [String] = []
        if metricID != baseline.metricDefinitionID {
            changes.append(
                "指标：\(baseline.metricNameSnapshot) → \(metricName(metricID))"
            )
        }
        if level != baseline.ordinalLevel {
            changes.append(
                "级别：第 \(baseline.ordinalLevel) 级 → 第 \(level) 级"
            )
        }
        if note != baseline.note {
            changes.append(
                "备注：\(displayValue(baseline.note)) → \(displayValue(note))"
            )
        }
        if occurredAt != baseline.timestamp.instant {
            changes.append(
                "记录时间：\(dateText(baseline.timestamp.instant)) → \(dateText(occurredAt))"
            )
        }
        return changes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    mutationHeader(
                        register: "CORRECTION / STATUS",
                        title: isReviewing ? "核对更正" : "更正状态"
                    )
                    if isReviewing {
                        reviewContent
                    } else {
                        editContent
                    }
                    if let errorMessage {
                        mutationError(errorMessage)
                    }
                    if needsReload {
                        Button(
                            isReloading ? "正在重新载入…" : "保留草稿并重新载入当前版本"
                        ) {
                            reloadBaseline()
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .disabled(isReloading || isSaving)
                        .accessibilityIdentifier(
                            "statusCorrection.reloadHead"
                        )
                    }
                    V25PrivacyFooter(
                        text: "更正会追加一个新版本；原始记录不会被覆盖。附件保持不变。"
                    )
                        .padding(.bottom, 86)
                }
                .padding(V25Theme.pagePadding)
                .frame(maxWidth: V25Theme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.rice.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if isReviewing {
                    HStack(spacing: 10) {
                        Button("返回修改") {
                            isReviewing = false
                            errorMessage = nil
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .disabled(isSaving)
                        Button(isSaving ? "正在保存…" : "确认追加更正") {
                            save()
                        }
                        .buttonStyle(V25PrimaryButtonStyle())
                        .disabled(
                            isSaving || needsReload || !hasChanges
                        )
                        .accessibilityIdentifier(
                            "statusCorrection.confirm"
                        )
                    }
                    .padding(.horizontal, V25Theme.pagePadding)
                    .padding(.vertical, 10)
                    .background(theme.paper)
                } else {
                    V25SaveBar(
                        title: "查看更正内容",
                        isEnabled: hasChanges && !isReloading,
                        accessibilityIdentifier:
                            "statusCorrection.review"
                    ) {
                        errorMessage = nil
                        isReviewing = true
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task { await loadMetrics() }
    }

    private var editContent: some View {
        Group {
            Text("先修改当前有效版本，再在下一步核对前后差异。原始录入会保留在本地审计链中。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Picker("指标", selection: $metricID) {
                if metrics.isEmpty {
                    Text(baseline.metricNameSnapshot)
                        .tag(baseline.metricDefinitionID)
                } else {
                    ForEach(metrics) { metric in
                        Text(metric.displayName).tag(metric.id)
                    }
                }
            }
            .pickerStyle(.menu)
            V25SectionHeader(
                title: "级别",
                detail: "第 \(level) 级，共 4 级"
            )
            HStack(spacing: 8) {
                ForEach(1...4, id: \.self) { value in
                    Button {
                        level = value
                    } label: {
                        Text("\(value)")
                            .font(.headline.weight(.black))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(
                                level == value
                                    ? theme.paper
                                    : theme.indigo
                            )
                            .background(
                                level == value
                                    ? theme.indigo
                                    : theme.paper
                            )
                            .overlay {
                                Rectangle().stroke(
                                    theme.indigo,
                                    lineWidth: level == value ? 3 : 1.5
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(value) 级，共 4 级")
                    .accessibilityAddTraits(
                        level == value ? .isSelected : []
                    )
                }
            }
            correctionField("备注（可选）", text: $note)
            DatePicker(
                "记录时间",
                selection: $occurredAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请确认这些变化")
                .font(theme.display(24, relativeTo: .title2))
            Text("保存后会生成新的有效版本，旧版本不被改写。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            ForEach(Array(changeSummary.enumerated()), id: \.offset) {
                index,
                change in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%02d", index + 1))
                        .font(theme.utility(10))
                        .foregroundStyle(theme.vermilionText)
                    Text(change)
                        .font(.body)
                        .foregroundStyle(theme.indigoDeep)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.indigo.opacity(0.35))
                        .frame(height: 1)
                }
            }
        }
        .padding(15)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }

    private func save() {
        guard hasChanges, let mutationService else {
            errorMessage = "本地资料尚未准备好，或没有可保存的变化。"
            return
        }
        let timestamp: HistoricalTimestamp
        do {
            timestamp = try correctionTimestamp(
                baseline: baseline.timestamp,
                selectedInstant: occurredAt
            )
        } catch {
            errorMessage = "记录时间无法保存，请重新选择。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await mutationService
                    .correctStatusObservation(
                        CorrectStatusObservationCommand(
                            parentID: baseline.id,
                            expectedHead: head,
                            metricDefinitionID: metricID,
                            ordinalLevel: level,
                            note: note,
                            timestamp: timestamp
                        )
                    )
                onSaved()
                dismiss()
            } catch {
                applyMutationError(error)
            }
        }
    }

    private func reloadBaseline() {
        guard let reader else { return }
        isReloading = true
        Task {
            defer { isReloading = false }
            do {
                guard let latest = try await reader.statusObservation(
                    id: baseline.id
                ),
                let latestHead = try await reader.parentRecordHeadToken(
                    type: .statusObservation,
                    id: baseline.id
                ) else {
                    errorMessage = "这条记录已被删除，草稿没有被提交。"
                    return
                }
                baseline = latest
                head = latestHead
                needsReload = false
                errorMessage =
                    "已载入当前版本；你的草稿仍在，请重新核对差异。"
            } catch {
                applyMutationError(error)
            }
        }
    }

    private func loadMetrics() async {
        guard let reader else { return }
        do {
            metrics = try await reader.statusMetrics()
            if !metrics.contains(where: { $0.id == metricID }) {
                metrics.append(
                    StatusMetricSnapshot(
                        id: baseline.metricDefinitionID,
                        displayName: baseline.metricNameSnapshot,
                        isArchived: true
                    )
                )
            }
        } catch {
            applyMutationError(error)
        }
    }

    private func metricName(_ id: UUID) -> String {
        metrics.first(where: { $0.id == id })?.displayName
            ?? baseline.metricNameSnapshot
    }

    private func applyMutationError(_ error: Error) {
        if error as? ParentRecordMutationFailure == .staleHead {
            needsReload = true
            errorMessage =
                "这条记录在别处发生了变化。草稿仍保留；请重新载入当前版本后再次核对。"
        } else if error as? ParentRecordMutationFailure
                    == .noEffectiveChange {
            errorMessage = "当前内容没有产生新的有效变化。"
        } else if error as? ParentRecordMutationFailure
                    == .alreadyDeleted {
            errorMessage = "这条记录已经删除，草稿没有被提交。"
        } else if error as? ParentRecordMutationFailure
                    == .correctionLimitReached {
            errorMessage =
                "这条记录的更正历史已达到当前版本上限。原记录和草稿都没有改变。"
        } else if error as? AttachmentMutationFailure
                    == .previewInProgress {
            errorMessage = "请先关闭附件预览，再保存更正。"
        } else if error as? AttachmentMutationFailure
                    == .recoveryRequired
            || error as? AppDataFailure == .corruptionSuspected {
            errorMessage =
                "本地资料没有通过完整性检查。App 将进入恢复模式。"
            integrityFailureHandler?()
        } else {
            errorMessage = "更正没有保存；草稿仍在当前页面。"
        }
    }
}

@MainActor
struct ParentRecordDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var reader
    @Environment(\.attachmentMutationService) private var mutationService
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @Environment(AppTheme.self) private var theme

    @State private var impact: ParentRecordDeletionImpact
    @State private var isDeleting = false
    @State private var isReloading = false
    @State private var needsReload = false
    @State private var errorMessage: String?

    let onDeleted: () -> Void

    init(
        impact: ParentRecordDeletionImpact,
        onDeleted: @escaping () -> Void
    ) {
        _impact = State(initialValue: impact)
        self.onDeleted = onDeleted
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    mutationHeader(
                        register: "DELETE / IMPACT",
                        title: "删除记录"
                    )
                    Text("请先核对这次删除会影响什么。删除是终止操作，之后不能在 App 中恢复这条记录。")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                    VStack(alignment: .leading, spacing: 12) {
                        impactRow(
                            "记录类型",
                            impact.parentType == .labSample
                                ? "化验"
                                : "状态"
                        )
                        if impact.parentType == .labSample {
                            impactRow(
                                "当前有效结果",
                                "\(impact.effectiveResultCount) 项"
                            )
                        }
                        impactRow(
                            "既有更正",
                            "\(impact.correctionCount) 次"
                        )
                        impactRow(
                            "随记录删除的附件",
                            "\(impact.attachments.count) 个"
                        )
                        impactRow(
                            "附件大小",
                            ByteCountFormatter.string(
                                fromByteCount:
                                    impact.attachmentByteCount,
                                countStyle: .file
                            )
                        )
                    }
                    .padding(15)
                    .background(theme.paper)
                    .overlay {
                        Rectangle().stroke(
                            theme.vermilion,
                            lineWidth: 1.5
                        )
                    }
                    if !impact.attachments.isEmpty {
                        deletionAttachmentLedger
                    }
                    Text(
                        "这会从正常视图移除当前记录，并删除 App 当前管理的附件文件。它不是取证级擦除：系统备份、存储介质快照或先前导出的副本可能仍然存在。"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.vermilionText)
                    if let errorMessage {
                        mutationError(errorMessage)
                    }
                    if needsReload {
                        Button(
                            isReloading ? "正在重新计算…" : "重新计算删除影响"
                        ) {
                            reloadImpact()
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .disabled(isReloading || isDeleting)
                        .accessibilityIdentifier(
                            "parentDelete.reloadImpact"
                        )
                    }
                    V25PrivacyFooter(text: SystemBackupDisclosure.compact)
                        .padding(.bottom, 86)
                }
                .padding(V25Theme.pagePadding)
                .frame(maxWidth: V25Theme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(theme.rice.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button("取消") { dismiss() }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .disabled(isDeleting)
                    Button(
                        isDeleting ? "正在删除…" : "确认删除",
                        role: .destructive
                    ) {
                        delete()
                    }
                    .buttonStyle(V25PrimaryButtonStyle())
                    .disabled(isDeleting || isReloading || needsReload)
                    .accessibilityIdentifier("parentDelete.confirm")
                }
                .padding(.horizontal, V25Theme.pagePadding)
                .padding(.vertical, 10)
                .background(theme.paper)
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func impactRow(
        _ label: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.headline.weight(.black))
                .foregroundStyle(theme.indigoDeep)
        }
        .accessibilityElement(children: .combine)
    }

    private var deletionAttachmentLedger: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("将删除的附件")
                .font(theme.display(22, relativeTo: .title3))
                .padding(.bottom, 6)
            Text("请逐项核对文件名；相同名称会以附件序号区分。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            ForEach(
                parentRecordDeletionAttachmentPresentations(
                    impact.attachments
                )
            ) { attachment in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            String(
                                format:
                                    "附件 %02d",
                                attachment.ordinal
                            )
                        )
                        .font(theme.utility(10))
                        .foregroundStyle(theme.vermilionText)
                        Spacer(minLength: 10)
                        Text(
                            attachment.formattedByteCount
                        )
                        .font(theme.utility(10))
                        .foregroundStyle(theme.secondaryText)
                    }
                    Text(attachment.originalFilename)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.indigoDeep)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                    Text(attachment.fileTypeLabel)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.indigo.opacity(0.35))
                        .frame(height: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(attachment.accessibilityLabel)
                .accessibilityIdentifier(
                    "parentDelete.attachment."
                        + attachment.id.uuidString.lowercased()
                )
            }
        }
        .padding(15)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 1.5)
        }
        .accessibilityIdentifier(
            "parentDelete.attachmentLedger"
        )
    }

    private func delete() {
        guard let mutationService else {
            errorMessage = "本地资料尚未准备好。"
            return
        }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                _ = try await mutationService.deleteParentRecord(
                    impact: impact
                )
                onDeleted()
                dismiss()
            } catch {
                if error as? ParentRecordMutationFailure == .staleHead
                    || error as? ParentRecordMutationFailure
                        == .impactChanged {
                    needsReload = true
                    errorMessage =
                        "记录或附件已发生变化，删除没有执行。请重新核对影响范围。"
                } else if error as? AttachmentMutationFailure
                            == .previewInProgress {
                    errorMessage = "请先关闭附件预览，再删除记录。"
                } else if error as? AttachmentMutationFailure
                            == .recoveryRequired
                    || error as? AppDataFailure
                        == .corruptionSuspected {
                    errorMessage =
                        "删除没有完成安全收尾。App 将进入恢复模式。"
                    integrityFailureHandler?()
                } else {
                    errorMessage = "记录没有删除，请稍后重试。"
                }
            }
        }
    }

    private func reloadImpact() {
        guard let reader else { return }
        isReloading = true
        Task {
            defer { isReloading = false }
            do {
                impact = try await reader.parentRecordDeletionImpact(
                    type: impact.parentType,
                    id: impact.parentID
                )
                needsReload = false
                errorMessage = "影响范围已更新，请再次核对。"
            } catch {
                if error as? AppDataFailure == .corruptionSuspected {
                    errorMessage =
                        "本地资料没有通过完整性检查。App 将进入恢复模式。"
                    integrityFailureHandler?()
                } else {
                    errorMessage = "暂时无法重新计算删除影响。"
                }
            }
        }
    }
}

@MainActor
private func mutationHeader(
    register: String,
    title: String
) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(register)
            .font(.caption.weight(.black))
            .tracking(1.1)
        Text(title)
            .font(.system(.largeTitle, design: .serif).weight(.black))
    }
}

@MainActor
private func correctionField(
    _ label: String,
    text: Binding<String>
) -> some View {
    CorrectionField(label: label, text: text)
}

@MainActor
private func mutationError(_ message: String) -> some View {
    MutationError(message: message)
}

@MainActor
private struct CorrectionField: View {
    @Environment(AppTheme.self) private var theme

    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.black))
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .frame(minHeight: 48)
                .background(theme.paper)
                .overlay {
                    Rectangle().stroke(
                        theme.indigo.opacity(0.65),
                        lineWidth: 1.5
                    )
                }
                .accessibilityLabel(label)
        }
    }
}

@MainActor
private struct MutationError: View {
    @Environment(AppTheme.self) private var theme

    let message: String

    var body: some View {
        Text(message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.vermilionText)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.paper)
            .overlay {
                Rectangle().stroke(
                    theme.vermilion,
                    lineWidth: 1.5
                )
            }
    }
}

private func displayValue(_ value: String) -> String {
    value.isEmpty ? "（空）" : value
}

private func optionalAuditValue(_ value: String?) -> String {
    guard let value else { return "未提供" }
    return value.isEmpty ? "（空）" : value
}

func labCorrectionResultChanges(
    baseline: [LabCorrectionResultDraft],
    current: [LabCorrectionResultDraft]
) -> [String] {
    guard baseline != current else { return [] }
    var changes: [String] = []
    if baseline.count != current.count {
        changes.append(
            "化验结果：\(baseline.count) 项 → \(current.count) 项"
        )
    }
    for old in baseline
    where !current.contains(where: { $0.id == old.id }) {
        changes.append("移除结果：\(old.auditText)")
    }
    for (index, result) in current.enumerated() {
        let old = baseline.first { $0.id == result.id }
        if let old, old != result {
            changes.append(
                "结果 \(index + 1)：\(old.auditText) → \(result.auditText)"
            )
        } else if old == nil {
            changes.append("新增结果：\(result.auditText)")
        }
    }
    let oldSharedOrder = baseline
        .filter { old in current.contains(where: { $0.id == old.id }) }
        .map(\.id)
    let newSharedOrder = current
        .filter { result in
            baseline.contains(where: { $0.id == result.id })
        }
        .map(\.id)
    if oldSharedOrder != newSharedOrder {
        let oldNames = baseline
            .filter { oldSharedOrder.contains($0.id) }
            .map {
                LabDefinitionIdentityPresentation.label(
                    id: $0.itemDefinitionID,
                    displayName: $0.itemName,
                    code: $0.itemCode
                )
            }
            .joined(separator: "、")
        let newNames = current
            .filter { newSharedOrder.contains($0.id) }
            .map {
                LabDefinitionIdentityPresentation.label(
                    id: $0.itemDefinitionID,
                    displayName: $0.itemName,
                    code: $0.itemCode
                )
            }
            .joined(separator: "、")
        changes.append("结果顺序：\(oldNames) → \(newNames)")
    }
    return changes
}

private func referenceTextBinding(
    result: Binding<LabCorrectionResultDraft>
) -> Binding<String> {
    Binding(
        get: { result.wrappedValue.reference.text },
        set: { value in
            result.wrappedValue.reference.replaceWithUserInput(value)
        }
    )
}

private func variantTextBinding(
    result: Binding<LabCorrectionResultDraft>
) -> Binding<String> {
    Binding(
        get: { result.wrappedValue.variant.text },
        set: { value in
            result.wrappedValue.variant.replaceWithUserInput(value)
        }
    )
}

func correctionTimestamp(
    baseline: HistoricalTimestamp,
    selectedInstant: Date
) throws -> HistoricalTimestamp {
    if selectedInstant == baseline.instant {
        return baseline
    }
    return try HistoricalTimestamp.captured(
        instant: selectedInstant,
        timeZoneIdentifier: baseline.timeZoneIdentifier,
        precision: .minute,
        provenance: .userEntered
    )
}

private func dateText(_ date: Date) -> String {
    date.formatted(
        date: .abbreviated,
        time: .shortened
    )
}
