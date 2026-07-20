import SwiftData
import SwiftUI

@MainActor
struct ArchiveView: View {
    @Environment(AppTheme.self) private var theme
    @Query(sort: \HRTProfile.startDate) private var profiles: [HRTProfile]
    @Query(sort: \CountdownRecord.targetDate, order: .reverse) private var countdowns: [CountdownRecord]
    @Query(sort: \JourneyEntry.occurredAt, order: .reverse) private var entries: [JourneyEntry]
    @Query(sort: \LabRecord.sampledAt, order: .reverse) private var labRecords: [LabRecord]
    @Query(sort: \RegimenVersion.startedAt, order: .reverse) private var regimens: [RegimenVersion]

    @State private var destination: ArchiveDestination?

    private var snapshot: ArchiveSnapshot {
        ArchiveSnapshot(
            profiles: profiles,
            countdowns: countdowns,
            entries: entries,
            labRecords: labRecords,
            regimens: regimens
        )
    }

    var body: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "V2.5 / LOCAL ARCHIVE",
                    title: "档案",
                    subtitle: "整理、带走，也决定留下什么。",
                    status: "仅在本机"
                )

                V25SectionHeader(
                    title: "这台设备里的记录",
                    detail: snapshot.latestActivityLabel
                )

                ArchiveDossierCover(snapshot: snapshot)

                V25SectionHeader(title: "整理并带走", detail: "先预览，再生成")

                ArchiveExportDesk(
                    snapshot: snapshot,
                    summaryAction: { destination = .visitSummary },
                    exportAction: { destination = .rawExport }
                )

                V25SectionHeader(title: "数据与隐私", detail: "你来决定")

                ArchiveControlLedger(
                    storageAction: { destination = .localStorage },
                    deleteAction: { destination = .deleteAndReset }
                )

                V25SectionHeader(title: "随身附页", detail: "需要时再打开")

                ArchiveSupplementIndex(
                    unitAction: { destination = .unitConversion },
                    knowledgeAction: { destination = .knowledgeSearch }
                )

                V25PrivacyFooter(text: "导出前会完整预览；导出的文件不再受 App 保护")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $destination) { destination in
            ArchivePreviewSheet(destination: destination, snapshot: snapshot)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ArchiveSnapshot {
    let journeyCount: Int
    let labSampleCount: Int
    let labRecordCount: Int
    let regimenCount: Int
    let profileCount: Int
    let countdownCount: Int
    let firstActivityDate: Date?
    let latestActivityDate: Date?

    init(
        profiles: [HRTProfile],
        countdowns: [CountdownRecord],
        entries: [JourneyEntry],
        labRecords: [LabRecord],
        regimens: [RegimenVersion]
    ) {
        let calendar = Calendar.autoupdatingCurrent
        let sampleDays = Set(labRecords.map { calendar.startOfDay(for: $0.sampledAt) })
        let dates = profiles.map(\.startDate)
            + entries.map(\.occurredAt)
            + labRecords.map(\.sampledAt)
            + regimens.map(\.startedAt)

        journeyCount = entries.count
        labSampleCount = sampleDays.count
        labRecordCount = labRecords.count
        regimenCount = regimens.count
        profileCount = profiles.count
        countdownCount = countdowns.count
        firstActivityDate = dates.min()
        latestActivityDate = dates.max()
    }

    var exportItemCount: Int {
        journeyCount + labRecordCount + regimenCount + profileCount + countdownCount
    }

    var supportingDateCount: Int {
        profileCount + countdownCount
    }

    var hasContent: Bool {
        exportItemCount > 0
    }

    var rangeLabel: String {
        guard let firstActivityDate, let latestActivityDate else {
            return "还没有记录范围"
        }

        let first = firstActivityDate.formatted(.dateTime.year().month(.twoDigits))
        let latest = latestActivityDate.formatted(.dateTime.year().month(.twoDigits))
        return first == latest ? first : "\(first) — \(latest)"
    }

    var latestActivityLabel: String {
        guard let latestActivityDate else { return "等待第一笔" }
        return "更新至 " + latestActivityDate.formatted(.dateTime.month().day())
    }
}

private struct ArchiveDossierCover: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let snapshot: ArchiveSnapshot

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.mustard)
                .offset(x: 6, y: 6)

            HStack(spacing: 0) {
                archiveSpine

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PERSONAL RECORD")
                                .font(theme.utility(9))
                                .tracking(1)
                                .foregroundStyle(theme.vermilion)
                            Text(snapshot.hasContent ? "你的个人记录档案" : "从第一笔开始")
                                .font(theme.display(25, relativeTo: .title2))
                                .foregroundStyle(theme.indigoDeep)
                        }

                        Spacer(minLength: 8)

                        Text("本机")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(theme.paper)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 26)
                            .background(theme.blue)
                    }

                    Text(snapshot.rangeLabel)
                        .font(theme.utility(11))
                        .tracking(0.5)
                        .foregroundStyle(theme.indigo.opacity(0.62))
                        .padding(.top, 10)

                    Rectangle()
                        .fill(theme.indigo)
                        .frame(height: 1)
                        .padding(.vertical, 12)

                    ArchiveCounts(snapshot: snapshot, stacked: dynamicTypeSize.isAccessibilitySize)

                    Text(coverNote)
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.64))
                        .padding(.top, 13)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
            }
            .background(theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "本机个人档案，旅程 \(snapshot.journeyCount) 笔，检查 \(snapshot.labSampleCount) 次，方案 \(snapshot.regimenCount) 版，范围 \(snapshot.rangeLabel)"
        )
    }

    private var archiveSpine: some View {
        ZStack {
            theme.indigoDeep
            Text("LOCAL / 04")
                .font(theme.utility(9))
                .tracking(1.2)
                .foregroundStyle(theme.mustard)
                .rotationEffect(.degrees(-90))
                .fixedSize()
        }
        .frame(width: 38)
    }

    private var coverNote: String {
        guard snapshot.supportingDateCount > 0 else {
            return "所有数量都来自你在这台设备上保存的内容。"
        }
        return "另含 \(snapshot.profileCount) 个开始日与 \(snapshot.countdownCount) 个 Countdown。"
    }
}

