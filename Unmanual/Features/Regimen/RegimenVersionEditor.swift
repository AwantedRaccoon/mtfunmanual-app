import SwiftUI

@MainActor
struct RegimenVersionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appReadActor) private var appReadActor
    @Environment(AppTheme.self) private var theme

    @State private var overview = CoreRegimenOverviewSnapshot.empty
    @State private var title = ""
    @State private var startedAt = Date()
    @State private var note = ""
    @State private var draftMedications: [RegimenMedicationDraft]
    @State private var isChoosingMedication = false
    @State private var didLoadCurrentVersion = false
    @State private var saveErrorMessage: String?
    @State private var isSaving = false
    @State private var previewSheet: RegimenPreviewSheet?
    @State private var draftID = UUID()
    private let requestedDraftID: UUID?

    init(
        existingDraftID: UUID? = nil,
        initialMedications: [RegimenMedicationDraft] = []
    ) {
        requestedDraftID = existingDraftID
        _draftID = State(initialValue: existingDraftID ?? UUID())
        _draftMedications = State(initialValue: initialMedications)
    }

    private var activeRegimen: CoreRegimenVersionSnapshot? { overview.current }
    private var editingDraft: CoreRegimenVersionSnapshot? {
        guard let requestedDraftID else { return nil }
        return overview.drafts.first { $0.id == requestedDraftID }
    }

    private var draftCode: String {
        if let editingDraft { return editingDraft.code }
        let largestExistingNumber = overview.allVersions.compactMap { regimen in
            Int(regimen.code.split(separator: "-").last ?? "")
        }.max() ?? 0
        return String(format: "R-%02d", largestExistingNumber + 1)
    }

    private var canSave: Bool {
        let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasTitle && !draftMedications.isEmpty
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        RegimenEditHeader(cancel: dismiss.callAsFunction)

                        RegimenEditIntro(isEditing: activeRegimen != nil)
                            .padding(.top, 24)

                        RegimenIdentitySlip(
                            title: $title,
                            startedAt: $startedAt,
                            draftCode: draftCode,
                            previousCode: activeRegimen?.code
                        )
                        .padding(.top, 22)

                        V25SectionHeader(
                            title: "方案组成",
                            detail: draftMedications.isEmpty ? "尚未添加" : "\(draftMedications.count) 项"
                        )

                        RegimenMedicationLedger(
                            medications: draftMedications,
                            addAction: { isChoosingMedication = true },
                            removeAction: removeMedication
                        )

                        V25SectionHeader(
                            title: "这次修改",
                            detail: activeRegimen == nil ? "首次建立" : "旧版本留档"
                        )

                        RegimenRevisionNote(note: $note, previousRegimen: activeRegimen)
                    }
                    .padding(.bottom, 24)
                    .frame(
                        width: min(
                            V25Theme.contentWidth,
                            max(0, geometry.size.width - V25Theme.pagePadding * 2)
                        ),
                        alignment: .leading
                    )
                    .padding(.horizontal, V25Theme.pagePadding)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
            .background(theme.rice.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RegimenSaveBar(
                    isEnabled: canSave && !isSaving,
                    nextCode: draftCode,
                    isEditing: activeRegimen != nil,
                    action: save
                )
            }
            .navigationDestination(isPresented: $isChoosingMedication) {
                MedicationCatalogPicker(
                    backAction: { isChoosingMedication = false },
                    chooseAction: addMedication
                )
            }
        }
        .tint(theme.indigo)
        .task { await loadCurrentVersionIfNeeded() }
        .localSaveErrorAlert(message: $saveErrorMessage)
        .sheet(item: $previewSheet) { sheet in
            RegimenImpactReviewSheet(
                preview: sheet.preview,
                code: draftCode,
                effectiveDate: sheet.effectiveDate,
                isSaving: isSaving,
                cancel: { previewSheet = nil },
                confirm: { seal(sheet) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func loadCurrentVersionIfNeeded() async {
        do {
            let today = try HistoricalTimestamp.captured(
                instant: Date(),
                timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
            ).localDate
            if let updated = try await appReadActor?.coreRegimenOverview(asOf: today) {
                overview = updated
            }
        } catch {
            saveErrorMessage = "暂时无法读取当前方案，原资料没有被修改。"
        }
        guard !didLoadCurrentVersion else { return }
        guard let source = editingDraft ?? activeRegimen else {
            didLoadCurrentVersion = true
            return
        }
        let isCloningSealedVersion = editingDraft == nil
        title = source.title
        note = source.changeReason
        if let sourceDate = try? displayDate(from: source.effectiveStartDate) {
            startedAt = sourceDate
        }
        draftMedications = source.items.map {
            RegimenMedicationDraft(
                id: isCloningSealedVersion ? UUID() : $0.id,
                catalogID: $0.catalogProductID,
                catalogVersion: $0.catalogVersion,
                name: $0.displayName,
                englishName: $0.genericName,
                detail: $0.productSnapshot.isEmpty
                    ? [$0.dosageForm, $0.route, $0.doseOriginal, $0.unitOriginal]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    : $0.productSnapshot,
                dosageForm: $0.dosageForm,
                route: $0.route,
                doseOriginal: $0.doseOriginal,
                unitOriginal: $0.unitOriginal,
                schedule: $0.schedule?.input(cloningIdentity: isCloningSealedVersion),
                productSnapshot: $0.productSnapshot,
                origin: $0.catalogProductID == nil ? .custom : .catalog
            )
        }
        didLoadCurrentVersion = true
    }

    private func displayDate(from date: CivilDateFact) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let value = calendar.date(
            from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)
        ) else {
            throw AppWriteFailure.invalidInput
        }
        return value
    }

    private func save() {
        guard !isSaving else { return }
        guard let appDataWriter else {
            saveErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let effectiveDate = try HistoricalTimestamp.captured(
                    instant: startedAt,
                    timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                    provenance: .userEntered
                ).localDate
                let previousVersionID = editingDraft?.previousVersionID
                    ?? overview.allVersions
                        .filter {
                            $0.editState == .sealed
                                && !$0.requiresReview
                                && $0.effectiveStartDate < effectiveDate
                        }
                        .sorted {
                            $0.effectiveStartDate != $1.effectiveStartDate
                                ? $0.effectiveStartDate < $1.effectiveStartDate
                                : $0.id.uuidString < $1.id.uuidString
                        }
                        .last?.id
                let command = SaveRegimenDraftCommand(
                    recordID: draftID,
                    previousVersionID: previousVersionID,
                    code: draftCode,
                    title: title,
                    effectiveStartDate: effectiveDate,
                    changeReason: note,
                    items: draftMedications.map {
                        RegimenItemInput(
                            id: $0.id,
                            catalogProductID: $0.catalogID,
                            catalogVersion: $0.catalogVersion,
                            displayName: $0.name,
                            genericName: $0.englishName,
                            dosageForm: $0.dosageForm,
                            route: $0.route,
                            doseOriginal: $0.doseOriginal,
                            unitOriginal: $0.unitOriginal,
                            productSnapshot: $0.productSnapshot,
                            schedule: $0.schedule
                        )
                    },
                    committedAt: Date()
                )
                try await appDataWriter.saveRegimenDraft(command)
                let preview = try await appDataWriter.previewRegimenChange(draftID: draftID)
                previewSheet = RegimenPreviewSheet(
                    preview: preview,
                    effectiveDate: effectiveDate
                )
            } catch {
                saveErrorMessage = "校样仍保留在当前页面，请检查后再保存。"
            }
        }
    }

    private func seal(_ sheet: RegimenPreviewSheet) {
        guard !isSaving, let appDataWriter else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await appDataWriter.sealRegimenDraft(
                    SealRegimenDraftCommand(
                        draftID: sheet.preview.draftID,
                        expectedNextLocalRevision: sheet.preview.expectedNextLocalRevision,
                        draftDigest: sheet.preview.draftDigest,
                        committedAt: Date()
                    )
                )
                previewSheet = nil
                dismiss()
            } catch {
                previewSheet = nil
                saveErrorMessage = "核对期间资料已经变化，请重新查看影响后再封存。"
            }
        }
    }

    private func addMedication(_ medication: RegimenMedicationDraft) {
        draftMedications.append(medication)
        isChoosingMedication = false
    }

    private func removeMedication(_ medication: RegimenMedicationDraft) {
        draftMedications.removeAll { $0.id == medication.id }
    }
}

