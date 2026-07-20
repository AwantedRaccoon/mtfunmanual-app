import SwiftData
import SwiftUI

@MainActor
struct QuickRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppTheme.self) private var theme
    @Query(sort: \RegimenVersion.startedAt, order: .reverse) private var regimens: [RegimenVersion]

    @State private var text = ""
    @State private var kind: JourneyEntryKind = .moment
    @State private var occurredAt = Date()
    @State private var temporalEditor: JourneyTemporalField?
    @State private var saveErrorMessage: String?
    @FocusState private var isTextFocused: Bool

    private var activeRegimen: RegimenVersion? {
        regimens.first(where: { $0.endedAt == nil })
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    JourneyRecordHeader(cancel: dismiss.callAsFunction)

                    JourneyRecordIntro()
                        .padding(.top, 24)

                    JourneyEntryComposer(text: $text, isFocused: $isTextFocused)
                        .padding(.top, 22)

                    V25SectionHeader(title: "想记下什么", detail: kind.journeyRecordTitle)

                    JourneyKindSelector(selection: $kind)

                    V25SectionHeader(
                        title: "发生在",
                        detail: occurredAt.formatted(.dateTime.month().day())
                    )

                    JourneyDateTimePlate(
                        occurredAt: occurredAt,
                        editDateAction: { presentTemporalEditor(.date) },
                        editTimeAction: { presentTemporalEditor(.time) }
                    )

                    V25PrivacyFooter(text: "这条记录只保存在你的本地旅程中")
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
                V25SaveBar(
                    title: "保存到旅程",
                    isEnabled: canSave,
                    accessibilityIdentifier: "quickRecord.save",
                    action: save
                )
            }
            .onAppear { isTextFocused = true }
        }
        .tint(theme.indigo)
        .localSaveErrorAlert(message: $saveErrorMessage)
        .sheet(item: $temporalEditor) { field in
            JourneyTemporalEditor(
                field: field,
                initialValue: occurredAt,
                saveAction: { occurredAt = $0 }
            )
            .presentationDetents(field == .date ? [.large] : [.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func presentTemporalEditor(_ field: JourneyTemporalField) {
        isTextFocused = false
        temporalEditor = field
    }

    private func save() {
        do {
            modelContext.insert(
                JourneyEntry(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: kind,
                    occurredAt: occurredAt,
                    regimenVersionID: activeRegimen?.id
                )
            )
            try modelContext.save()
            dismiss()
        } catch {
            saveErrorMessage = "这条旅程仍在当前页面，请检查后再保存。"
        }
    }
}

private struct JourneyRecordHeader: View {
    @Environment(AppTheme.self) private var theme

    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("取消", action: cancel)
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .buttonStyle(.plain)

            Spacer()

            Text("LOCAL / JOURNEY")
                .font(theme.utility(10))
                .tracking(0.9)
        }
        .foregroundStyle(theme.indigo)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

private struct JourneyRecordIntro: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW ENTRY / 新的一页")
                .font(theme.utility(10))
                .tracking(0.9)
                .foregroundStyle(theme.vermilion)
            Text("记录旅程")
                .font(theme.display(36, relativeTo: .largeTitle))
                .foregroundStyle(theme.indigoDeep)
            Text("一句就够，不需要把今天解释完整。")
                .font(.subheadline)
                .foregroundStyle(theme.indigo.opacity(0.68))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct JourneyEntryComposer: View {
    @Environment(AppTheme.self) private var theme

    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("想留下什么？")
                .font(.caption.weight(.black))
                .foregroundStyle(theme.vermilion)

            TextField("写下一件想留下的事", text: $text, axis: .vertical)
                .font(theme.display(22, relativeTo: .body))
                .lineLimit(4...8)
                .focused(isFocused)
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
                .accessibilityIdentifier("quickRecord.text")

            Text("可以只写一句，也可以稍后再补充新的记录。")
                .font(.caption)
                .foregroundStyle(theme.indigo.opacity(0.58))
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(16)
        .background(theme.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.vermilion).frame(width: 6)
        }
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .background(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.mustard.opacity(0.84))
                .offset(x: 5, y: 5)
                .accessibilityHidden(true)
        }
        .padding(.trailing, 5)
        .padding(.bottom, 5)
    }
}

private struct JourneyKindSelector: View {
    @Environment(AppTheme.self) private var theme

