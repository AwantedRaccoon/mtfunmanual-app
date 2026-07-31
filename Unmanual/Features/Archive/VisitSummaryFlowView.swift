import SwiftUI
#if DEBUG
import UniformTypeIdentifiers
#endif

@MainActor
struct VisitSummaryFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var reader
    @Environment(AppTheme.self) private var theme

    @State private var preset: VisitSummaryRangePreset = .ninetyDays
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var subjectName = ""
    @State private var privacy = VisitSummaryPrivacySelection()
    @State private var content = VisitSummaryContentSelection()
    @State private var snapshot: VisitSummarySnapshot?
    @State private var frozenConfiguration:
        VisitSummaryConfiguration?
    @State private var isBuilding = false
    @State private var errorMessage: String?
    @State private var workTask: Task<Void, Never>?
    @State private var workRequestID: UUID?
    @State private var isActive = false
#if DEBUG
    @State private var exportDocument: VisitSummaryExportDocument?
    @State private var exportType: VisitSummaryExportType = .pdf
    @State private var isExporting = false
    @State private var exportMessage: String?
#endif

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "REPORT / VISIT",
                eyebrow: snapshot == nil ? "选择与预览" : "冻结预览",
                title: "就诊摘要",
                detail: snapshot == nil
                    ? "选择范围和包含内容；生成前不会保存真实报告副本。"
                    : "下面的内容来自同一份冻结快照。修改选择后需要重新生成。",
                cancel: cancelAndDismiss
            ) {
                if let snapshot {
                    preview(snapshot)
                } else {
                    configurationForm
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilionText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "archive.visitSummary.error"
                        )
                }
#if DEBUG
                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.mossText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "archive.visitSummary.exportStatus"
                        )
                }
#endif
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
            }
        }
        .tint(theme.indigo)
        .onAppear {
            isActive = true
            setPreset(.ninetyDays)
        }
        .onDisappear {
            isActive = false
            cancelOutstandingWork()
#if DEBUG
            exportDocument = nil
            isExporting = false
#endif
        }
#if DEBUG
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportType.contentType,
            defaultFilename: exportType.defaultFilename
        ) { result in
            guard isActive else { return }
            switch result {
            case .success:
                exportMessage =
                    "文件已交给所选位置；离开 App 后不再受 App Lock 保护。"
            case .failure:
                exportMessage =
                    "没有生成文件；冻结预览仍保留，可以稍后重试。"
            }
            exportDocument = nil
        }