private struct RegimenEditHeader: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("取消", action: cancel)
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .buttonStyle(.plain)

            Spacer()

            Text(dynamicTypeSize.isAccessibilitySize ? "方案编辑" : "LOCAL / CURRENT PLAN")
                .font(theme.utility(10))
                .tracking(0.9)
        }
        .foregroundStyle(theme.indigo)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

private struct RegimenEditIntro: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                dynamicTypeSize.isAccessibilitySize
                    ? (isEditing ? "正在修改" : "初次建立")
                    : (isEditing ? "CURRENT PLAN / 正在修改" : "FIRST PLAN / 初次建立")
            )
                .font(theme.utility(10))
                .tracking(0.9)
                .foregroundStyle(theme.vermilion)

            Text(isEditing ? "编辑当前方案" : "建立方案")
                .font(
                    theme.display(
                        dynamicTypeSize.isAccessibilitySize ? 26 : 36,
                        relativeTo: dynamicTypeSize.isAccessibilitySize ? .headline : .largeTitle
                    )
                )
                .foregroundStyle(theme.indigoDeep)

            Text(isEditing ? "调整今天以后使用的方案。保存后，旧方案仍会留在历史记录里。" : "先把现在使用的药物记下来，之后可以随时修改。")
                .font(.subheadline)
                .foregroundStyle(theme.indigo.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RegimenIdentitySlip: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var title: String
    @Binding var startedAt: Date
    let draftCode: String
    let previousCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("方案校样")
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.mustard)
                Spacer()
                Text(draftCode + " / DRAFT")
                    .font(theme.utility(10))
                    .tracking(0.7)
                    .foregroundStyle(theme.paper.opacity(0.74))
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)

            TextField("方案名称", text: $title)
                .font(theme.display(dynamicTypeSize.isAccessibilitySize ? 25 : 30, relativeTo: .title))
                .foregroundStyle(theme.paper)
                .tint(theme.mustard)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .accessibilityLabel("方案名称")
                .accessibilityIdentifier("regimen.title")

            Rectangle()
                .fill(theme.paper.opacity(0.34))
                .frame(height: 1)
                .padding(.horizontal, 16)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        effectiveDateLabel
                        effectiveDatePicker
                    }
                } else {
                    HStack(spacing: 12) {
                        effectiveDateLabel
                        Spacer()
                        effectiveDatePicker
                    }
                }
            }
            .padding(16)
        }
        .background(theme.indigoDeep)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.vermilion)
                .frame(width: 7)
        }
        .background(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.mustard.opacity(0.88))
                .offset(x: 6, y: 6)
                .accessibilityHidden(true)
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
    }

    private var effectiveDateLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("从这一天开始")
                .font(.caption.weight(.black))
            if let previousCode {
                Text("届时归档 \(previousCode)")
                    .font(.caption)
                    .foregroundStyle(theme.paper.opacity(0.64))
            }
        }
        .foregroundStyle(theme.paper)
    }

    private var effectiveDatePicker: some View {
        DatePicker("生效日期", selection: $startedAt, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .colorScheme(.dark)
            .tint(theme.mustard)
            .accessibilityLabel("生效日期")
            .accessibilityIdentifier("regimen.startDate")
    }
}

