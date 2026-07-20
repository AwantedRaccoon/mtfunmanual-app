import SwiftData
import SwiftUI

@MainActor
struct RegimenVersionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppTheme.self) private var theme
    @Query(sort: \RegimenVersion.startedAt, order: .reverse) private var regimens: [RegimenVersion]

    @State private var title = ""
    @State private var startedAt = Date()
    @State private var note = ""
    @State private var draftMedications: [RegimenMedicationDraft]
    @State private var isChoosingMedication = false
    @State private var didLoadCurrentVersion = false
    @State private var saveErrorMessage: String?

    init(initialMedications: [RegimenMedicationDraft] = []) {
        _draftMedications = State(initialValue: initialMedications)
    }

    private var activeRegimen: RegimenVersion? {
        regimens.first(where: { $0.endedAt == nil })
    }

    private var draftCode: String {
        let largestExistingNumber = regimens.compactMap { regimen in
            Int(regimen.code.split(separator: "-").last ?? "")
        }.max() ?? 0
        return String(format: "R-%02d", largestExistingNumber + 1)
    }

    private var canSave: Bool {
        let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let activeRegimen else { return hasTitle }
        return hasTitle && startedAt >= Calendar.current.startOfDay(for: activeRegimen.startedAt)
    }

    var body: some View {
        NavigationStack {
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

                    V25PrivacyFooter(text: "保存只记录你输入的方案，不会据此生成剂量或用药建议")
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, V25Theme.pagePadding)
                .frame(maxWidth: V25Theme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .background(theme.rice.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RegimenSaveBar(
                    isEnabled: canSave,
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
        .task(id: activeRegimen?.id) {
            loadCurrentVersionIfNeeded()
        }
        .localSaveErrorAlert(message: $saveErrorMessage)
    }

    private func loadCurrentVersionIfNeeded() {
        guard !didLoadCurrentVersion, let activeRegimen else { return }
        title = activeRegimen.title
        startedAt = max(Date(), Calendar.current.startOfDay(for: activeRegimen.startedAt))
        didLoadCurrentVersion = true
    }

    private func save() {
        do {
            if let activeRegimen {
                activeRegimen.endedAt = startedAt
            }

            modelContext.insert(
                RegimenVersion(
                    code: draftCode,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    startedAt: startedAt,
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            try modelContext.save()
            dismiss()
        } catch {
            saveErrorMessage = "修改仍保留在当前页面，请检查后再保存。"
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

    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("取消", action: cancel)
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .buttonStyle(.plain)

            Spacer()

            Text("LOCAL / CURRENT PLAN")
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

    let isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isEditing ? "CURRENT PLAN / 正在修改" : "FIRST PLAN / 初次建立")
                .font(theme.utility(10))
                .tracking(0.9)
                .foregroundStyle(theme.vermilion)

            Text(isEditing ? "编辑当前方案" : "建立方案")
                .font(theme.display(36, relativeTo: .largeTitle))
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
    let previousRegimen: RegimenVersion?

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
                Text("这段说明只帮助以后回看，不会参与方案判断。")
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

            Button(isEditing ? "保存修改" : "保存方案", action: action)
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
