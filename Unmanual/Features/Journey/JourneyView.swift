import SwiftUI

@MainActor
struct JourneyView: View {
    @Binding private var requestedItem: PersonalTimelineItem?
    @State private var presentedSheet: JourneySheet?
    @State private var refreshToken = 0

    init(
        requestedItem: Binding<PersonalTimelineItem?> = .constant(nil)
    ) {
        _requestedItem = requestedItem
    }

    var body: some View {
        PersonalTimelineView(
            refreshToken: refreshToken,
            requestedItem: $requestedItem,
            recordAction: presentRecordEditor
        )
            .sheet(item: $presentedSheet, onDismiss: refreshAfterDismiss) { destination in
                switch destination {
                case .recordMenu:
                    JourneyRecordMenu(select: { presentedSheet = $0 })
                case .quickRecord:
                    QuickRecordEditor()
                case .lab:
                    LabSampleEditor()
                case .status:
                    StatusObservationEditor()
                }
            }
    }

    private func presentRecordEditor() {
        presentedSheet = .recordMenu
    }

    private func refreshAfterDismiss() {
        refreshToken &+= 1
    }
}

enum JourneySheet: String, Identifiable {
    case recordMenu
    case quickRecord
    case lab
    case status

    var id: String { rawValue }
}

private struct JourneyRecordMenu: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    let select: (JourneySheet) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("ADD / 添加记录")
                    .font(theme.utility(10))
                    .tracking(0.8)
                    .foregroundStyle(theme.vermilionText)
                Text("这次想留下什么？")
                    .font(theme.display(30, relativeTo: .title))
                    .padding(.top, 8)
                Text("只选当前需要的一种；稍后仍可继续添加。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 6)

                VStack(spacing: 0) {
                    menuRow(
                        title: "化验",
                        detail: "保存一组结果、原报告信息或附件",
                        systemImage: "cross.case",
                        destination: .lab
                    )
                    menuRow(
                        title: "状态",
                        detail: "用固定四级记录一个自定义指标",
                        systemImage: "waveform.path.ecg",
                        destination: .status
                    )
                    menuRow(
                        title: "普通记录",
                        detail: "留下一段感受或片段",
                        systemImage: "square.and.pencil",
                        destination: .quickRecord
                    )
                }
                .padding(.top, 24)

                V25PrivacyFooter(text: SystemBackupDisclosure.quickRecord)
                    .padding(.top, 24)
                Spacer(minLength: 20)
            }
            .padding(V25Theme.pagePadding)
            .background(theme.rice.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func menuRow(
        title: String,
        detail: String,
        systemImage: String,
        destination: JourneySheet
    ) -> some View {
        Button {
            select(destination)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(theme.paper)
                    .background(theme.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline.weight(.black))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

struct JourneyPageRecordAction: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        actionCopy
                        actionLabel
                    }
                } else {
                    HStack(spacing: 12) {
                        actionCopy
                        Spacer(minLength: 10)
                        actionLabel
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 14 : 5)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 5)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(theme.paper)
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.mustard).frame(height: 4)
        }
        .accessibilityLabel("记录旅程")
        .accessibilityHint("打开新的旅程记录")
        .accessibilityIdentifier("journey.record")
    }

    private var actionCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NEW ENTRY")
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.vermilionText)
            Text("想留下什么时再记")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var actionLabel: some View {
        Label("记录旅程", systemImage: "plus")
            .font(.body.weight(.black))
            .foregroundStyle(theme.paper)
            .padding(.horizontal, 14)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 46)
            .background(theme.indigoDeep)
    }
}
