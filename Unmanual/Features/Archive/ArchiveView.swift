import SwiftUI

@MainActor
struct ArchiveView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var appReadActor

    @State private var destination: ArchiveDestination?
    @State private var snapshot = AppArchiveSnapshot.empty

    var body: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "LOCAL / ARCHIVE",
                    title: "档案",
                    subtitle: "整理、带走，也决定留下什么。",
                    status: SystemBackupDisclosure.statusLabel
                )

                V25SectionHeader(
                    title: "这台设备里的记录",
                    detail: snapshot.latestActivityLabel
                )

                ArchiveDossierCover(snapshot: snapshot)

                V25SectionHeader(title: "整理并带走", detail: "先预览，再生成")

#if DEBUG
                ArchiveExportDesk(
                    snapshot: snapshot,
                    summaryAction: { destination = .visitSummary },
                    exportAction: { destination = .rawExport },
                    importAction: { destination = .rawImport }
                )
#else
                ArchiveExportDesk(
                    snapshot: snapshot,
                    summaryAction: { destination = .visitSummary },
                    exportAction: {},
                    importAction: {}
                )
#endif

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

#if DEBUG
                V25PrivacyFooter(text: "\(SystemBackupDisclosure.compact)；JSON 导入导出仅为开发原型")
#else
                V25PrivacyFooter(text: SystemBackupDisclosure.compact)
#endif
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await refreshSnapshot() }
        .sheet(item: $destination) { destination in
            Group {
                switch destination {
#if DEBUG
                case .rawExport:
                    ArchiveDataExportSheet()
                case .rawImport:
                    ArchiveDataImportSheet()
#endif
                default:
                    ArchivePreviewSheet(destination: destination, snapshot: snapshot)
                }
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func refreshSnapshot() async {
        guard let appReadActor else { return }
        if let loaded = try? await appReadActor.archiveSnapshot() {
            snapshot = loaded
        }
    }
}

private struct ArchiveDossierCover: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let snapshot: AppArchiveSnapshot

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
                                .foregroundStyle(theme.vermilionText)
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
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 10)

                    Rectangle()
                        .fill(theme.indigo)
                        .frame(height: 1)
                        .padding(.vertical, 12)

                    ArchiveCounts(snapshot: snapshot, stacked: dynamicTypeSize.isAccessibilitySize)

                    Text(coverNote)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
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
            "本机个人档案，旅程 \(snapshot.journeyCount) 笔，检查记录 \(snapshot.labRecordCount) 项，方案 \(snapshot.regimenCount) 版，范围 \(snapshot.rangeLabel)"
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

    let snapshot: AppArchiveSnapshot
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
        ArchiveCount(value: snapshot.labRecordCount, label: "检查项", color: theme.blue)
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
                .foregroundStyle(theme.secondaryText)
        }
        .foregroundStyle(theme.indigoDeep)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(color).frame(width: 24, height: 3).offset(y: 5)
        }
    }
}

private struct ArchiveExportDesk: View {
    let snapshot: AppArchiveSnapshot
    let summaryAction: () -> Void
    let exportAction: () -> Void
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArchiveActionRow(
                kicker: "一页摘要",
                title: "整理就诊材料",
                detail: "选择时间范围和内容，先生成一份可核对的预览。",
                badge: "PDF",
                symbol: "arrow.up.right",
                style: .primary,
                action: summaryAction
            )

#if DEBUG
            ArchiveActionRow(
                kicker: "开发原型",
                title: "试验 JSON 导出",
                detail: snapshot.developmentExportItemCount == 0
                    ? "留下测试记录后，可以检查结构副本流程；这不是完整或安全备份。"
                    : "将 \(snapshot.developmentExportItemCount) 条原型可支持记录写入结构副本；这不是完整或安全备份。",
                badge: "JSON",
                symbol: "arrow.up.right",
                style: .secondary,
                action: exportAction
            )

            ArchiveActionRow(
                kicker: "开发原型",
                title: "试验 JSON 导入",
                detail: "当前只按 ID 试验写入，尚无 dataset、digest 或正式冲突处理；只用于开发数据。",
                badge: "JSON",
                symbol: "arrow.down.left",
                style: .secondary,
                action: importAction
            )
#endif
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
    let symbol: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kicker.uppercased())
                        .font(theme.utility(9))
                        .tracking(0.8)
                        .foregroundStyle(
                            style == .primary ? theme.mustard : theme.vermilionText
                        )
                    Text(title)
                        .font(theme.display(23, relativeTo: .title3))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 14) {
                    Text(badge)
                        .font(theme.utility(10))
                        .tracking(0.8)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 24)
                        .overlay { Rectangle().stroke(foreground, lineWidth: 1) }

                    Image(systemName: symbol)
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
                status: "当前：\(SystemBackupDisclosure.statusLabel)",
                color: theme.blue,
                accessibilityIdentifier: "archive.localStorage",
                action: storageAction
            )
            ArchiveLedgerRow(
                title: "删除与重置",
                detail: "逐项检查记录，不提供含糊的“一键无痕”承诺。",
                status: "逐项处理",
                color: theme.vermilion,
                accessibilityIdentifier: "archive.deleteAndReset",
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
    let accessibilityIdentifier: String
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
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(status)
                        .font(theme.utility(9))
                        .tracking(0.4)
                        .foregroundStyle(theme.secondaryText)
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
        .accessibilityIdentifier(accessibilityIdentifier)
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
                    .foregroundStyle(theme.vermilionText)
                    .frame(width: 34, alignment: .leading)
                Text(title)
                    .font(.subheadline.weight(.black))
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.black))
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.secondaryText).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
    }
}