private struct RegimenMedicationLedger: View {
    @Environment(AppTheme.self) private var theme

    let medications: [RegimenMedicationDraft]
    let addAction: () -> Void
    let removeAction: (RegimenMedicationDraft) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if medications.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("还没有药物")
                        .font(.headline.weight(.black))
                    Text("从药品索引定位具体产品，或按药盒上的原始写法添加。")
                        .font(.subheadline)
                        .foregroundStyle(theme.indigo.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(medications.enumerated()), id: \.element.id) { index, medication in
                    RegimenMedicationLedgerRow(
                        position: index + 1,
                        medication: medication,
                        removeAction: { removeAction(medication) }
                    )
                }
            }

            Button(action: addAction) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                    Text("从药品索引添加")
                        .font(.body.weight(.black))
                    Spacer()
                    Text("定位到具体产品")
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.62))
                }
                .foregroundStyle(theme.indigoDeep)
                .padding(.horizontal, 15)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(V25PressStyle())
            .overlay(alignment: .top) {
                Rectangle().fill(theme.indigo.opacity(0.42)).frame(height: 1)
            }
            .accessibilityIdentifier("regimen.addMedication")
        }
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

private struct RegimenMedicationLedgerRow: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let position: Int
    let medication: RegimenMedicationDraft
    let removeAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(String(format: "%02d", position))
                .font(theme.utility(13))
                .monospacedDigit()
                .foregroundStyle(theme.vermilion)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(medication.name)
                    .font(.body.weight(.black))
                    .foregroundStyle(theme.indigoDeep)
                if !medication.englishName.isEmpty && !dynamicTypeSize.isAccessibilitySize {
                    Text(medication.englishName)
                        .font(theme.utility(9))
                        .tracking(0.25)
                        .foregroundStyle(theme.indigo.opacity(0.58))
                }
                Text(medication.detail)
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: removeAction) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.indigo.opacity(0.68))
            .accessibilityLabel("移除 \(medication.name)")
        }
        .padding(.leading, 15)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .frame(minHeight: 76)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.34)).frame(height: 1)
        }
    }
}