private struct ArchiveCounts: View {
    @Environment(AppTheme.self) private var theme

    let snapshot: ArchiveSnapshot
    let stacked: Bool

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 12) { countItems }
            } else {
                HStack(alignment: .top, spacing: 8) { countItems }
            }
        }
    }

    @ViewBuilder
    private var countItems: some View {
        ArchiveCount(value: snapshot.journeyCount, label: "旅程", color: theme.vermilion)
        ArchiveCount(value: snapshot.labSampleCount, label: "检查", color: theme.blue)
        ArchiveCount(value: snapshot.regimenCount, label: "方案", color: theme.moss)
    }
}

private struct ArchiveCount: View {
    @Environment(AppTheme.self) private var theme

    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value, format: .number)
                .font(theme.display(29, relativeTo: .title2))
                .monospacedDigit()
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.indigo.opacity(0.62))
        }
        .foregroundStyle(theme.indigoDeep)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(color).frame(width: 24, height: 3).offset(y: 5)
        }
    }
}

private struct ArchiveExportDesk: View {
    let snapshot: ArchiveSnapshot
    let summaryAction: () -> Void
    let exportAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArchiveActionRow(
                kicker: "一页摘要",
                title: "整理就诊材料",
                detail: "选择时间范围和内容，先生成一份可核对的预览。",
                badge: "PDF",
                style: .primary,
                action: summaryAction
            )

            ArchiveActionRow(
                kicker: "原始副本",
                title: "导出自己的数据",
                detail: snapshot.exportItemCount == 0
                    ? "留下记录后，可以按类别生成原始数据文件。"
                    : "共 \(snapshot.exportItemCount) 条原始数据，可按类别分别选择。",
                badge: "CSV",
                style: .secondary,
                action: exportAction
            )
        }
    }
}

private struct ArchiveActionRow: View {
    enum Style { case primary, secondary }