    @Binding var selection: JourneyEntryKind

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(JourneyEntryKind.allCases) { kind in
                Button {
                    selection = kind
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.journeyRecordTitle)
                            .font(.body.weight(.black))
                        Text(kind.journeyRecordDetail)
                            .font(.caption)
                            .foregroundStyle(
                                selection == kind ? theme.paper.opacity(0.7) : theme.indigo.opacity(0.58)
                            )
                    }
                    .foregroundStyle(selection == kind ? theme.paper : theme.indigoDeep)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                    .background(selection == kind ? theme.indigoDeep : theme.paper)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(selection == kind ? theme.mustard : theme.indigo.opacity(0.28))
                            .frame(width: 4)
                    }
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.25) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(V25PressStyle())
                .accessibilityLabel("\(kind.journeyRecordTitle)，\(kind.journeyRecordDetail)")
                .accessibilityValue(selection == kind ? "已选择" : "")
                .accessibilityAddTraits(selection == kind ? [.isSelected] : [])
            }
        }
    }
}

private struct JourneyDateTimePlate: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let occurredAt: Date
    let editDateAction: () -> Void
    let editTimeAction: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    dateControl
                    Rectangle().fill(theme.paper.opacity(0.28)).frame(height: 1)
                    timeControl
                }
            } else {
                HStack(spacing: 14) {
                    dateControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(theme.paper.opacity(0.28)).frame(width: 1, height: 44)
                    timeControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(theme.paper)
        .background(theme.indigoDeep)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.mustard).frame(height: 4)
        }
    }

    private var dateControl: some View {
        Button(action: editDateAction) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("日期")
                        .font(theme.utility(9))
                        .tracking(0.8)
                        .foregroundStyle(theme.mustard)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(theme.mustard)
                }

                Text(dateText)
                    .font(theme.utility(19, relativeTo: .title3))
                    .tracking(0.5)
                    .monospacedDigit()
                    .foregroundStyle(theme.paper)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityLabel("发生日期，\(dateText)")
        .accessibilityHint("点按修改日期")
        .accessibilityIdentifier("quickRecord.date")
    }

    private var timeControl: some View {
        Button(action: editTimeAction) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("时间")
                        .font(theme.utility(9))
                        .tracking(0.8)
                        .foregroundStyle(theme.mustard)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(theme.mustard)
                }

                Text(timeText)
                    .font(theme.utility(19, relativeTo: .title3))
                    .tracking(0.5)
                    .monospacedDigit()
                    .foregroundStyle(theme.paper)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityLabel("发生时间，\(timeText)")
        .accessibilityHint("点按修改时间")
        .accessibilityIdentifier("quickRecord.time")
    }

    private var dateText: String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: occurredAt)
        return String(
            format: "%04d.%02d.%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private var timeText: String {
        occurredAt.formatted(date: .omitted, time: .shortened)
    }
}

private enum JourneyTemporalField: String, Identifiable {
    case date
    case time

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: "修改日期"
        case .time: "修改时间"
        }
    }

    var actionTitle: String {
        switch self {
        case .date: "使用这个日期"
        case .time: "使用这个时间"
        }
    }
}

private struct JourneyTemporalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme

    let field: JourneyTemporalField
    let saveAction: (Date) -> Void

    @State private var draftValue: Date

    init(
        field: JourneyTemporalField,
        initialValue: Date,
        saveAction: @escaping (Date) -> Void
    ) {
        self.field = field
        self.saveAction = saveAction
        _draftValue = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("取消", action: dismiss.callAsFunction)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .buttonStyle(.plain)

                    Spacer()

                    Text(field == .date ? "DATE / EDIT" : "TIME / EDIT")
                        .font(theme.utility(10))
                        .tracking(0.9)
                }
                .foregroundStyle(theme.indigo)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.indigo).frame(height: 1)
                }

                Text(field.title)
                    .font(theme.display(34, relativeTo: .largeTitle))
                    .foregroundStyle(theme.indigoDeep)
                    .padding(.top, 22)

                picker
                    .padding(.top, 18)

                Spacer(minLength: 16)
            }
            .padding(.horizontal, V25Theme.pagePadding)
            .background(theme.rice.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(field.actionTitle) {
                    saveAction(draftValue)
                    dismiss()
                }
                .buttonStyle(V25PrimaryButtonStyle())
                .padding(.horizontal, V25Theme.pagePadding)
                .padding(.top, 9)
                .padding(.bottom, 8)
                .background(theme.rice)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.indigo).frame(height: 1)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(theme.indigo)
    }

    @ViewBuilder
    private var picker: some View {
        if field == .date {
            DatePicker("日期", selection: $draftValue, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(12)
                .background(theme.paper)
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                .accessibilityLabel("选择日期")
        } else {
            DatePicker("时间", selection: $draftValue, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(theme.paper)
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                .accessibilityLabel("选择时间")
        }
    }
}

private extension JourneyEntryKind {
    var journeyRecordTitle: String {
        switch self {
        case .change: "变化"
        case .feeling: "感受"
        case .question: "问题"
        case .moment: "时刻"
        }
    }

    var journeyRecordDetail: String {
        switch self {
        case .change: "身体或生活"
        case .feeling: "此刻的状态"
        case .question: "以后想问"
        case .moment: "想记住的事"
        }
    }
}