private struct RegimenRevisionNote: View {
    @Environment(AppTheme.self) private var theme

    @Binding var note: String
    let previousRegimen: CoreRegimenVersionSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let previousRegimen {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(previousRegimen.code)
                        .font(theme.utility(11))
                        .foregroundStyle(theme.vermilion)
                    Text(previousRegimen.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("将转入历史")
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.58))
                }
                .padding(14)
                .background(theme.blue.opacity(0.13))

                Rectangle().fill(theme.indigo.opacity(0.4)).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("修改说明（可选）")
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.vermilion)
                TextField("例如：复诊后调整，或原产品暂时无法获得", text: $note, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("regimen.note")
                Text("保存为这次修改的备注，方便以后回看。")
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.6))
            }
            .padding(14)
        }
        .foregroundStyle(theme.indigoDeep)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

private struct RegimenSaveBar: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let isEnabled: Bool
    let nextCode: String
    let isEditing: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isEditing && !dynamicTypeSize.isAccessibilitySize {
                Text("保存后生成 \(nextCode)，原版本保留在历史记录中")
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.66))
            }

            Button(
                dynamicTypeSize.isAccessibilitySize ? "保存校样" : "保存校样并核对影响",
                action: action
            )
                .buttonStyle(V25PrimaryButtonStyle())
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.46)
                .accessibilityIdentifier("regimen.save")
        }
        .padding(.horizontal, V25Theme.pagePadding)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(theme.rice)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

private struct RegimenPreviewSheet: Identifiable {
    let preview: RegimenChangePreview
    let effectiveDate: CivilDateFact

    var id: UUID { preview.draftID }
}

private struct RegimenImpactReviewSheet: View {
    @Environment(AppTheme.self) private var theme