    @Environment(AppTheme.self) private var theme

    let kicker: String
    let title: String
    let detail: String
    let badge: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kicker.uppercased())
                        .font(theme.utility(9))
                        .tracking(0.8)
                        .foregroundStyle(style == .primary ? theme.mustard : theme.vermilion)
                    Text(title)
                        .font(theme.display(23, relativeTo: .title3))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(foreground.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 14) {
                    Text(badge)
                        .font(theme.utility(10))
                        .tracking(0.8)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 24)
                        .overlay { Rectangle().stroke(foreground.opacity(0.72), lineWidth: 1) }

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .black))
                }
            }
            .foregroundStyle(foreground)
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(style == .primary ? theme.vermilion : theme.blue)
                    .frame(width: 5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityHint("打开内容预览")
    }

    private var foreground: Color {
        style == .primary ? theme.paper : theme.indigoDeep
    }

    private var background: Color {
        style == .primary ? theme.indigoDeep : theme.paper
    }
}

private struct ArchiveControlLedger: View {
    @Environment(AppTheme.self) private var theme

    let storageAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArchiveLedgerRow(
                title: "本地存储说明",
                detail: "看看哪些内容留在设备里，导出后又会发生什么。",
                status: "当前：本机",
                color: theme.blue,
                action: storageAction
            )
            ArchiveLedgerRow(
                title: "删除与重置",
                detail: "逐项检查记录，不提供含糊的“一键无痕”承诺。",
                status: "逐项处理",
                color: theme.vermilion,
                action: deleteAction
            )
        }
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

private struct ArchiveLedgerRow: View {
    @Environment(AppTheme.self) private var theme

    let title: String
    let detail: String
    let status: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Rectangle().fill(color).frame(width: 4, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.black))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.indigo.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(status)
                        .font(theme.utility(9))
                        .tracking(0.4)
                        .foregroundStyle(theme.indigo.opacity(0.62))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.black))
                }
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .background(theme.paper)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
    }
}

private struct ArchiveSupplementIndex: View {
    @Environment(AppTheme.self) private var theme

    let unitAction: () -> Void
    let knowledgeAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            supplementRow(
                label: "换算",
                title: "单位换算",
                detail: "保留原始值，换算结果单独标记",
                action: unitAction
            )
            supplementRow(
                label: "资料",
                title: "查找 MTF不全书",
                detail: "完整内容仍由网站承担",
                action: knowledgeAction
            )
        }
        .overlay(alignment: .top) { Rectangle().fill(theme.indigo).frame(height: 1.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.indigo).frame(height: 1.5) }
    }

    private func supplementRow(
        label: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(theme.utility(9))
                    .tracking(0.6)
                    .foregroundStyle(theme.vermilion)
                    .frame(width: 34, alignment: .leading)
                Text(title)
                    .font(.subheadline.weight(.black))
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.58))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.black))
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo.opacity(0.42)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
    }
}

private enum ArchiveDestination: String, Identifiable {
    case visitSummary
    case rawExport
    case localStorage
    case deleteAndReset
    case unitConversion
    case knowledgeSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visitSummary: "整理就诊材料"
        case .rawExport: "导出自己的数据"
        case .localStorage: "本地存储说明"
        case .deleteAndReset: "删除与重置"
        case .unitConversion: "单位换算"
        case .knowledgeSearch: "查找资料"
        }
    }

    var eyebrow: String {
        switch self {
        case .visitSummary: "SUMMARY / PREVIEW"
        case .rawExport: "DATA / PREVIEW"
        case .localStorage: "LOCAL / PRIVACY"
        case .deleteAndReset: "DATA / CONTROL"
        case .unitConversion: "UTILITY / CONVERT"
        case .knowledgeSearch: "MTFBOOK / SEARCH"
        }
    }

    var detail: String {
        switch self {
        case .visitSummary: "先选择范围和内容，再核对一页摘要。它不会被写成处方或诊断证明。"
        case .rawExport: "按类别选择原始记录，完整预览后才生成文件。"
        case .localStorage: "这里会逐项说明本机数据、系统备份和导出文件之间的边界。"
        case .deleteAndReset: "删除前先列出准确对象和影响范围，并再次确认。"
        case .unitConversion: "换算不会覆盖医院报告中的原始值，也不会自动解释结果。"
        case .knowledgeSearch: "App 只提供场景入口；文章正文、来源和更新仍由 mtfbook.com 承担。"
        }
    }
}