#endif
    }

    private var configurationForm: some View {
        Group {
            V25SectionHeader(title: "时间范围", detail: "最多十年")
            VStack(spacing: 0) {
                ForEach(VisitSummaryRangePreset.allCases) { option in
                    Button {
                        setPreset(option)
                    } label: {
                        HStack(spacing: 12) {
                            Text(option.title)
                                .font(.body.weight(.black))
                            Spacer()
                            if preset == option {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.black))
                            }
                        }
                        .foregroundStyle(theme.indigoDeep)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                        .background(
                            preset == option
                                ? theme.mustard.opacity(0.22)
                                : theme.paper
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(theme.indigo)
                                .frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "archive.visitSummary.range.\(option.rawValue)"
                    )
                }
            }
            .overlay {
                Rectangle().stroke(theme.indigo, lineWidth: 1.5)
            }

            if preset == .custom {
                V25FieldSurface(
                    "自定义日期",
                    note: "包括开始日和结束日。"
                ) {
                    DatePicker(
                        "开始日期",
                        selection: startDateBinding,
                        displayedComponents: .date
                    )
                    .frame(minHeight: 44)
                    DatePicker(
                        "结束日期",
                        selection: endDateBinding,
                        displayedComponents: .date
                    )
                    .frame(minHeight: 44)
                }
            }

            ContextualContentScenarioEntry(
                scenario: .visitPreparation
            )

            V25SectionHeader(title: "包含内容", detail: "逐项决定")
            VisitSummaryToggleLedger {
                toggle(
                    "具体方案",
                    detail: "方案版本、项目、原始用量与日程摘要",
                    isOn: binding(\.includeRegimen, in: $privacy)
                )
                toggle(
                    "执行记录",
                    detail: "已执行、跳过与实际记录时间",
                    isOn: binding(\.includeExecution, in: $content)
                )
                toggle(
                    "化验",
                    detail: "原始结果、单位和报告参考范围",
                    isOn: binding(\.includeLabs, in: $privacy)
                )
                toggle(
                    "状态",
                    detail: "用户选择的状态等级",
                    isOn: binding(\.includeStatus, in: $content)
                )
                toggle(
                    "变化与事件",
                    detail: "旅程中的变化、感受和重要时刻",
                    isOn: binding(\.includeEvents, in: $content)
                )
                toggle(
                    "想问的问题",
                    detail: "当前记录没有“已解决”状态，因此展示范围内全部问题",
                    isOn: binding(\.includeQuestions, in: $content)
                )
            }

            V25SectionHeader(title: "隐私开关", detail: "默认克制")
            VisitSummaryToggleLedger {
                toggle(
                    "姓名",
                    detail: "默认不包含；姓名只用于这次预览",
                    isOn: binding(\.includeName, in: $privacy)
                )
                if privacy.includeName {
                    TextField(
                        "姓名",
                        text: subjectNameBinding
                    )
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .background(theme.paper)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.indigo).frame(height: 1)
                    }
                    .accessibilityLabel("摘要中的姓名")
                }
                toggle(
                    "生成日期",
                    detail: "关闭后仍保留记录范围",
                    isOn: binding(\.includeGeneratedDate, in: $privacy)
                )
                toggle(
                    "照片数量",
                    detail: "默认关闭；只披露图片附件数量，不嵌入照片",
                    isOn: binding(\.includePhotos, in: $privacy)
                )
                toggle(
                    "敏感笔记",
                    detail: "默认关闭；包括方案变更、执行、采样和状态备注",
                    isOn: binding(\.includeSensitiveNotes, in: $privacy)
                )
            }

            V25PrivacyFooter(
                text: VisitSummarySnapshot.disclaimer
                    + " 生成前会先显示完整预览。"
            )
        }
    }

    @ViewBuilder
    private func preview(_ snapshot: VisitSummarySnapshot) -> some View {
        let projection = VisitSummaryDisclosureProjection(
            snapshot: snapshot
        )
        VisitSummaryPreviewHeader(snapshot: snapshot)
        summarySection(
            "报告信息",
            rows: projection.metadataRows
        )
        if snapshot.isEmpty {
            V25FieldSurface(
                "这个范围内没有所选记录",
                note: "返回修改范围或内容开关。"
            ) {
                Text("不会生成看似完整的空报告。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        } else {
            ForEach(
                Array(projection.sections.enumerated()),
                id: \.offset
            ) { _, section in
                summarySection(
                    section.title,
                    rows: section.rows
                )
            }
        }
        V25FieldSurface(
            "报告边界",
            note: VisitSummarySnapshot.disclaimer
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("快照校验：\(snapshot.stateDigest.prefix(12))")
                    .font(theme.utility(10))
                    .tracking(0.5)
                Text("离开 App 后，文件不再受 App Lock 保护。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ title: String, rows: [String]) -> some View {
        if !rows.isEmpty {
            V25SectionHeader(
                title: title,
                detail: "\(rows.count) 项"
            )
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) {
                    index, row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(format: "%02d", index + 1))
                            .font(theme.utility(10))
                            .foregroundStyle(theme.blueText)
                            .frame(width: 28, alignment: .leading)
                        Text(row)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.paper)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.indigo).frame(height: 1)
                    }
                }
            }
            .overlay {
                Rectangle().stroke(theme.indigo, lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if isBuilding {
            V25SaveBar(
                title: "正在生成完整预览",
                isEnabled: false,
                accessibilityIdentifier:
                    "archive.visitSummary.building",
                action: {}
            )
        } else if let snapshot {
            VStack(spacing: 0) {
#if DEBUG
                if !snapshot.isEmpty {
                    HStack(spacing: 10) {
                        Button("导出 PDF") {
                            export(snapshot, type: .pdf)
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(
                            "archive.visitSummary.exportPDF"
                        )
                        Button("导出 CSV") {
                            export(snapshot, type: .csvPackage)
                        }
                        .buttonStyle(V25SecondaryButtonStyle())
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(
                            "archive.visitSummary.exportCSV"
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .background(theme.rice)
                }
#endif
                V25SaveBar(
                    title: "修改选择",
                    isEnabled: true,
                    accessibilityIdentifier:
                        "archive.visitSummary.modify",
                    action: {
                        self.snapshot = nil
                        frozenConfiguration = nil
                        errorMessage = nil
                    }
                )
            }
        } else {
            V25SaveBar(
                title: "生成完整预览",
                isEnabled: true,
                accessibilityIdentifier:
                    "archive.visitSummary.build",
                action: buildPreview
            )
        }
    }

    private func buildPreview() {
        guard !isBuilding, let reader else {
            errorMessage = "本地资料尚未准备好。"
            return
        }
        cancelOutstandingWork()
        let requestID = UUID()
        workRequestID = requestID
        isBuilding = true
        errorMessage = nil
        let configuration = resolvedConfiguration
        workTask = Task {
            defer {
                if workRequestID == requestID {
                    workRequestID = nil
                    workTask = nil
                    isBuilding = false
                }
            }
            do {
                let value = try await reader.visitSummarySnapshot(
                    configuration: configuration
                )
                guard !Task.isCancelled,
                      isActive,
                      workRequestID == requestID,
                      resolvedConfiguration == configuration else {
                    return
                }
                snapshot = value
                frozenConfiguration = configuration
            } catch let error as VisitSummaryFailure {
                guard !Task.isCancelled,
                      isActive,
                      workRequestID == requestID else {
                    return
                }
                snapshot = nil
                frozenConfiguration = nil
                errorMessage = error.localizedDescription
            } catch {
                guard !Task.isCancelled,
                      isActive,
                      workRequestID == requestID else {
                    return
                }
                snapshot = nil
                frozenConfiguration = nil
                errorMessage = "摘要没有通过完整性检查；没有生成文件。"
            }
        }
    }

    private var resolvedConfiguration: VisitSummaryConfiguration {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let start = calendar.startOfDay(for: startDate)
        let endStart = calendar.startOfDay(for: endDate)
        let end = calendar.date(
            byAdding: DateComponents(day: 1, nanosecond: -1),
            to: endStart
        ) ?? endDate
        return VisitSummaryConfiguration(
            preset: preset,
            start: start,
            end: end,
            subjectName: subjectName,
            privacy: privacy,
            content: content
        )
    }

    private func setPreset(_ value: VisitSummaryRangePreset) {
        cancelOutstandingWork()
        preset = value
        invalidatePreview()
        guard let days = value.dayCount else { return }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        endDate = now
        startDate = calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: now
        ) ?? now
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<VisitSummaryPrivacySelection, Value>,
        in source: Binding<VisitSummaryPrivacySelection>
    ) -> Binding<Value> {
        Binding(
            get: { source.wrappedValue[keyPath: keyPath] },
            set: {
                source.wrappedValue[keyPath: keyPath] = $0
                invalidatePreview()
            }
        )
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<VisitSummaryContentSelection, Value>,
        in source: Binding<VisitSummaryContentSelection>
    ) -> Binding<Value> {
        Binding(
            get: { source.wrappedValue[keyPath: keyPath] },
            set: {
                source.wrappedValue[keyPath: keyPath] = $0
                invalidatePreview()
            }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { startDate },
            set: {
                startDate = $0
                invalidatePreview()
            }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { endDate },
            set: {
                endDate = $0
                invalidatePreview()
            }
        )
    }

    private var subjectNameBinding: Binding<String> {
        Binding(
            get: { subjectName },
            set: {
                subjectName = $0
                invalidatePreview()
            }
        )
    }

    private func invalidatePreview() {
        cancelOutstandingWork()
        snapshot = nil
        frozenConfiguration = nil
        errorMessage = nil
    }

    private func cancelOutstandingWork() {
        workRequestID = nil
        workTask?.cancel()
        workTask = nil
        isBuilding = false
    }

    private func cancelAndDismiss() {
        cancelOutstandingWork()
        dismiss()
    }

    private func toggle(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.black))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(theme.mustard)
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .background(theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

#if DEBUG
    private func export(
        _ snapshot: VisitSummarySnapshot,
        type: VisitSummaryExportType
    ) {
        guard !isBuilding,
              !snapshot.isEmpty,
              let reader,
              let configuration = frozenConfiguration else {
            exportMessage =
                "冻结预览已经失效；请返回修改并重新生成。"
            return
        }
        cancelOutstandingWork()
        let requestID = UUID()
        workRequestID = requestID
        isBuilding = true
        exportMessage = nil
        workTask = Task {
            defer {
                if workRequestID == requestID {
                    workRequestID = nil
                    workTask = nil
                    isBuilding = false
                }
            }
            do {
                let document: VisitSummaryExportDocument
                exportType = type
                switch type {
                case .pdf:
                    document = VisitSummaryExportDocument(
                        data: try await reader
                            .confirmedVisitSummaryPDF(
                                frozen: snapshot,
                                configuration: configuration
                            )
                    )
                case .csvPackage:
                    document = VisitSummaryExportDocument(
                        files: try await reader
                            .confirmedVisitSummaryCSVPackage(
                                frozen: snapshot,
                                configuration: configuration
                            )
                    )
                }
                guard !Task.isCancelled,
                      isActive,
                      workRequestID == requestID,
                      self.snapshot == snapshot,
                      frozenConfiguration == configuration else {
                    return
                }
                exportDocument = document
                isExporting = true
            } catch let error as VisitSummaryFailure
                where error == .stateChanged {
                guard !Task.isCancelled,
                      isActive,
                      workRequestID == requestID else {
                    return
                }
                exportDocument = nil
                exportMessage =
                    "预览后本地资料发生了变化；没有生成文件，请重新核对。"
            } catch {
                guard !Task.isCancelled,
                      isActive,
                      workRequestID == requestID else {
                    return
                }
                exportDocument = nil
                exportMessage =
                    "文件没有通过生成前复核；冻结预览仍保留。"
            }
        }
    }
#endif
}

private struct VisitSummaryToggleLedger<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .overlay {
            Rectangle().stroke(Color.primary, lineWidth: 1.5)
        }
    }
}