    let preview: RegimenChangePreview
    let code: String
    let effectiveDate: CivilDateFact
    let isSaving: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("IMPACT PROOF / 影响核对")
                        .font(theme.utility(10))
                        .tracking(0.9)
                        .foregroundStyle(theme.vermilion)
                    Text("封存 \(code)")
                        .font(theme.display(32, relativeTo: .largeTitle))
                        .foregroundStyle(theme.indigoDeep)
                    Text("从 \(effectiveDate.iso8601) 起生效。旧版本保持封存，不会被覆盖。")
                        .font(.body)
                        .foregroundStyle(theme.indigo.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    versionProof(
                        label: "变更前",
                        version: preview.before,
                        emptyCopy: "这是第一个方案版本"
                    )
                    versionProof(
                        label: "变更后",
                        version: preview.after,
                        emptyCopy: ""
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        impactRow("旅程记录", count: preview.affectedJourneyIDs.count)
                        impactRow("检查记录", count: preview.affectedLabIDs.count)
                        if !preview.affectedRecords.isEmpty {
                            Divider().overlay(theme.indigo.opacity(0.3))
                            ForEach(preview.affectedRecords) { record in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(
                                        (record.sourceRecordType == "JourneyEntry" ? "旅程" : "检查")
                                            + " · " + record.localDate.iso8601
                                    )
                                        .font(.caption.weight(.black))
                                    Text(record.summary)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(
                                        associationChangeText(
                                            before: record.beforeRegimenVersionID,
                                            after: record.afterRegimenVersionID
                                        )
                                    )
                                        .font(.caption.monospaced())
                                        .foregroundStyle(theme.indigo.opacity(0.68))
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                    .padding(14)
                    .background(theme.paper)
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }

                    Text("取消只会关闭本页；这份校样已明确保存，但在封存前不会成为当前方案，也不会改变历史关联。")
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("确认封存并更新关联", action: confirm)
                        .buttonStyle(V25PrimaryButtonStyle())
                        .disabled(isSaving)
                        .accessibilityIdentifier("regimen.confirmSeal")
                }
                .padding(V25Theme.pagePadding)
            }
            .background(theme.rice.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回修改", action: cancel)
                }
            }
        }
        .tint(theme.indigo)
    }

    private func impactRow(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.body.weight(.semibold))
            Spacer()
            Text("\(count) 条")
                .font(.body.monospacedDigit().weight(.black))
        }
        .foregroundStyle(theme.indigoDeep)
        .frame(minHeight: 44)
    }

    private func associationChangeText(before: UUID?, after: UUID?) -> String {
        let beforeCode = before.flatMap(codeForRegimen) ?? "未关联"
        let afterCode = after.flatMap(codeForRegimen) ?? "未关联"
        return beforeCode + " → " + afterCode
    }

    private func codeForRegimen(_ id: UUID) -> String? {
        if preview.after.code.isEmpty == false, id == preview.draftID {
            return preview.after.code
        }
        if let before = preview.before,
           preview.affectedRecords.contains(where: { $0.beforeRegimenVersionID == id }) {
            return before.code
        }
        return String(id.uuidString.prefix(8))
    }

    @ViewBuilder
    private func versionProof(
        label: String,
        version: RegimenChangeVersionPreview?,
        emptyCopy: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.vermilion)
            if let version {
                Text(version.code + " · " + version.title)
                    .font(.headline)
                    .foregroundStyle(theme.indigoDeep)
                if version.items.isEmpty {
                    Text("没有组成项")
                        .font(.subheadline)
                        .foregroundStyle(theme.indigo.opacity(0.65))
                } else {
                    ForEach(Array(version.items.enumerated()), id: \.offset) { index, item in
                        Text("\(index + 1). \(item)")
                            .font(.subheadline)
                            .foregroundStyle(theme.indigo)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(emptyCopy)
                    .font(.subheadline)
                    .foregroundStyle(theme.indigo.opacity(0.65))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}