private enum ArchiveDestination: String, Identifiable {
    case visitSummary
#if DEBUG
    case rawExport
    case rawImport
#endif
    case localStorage
    case deleteAndReset
    case unitConversion
    case knowledgeSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visitSummary: "整理就诊材料"
#if DEBUG
        case .rawExport: "导出 App 数据"
        case .rawImport: "导入 App 数据"
#endif
        case .localStorage: "本地存储说明"
        case .deleteAndReset: "删除与重置"
        case .unitConversion: "单位换算"
        case .knowledgeSearch: "查找资料"
        }
    }

    var eyebrow: String {
        switch self {
        case .visitSummary: "SUMMARY / PREVIEW"
#if DEBUG
        case .rawExport: "DATA / EXPORT"
        case .rawImport: "DATA / IMPORT"
#endif
        case .localStorage: "LOCAL / PRIVACY"
        case .deleteAndReset: "DATA / CONTROL"
        case .unitConversion: "UTILITY / CONVERT"
        case .knowledgeSearch: "MTFBOOK / SEARCH"
        }
    }

    var detail: String {
        switch self {
        case .visitSummary: "选择时间范围和内容，整理成一页摘要。"
#if DEBUG
        case .rawExport: "开发期结构副本原型，不是完整或安全备份。"
        case .rawImport: "开发期按 ID 写入原型，正式冲突合同尚未实现。"
#endif
        case .localStorage: "这里会逐项说明本机数据、系统备份和导出文件之间的边界。"
        case .deleteAndReset: "删除前先列出准确对象和影响范围，并再次确认。"
        case .unitConversion: "输入数值与单位，查看并保存换算结果。"
        case .knowledgeSearch: "App 只提供场景入口；文章正文、来源和更新仍由 mtfbook.com 承担。"
        }
    }
}

private struct ArchivePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme

    let destination: ArchiveDestination
    let snapshot: AppArchiveSnapshot

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
                            .foregroundStyle(
                                index == 0 ? theme.vermilionText : theme.blueText
                            )
                            .frame(width: 25, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                                .font(.body.weight(.black))
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
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
                .accessibilityIdentifier("archive.preview.footer")
        }
    }

    private var sectionTitle: String {
        switch destination {
        case .visitSummary: "将怎样处理"
#if DEBUG
        case .rawExport, .rawImport: "将怎样处理"
#endif
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
                ("查看完整预览", "确认所选内容后，再生成 PDF。")
            ]
#if DEBUG
        case .rawExport:
            return [
                ("旅程", "当前有 \(snapshot.journeyCount) 笔。"),
                ("检查", "当前有 \(snapshot.labRecordCount) 项原始结果。"),
                ("方案", "当前有 \(snapshot.regimenCount) 个历史版本。"),
                ("日期", "当前有 \(snapshot.profileCount) 个开始日与 \(snapshot.countdownCount) 个 Countdown。")
            ]
        case .rawImport:
            return [
                ("选择测试文件", "只接受当前原型生成的兼容 JSON。"),
                ("核对清单", "写入前展示每一类记录数量。"),
                ("原型限制", "当前按 ID 写入；dataset、digest 和正式冲突处理尚未实现。")
            ]
#endif
        case .localStorage:
            return [
                ("App 内记录", SystemBackupDisclosure.summary),
                ("上传与同步", SystemBackupDisclosure.networkBoundary),
                ("系统备份", SystemBackupDisclosure.systemBackupBoundary),
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
                ("保存换算结果", "原始记录与换算结果分别显示。")
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
            "把选定范围内的记录整理到同一页"
#if DEBUG
        case .rawExport:
            "仅供 DEBUG 验证结构，不作为恢复承诺"
        case .rawImport:
            "仅使用开发数据；正式冲突处理尚未实现"
#endif
        case .localStorage:
            "系统备份由设备管理，不等于 App 主动上传或同步"
        case .deleteAndReset:
            "删除功能实现前必须逐项验证恢复与关联关系"
        case .unitConversion:
            "换算结果与原始记录分开保存"
        case .knowledgeSearch:
            "完整资料、来源和更新由 mtfbook.com 承担"
        }
    }
}