private struct ArchivePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme

    let destination: ArchiveDestination
    let snapshot: ArchiveSnapshot

    var body: some View {
        V25EditorPage(
            register: destination.eyebrow,
            eyebrow: "档案附页",
            title: destination.title,
            detail: destination.detail,
            cancel: dismiss.callAsFunction
        ) {
            V25SectionHeader(title: sectionTitle, detail: "结构预览")

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(format: "%02d", index + 1))
                            .font(theme.utility(10))
                            .foregroundStyle(index == 0 ? theme.vermilion : theme.blue)
                            .frame(width: 25, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                                .font(.body.weight(.black))
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(theme.indigo.opacity(0.64))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.paper)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.indigo).frame(height: 1)
                    }
                }
            }
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }

            V25PrivacyFooter(text: footerText)
        }
    }

    private var sectionTitle: String {
        switch destination {
        case .visitSummary, .rawExport: "将怎样处理"
        case .localStorage, .deleteAndReset: "边界与确认"
        case .unitConversion, .knowledgeSearch: "这个附页负责"
        }
    }

    private var rows: [(title: String, detail: String)] {
        switch destination {
        case .visitSummary:
            return [
                ("选择时间范围", "最近 30、90、180 天或自定义范围。"),
                ("选择包含内容", "当前方案、检查、旅程记录和仍想询问的问题。"),
                ("查看完整预览", "确认敏感内容与说明边界后，再生成 PDF。")
            ]
        case .rawExport:
            return [
                ("旅程", "当前有 \(snapshot.journeyCount) 笔。"),
                ("检查", "当前有 \(snapshot.labRecordCount) 项原始结果，来自 \(snapshot.labSampleCount) 个采样日。"),
                ("方案", "当前有 \(snapshot.regimenCount) 个历史版本。"),
                ("日期", "当前有 \(snapshot.profileCount) 个开始日与 \(snapshot.countdownCount) 个 Countdown。")
            ]
        case .localStorage:
            return [
                ("App 内记录", "当前使用本机 SwiftData 存储，不要求账号。"),
                ("系统与设备", "系统备份、锁屏和最近任务属于不同保护范围。"),
                ("导出文件", "离开 App 后，不再受 App 内保护。")
            ]
        case .deleteAndReset:
            return [
                ("先选对象", "记录、检查、方案版本和全部数据分别处理。"),
                ("查看影响", "删除前列出关联内容，不隐藏后果。"),
                ("再次确认", "没有预览和确认时，不执行删除。")
            ]
        case .unitConversion:
            return [
                ("保留原始值", "录入内容不会被换算值覆盖。"),
                ("说明换算关系", "显示输入单位、输出单位和规则版本。"),
                ("不解释结果", "换算只处理数值与单位。")
            ]
        case .knowledgeSearch:
            return [
                ("从当前任务进入", "优先呈现与记录、检查或方案有关的内容。"),
                ("显示来源版本", "保留机构、发布日期和查阅日期。"),
                ("打开完整文章", "需要深入阅读时进入 mtfbook.com。")
            ]
        }
    }

    private var footerText: String {
        switch destination {
        case .visitSummary:
            "摘要来自用户记录，不是处方、诊断证明或医生签署的病历"
        case .rawExport:
            "这里先确认导出范围；文件生成能力将在数据层实现后接入"
        case .localStorage:
            "温和呈现不等同于系统级隐私保护"
        case .deleteAndReset:
            "删除功能实现前必须逐项验证恢复与关联关系"
        case .unitConversion:
            "单位换算不提供个体化化验解读"
        case .knowledgeSearch:
            "完整资料、来源和更新由 mtfbook.com 承担"
        }
    }
}