private struct VisitSummaryPreviewHeader: View {
    @Environment(AppTheme.self) private var theme
    let snapshot: VisitSummarySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FROZEN REPORT PREVIEW")
                .font(theme.utility(10))
                .tracking(1)
                .foregroundStyle(theme.mustardText)
            Text(snapshot.subjectName ?? "未包含姓名")
                .font(theme.display(26, relativeTo: .title2))
            Text(
                "\(snapshot.rangeStart.formatted(date: .numeric, time: .omitted))"
                    + " — "
                    + "\(snapshot.rangeEnd.formatted(date: .numeric, time: .omitted))"
            )
            .font(.caption.weight(.bold))
            Text("\(snapshot.recordCount) 项记录")
                .font(.body.weight(.black))
        }
        .foregroundStyle(theme.paper)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.indigoDeep)
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archive.visitSummary.preview")
    }
}

#if DEBUG
private enum VisitSummaryExportType {
    case pdf
    case csvPackage

    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .csvPackage:
            UTType(exportedAs: "com.mtfbook.unmanual.csv-package")
        }
    }

    var defaultFilename: String {
        let date = Date().formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        switch self {
        case .pdf:
            return "Unmanual-Visit-Summary-\(date)"
        case .csvPackage:
            return "Unmanual-Visit-Data-\(date)"
        }
    }
}

private struct VisitSummaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.pdf, UTType(exportedAs: "com.mtfbook.unmanual.csv-package")]
    }

    let data: Data?
    let files: [String: Data]?

    init(data: Data) {
        self.data = data
        self.files = nil
    }

    init(files: [String: Data]) {
        self.data = nil
        self.files = files
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws
        -> FileWrapper {
        if let data {
            return FileWrapper(regularFileWithContents: data)
        }
        guard let files else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(
            directoryWithFileWrappers: Dictionary(
                uniqueKeysWithValues: files.map {
                    (
                        $0.key,
                        FileWrapper(regularFileWithContents: $0.value)
                    )
                }
            )
        )
    }
}
#endif
