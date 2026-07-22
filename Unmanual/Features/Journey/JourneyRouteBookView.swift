import SwiftUI

@MainActor
struct JourneyRouteBookView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appReadActor) private var appReadActor

    @State private var entries: [JourneyEntrySnapshot] = []
    @State private var regimenCodes: [UUID: String] = [:]
    @State private var nextCursor: JourneyPageCursor?
    @State private var isLoadingPage = false
    @State private var loadErrorMessage: String?

    private let refreshToken: Int
    private let recordAction: () -> Void

    init(refreshToken: Int = 0, recordAction: @escaping () -> Void) {
        self.refreshToken = refreshToken
        self.recordAction = recordAction
    }

    var body: some View {
        let items = routeItems

        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "JOURNEY / ROUTE",
                    title: "旅程",
                    subtitle: "沿着事实回看，不要求连续打卡。",
                    status: entries.isEmpty
                        ? "尚无路线"
                        : (nextCursor == nil ? "\(entries.count) 个停靠点" : "最近 \(entries.count) 个停靠点")
                )

                JourneyPageRecordAction(action: recordAction)
                    .padding(.top, 14)

                if items.isEmpty {
                    JourneyRouteEmpty()
                        .padding(.top, 16)
                } else {
                    route(items)
                        .padding(.top, 16)
                }

                if nextCursor != nil {
                    Button(isLoadingPage ? "正在读取…" : "加载更早记录", action: loadOlderPage)
                        .buttonStyle(V25SecondaryButtonStyle())
                        .disabled(isLoadingPage)
                        .padding(.top, 18)
                        .accessibilityIdentifier("journey.loadOlder")
                }

                if let loadErrorMessage {
                    Text(loadErrorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilion)
                        .padding(.top, 10)
                }

                V25PrivacyFooter(text: "路线只由你的本地记录组成")
                    .padding(.bottom, 42)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: refreshToken) { await loadFirstPage() }
    }

    @ViewBuilder
    private func route(_ items: [JourneyRouteItem]) -> some View {
        LazyVStack(spacing: 0) {
            JourneyNowPoint(latestEntryDateText: items.first?.entry.recordedFullDateText)

            ForEach(items) { item in
                if item.startsContext {
                    JourneyContextWaypoint(contextLabel: item.contextLabel)
                }

                JourneyRouteStop(item: item)
            }
        }
        .background(alignment: .leading) {
            if !dynamicTypeSize.isAccessibilitySize {
                Rectangle()
                    .fill(theme.vermilion)
                    .frame(width: 2)
                    .padding(.leading, 67)
                    .padding(.vertical, 24)
                    .accessibilityHidden(true)
            }
        }
    }

    private var routeItems: [JourneyRouteItem] {
        return entries.enumerated().map { index, entry in
            let regimenCode = entry.regimenVersionID.flatMap { regimenCodes[$0] }
            let previousRegimenCode: String? = {
                guard index > 0 else { return nil }
                return entries[index - 1].regimenVersionID.flatMap { regimenCodes[$0] }
            }()
            let startsContext = index == 0 || regimenCode != previousRegimenCode
            let gapAfter: Int? = {
                guard entries.indices.contains(index + 1),
                      let currentDay = entry.recordedLocalDate(),
                      let olderDay = entries[index + 1].recordedLocalDate() else {
                    return nil
                }
                return max(0, currentDay.days(since: olderDay) ?? 0)
            }()

            return JourneyRouteItem(
                entry: entry,
                regimenCode: regimenCode,
                startsContext: startsContext,
                gapAfter: gapAfter,
                isLatest: index == 0
            )
        }
    }

    private func loadFirstPage() async {
        guard let appReadActor, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            let page = try await appReadActor.journeyPage(after: nil)
            entries = page.entries
            regimenCodes = page.regimenCodes
            nextCursor = page.nextCursor
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = "暂时无法读取旅程，原记录没有被修改。"
        }
    }

    private func loadOlderPage() {
        guard let appReadActor, let cursor = nextCursor, !isLoadingPage else { return }
        isLoadingPage = true
        Task {
            defer { isLoadingPage = false }
            do {
                let page = try await appReadActor.journeyPage(after: cursor)
                let existingIDs = Set(entries.map(\.id))
                entries.append(contentsOf: page.entries.filter { !existingIDs.contains($0.id) })
                regimenCodes.merge(page.regimenCodes) { current, _ in current }
                nextCursor = page.nextCursor
                loadErrorMessage = nil
            } catch {
                loadErrorMessage = "暂时无法读取更早的记录，请稍后重试。"
            }
        }
    }
}

private struct JourneyRouteItem: Identifiable {
    let entry: JourneyEntrySnapshot
    let regimenCode: String?
    let startsContext: Bool
    let gapAfter: Int?
    let isLatest: Bool

    var id: UUID { entry.id }
    var contextLabel: String { regimenCode.map { "方案 \($0)" } ?? "未关联方案" }
}

private struct JourneyNowPoint: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let latestEntryDateText: String?

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 7) {
                Text("此刻 · \(Date().formatted(.dateTime.month().day()))")
                    .font(theme.utility(11))
                    .tracking(0.7)
                    .foregroundStyle(theme.mustard)
                Text("从这里向过去回看")
                    .font(theme.display(25, relativeTo: .title2))
                if let latestEntryDateText {
                    Text("最近一次留下：\(latestEntryDateText)")
                        .font(.caption)
                        .foregroundStyle(theme.paper.opacity(0.7))
                }

            }
            .foregroundStyle(theme.paper)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.indigoDeep)
            .accessibilityElement(children: .contain)
        } else {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                        .font(theme.utility(12))
                        .monospacedDigit()
                    Text("今天")
                        .font(theme.utility(9))
                        .tracking(0.7)
                        .foregroundStyle(theme.indigo.opacity(0.56))
                }
                .frame(width: 50, alignment: .leading)

                JourneyRouteNode(kind: .now)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text("此刻")
                        .font(theme.utility(10))
                        .tracking(0.9)
                        .foregroundStyle(theme.mustard)
                    Text("从这里向过去回看")
                        .font(theme.display(23, relativeTo: .title3))
                    if let latestEntryDateText {
                        Text("最近一次留下：\(latestEntryDateText)")
                            .font(.caption)
                            .foregroundStyle(theme.paper.opacity(0.68))
                    }

                }
                .foregroundStyle(theme.paper)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.indigoDeep)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct JourneyContextWaypoint: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let contextLabel: String

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text("方案上下文")
                    .font(theme.utility(10))
                    .tracking(0.8)
                    .foregroundStyle(theme.vermilion)
                Text(contextLabel)
                    .font(.headline.weight(.black))
                Text("以下记录保留这一段的方案关联")
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.62))
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .center, spacing: 0) {
                Text("方案")
                    .font(theme.utility(9))
                    .tracking(0.8)
                    .foregroundStyle(theme.indigo.opacity(0.55))
                    .frame(width: 50, alignment: .leading)

                JourneyRouteNode(kind: .context)
                    .frame(width: 34)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(contextLabel)
                        .font(.caption.weight(.black))
                    Spacer(minLength: 8)
                    Text("以下记录")
                        .font(theme.utility(9))
                        .tracking(0.7)
                        .foregroundStyle(theme.indigo.opacity(0.56))
                }
                .foregroundStyle(theme.indigoDeep)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(theme.paper)
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                .shadow(color: theme.mustard.opacity(0.65), radius: 0, x: 4, y: 4)
            }
            .padding(.vertical, 15)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(contextLabel)，以下记录保留这一段的方案关联")
        }
    }
}

private struct JourneyRouteStop: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: JourneyRouteItem

    var body: some View {
        VStack(spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityStop
            } else {
                compactStop
            }

            if let gapAfter = item.gapAfter {
                JourneyRouteGap(days: gapAfter)
            }
        }
    }

    private var compactStop: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.recordedMonthDayText)
                    .font(theme.utility(12))
                    .monospacedDigit()
                Text(item.entry.recordedWeekdayText)
                    .font(theme.utility(9))
                    .tracking(0.5)
                    .foregroundStyle(theme.indigo.opacity(0.52))
            }
            .frame(width: 50, alignment: .leading)
            .padding(.top, 15)

            JourneyRouteNode(kind: item.isLatest ? .latest : .record)
                .frame(width: 34)
                .padding(.top, 17)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.isLatest ? "最近 · \(item.entry.kind.title)" : item.entry.kind.title)
                        .font(theme.utility(10))
                        .tracking(0.7)
                        .foregroundStyle(theme.vermilion)

                    Spacer(minLength: 8)

                    if let regimenCode = item.regimenCode {
                        Text(regimenCode)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(theme.indigo.opacity(0.5))
                    }
                }

                Text(item.entry.text)
                    .font(theme.display(item.isLatest ? 22 : 19, relativeTo: .body))
                    .foregroundStyle(theme.indigoDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, item.isLatest ? 12 : 0)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(item.isLatest ? theme.blue.opacity(0.2) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.indigo.opacity(item.isLatest ? 1 : 0.32))
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityStop: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.entry.recordedMonthDayWeekdayText)
                    .font(.headline.monospacedDigit())
                Spacer(minLength: 8)
                if let regimenCode = item.regimenCode {
                    Text("方案 \(regimenCode)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.indigo.opacity(0.58))
                }
            }

            Text(item.isLatest ? "最近 · \(item.entry.kind.title)" : item.entry.kind.title)
                .font(theme.utility(11))
                .tracking(0.7)
                .foregroundStyle(theme.vermilion)

            Text(item.entry.text)
                .font(theme.display(20, relativeTo: .body))
                .foregroundStyle(theme.indigoDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, item.isLatest ? 13 : 0)
        .background(item.isLatest ? theme.blue.opacity(0.2) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.42)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let latest = item.isLatest ? "最近一条，" : ""
        let date = item.entry.recordedFullDateText
        let regimen = item.regimenCode.map { "，方案 \($0)" } ?? ""
        return "\(latest)\(date)，\(item.entry.kind.title)\(regimen)，\(item.entry.text)"
    }
}

private struct JourneyRouteGap: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let days: Int

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            if days > 1 {
                Text("相隔 \(days) 日")
                    .font(theme.utility(10))
                    .tracking(0.7)
                    .foregroundStyle(theme.indigo.opacity(0.52))
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("与下一条记录相隔 \(days) 天")
            } else {
                Color.clear.frame(height: 8)
            }
        } else {
            HStack(spacing: 0) {
                Color.clear.frame(width: 84)

                Group {
                    if days > 1 {
                        Text("相隔 \(days) 日")
                            .font(theme.utility(9))
                            .tracking(0.7)
                            .foregroundStyle(theme.indigo.opacity(0.48))
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: gapHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(days > 1 ? "与下一条记录相隔 \(days) 天" : "")
            .accessibilityHidden(days <= 1)
        }
    }

    private var gapHeight: CGFloat {
        guard days > 0 else { return 8 }
        return min(16 + CGFloat(days) * 5, 38)
    }
}

private struct JourneyRouteNode: View {
    @Environment(AppTheme.self) private var theme

    enum Kind {
        case now
        case context
        case latest
        case record
    }

    let kind: Kind

    var body: some View {
        Rectangle()
            .fill(fillColor)
            .frame(width: nodeSize, height: nodeSize)
            .overlay {
                Rectangle().stroke(strokeColor, lineWidth: 2)
            }
            .rotationEffect(.degrees(45))
            .accessibilityHidden(true)
    }

    private var nodeSize: CGFloat {
        kind == .now ? 14 : 10
    }

    private var fillColor: Color {
        switch kind {
        case .now: theme.indigoDeep
        case .context: theme.mustard
        case .latest: theme.vermilion
        case .record: theme.paper
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .now, .context, .latest: fillColor
        case .record: theme.indigo
        }
    }
}

private struct JourneyRouteEmpty: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                    .font(theme.utility(12))
                    .monospacedDigit()
                Text("今天")
                    .font(theme.utility(9))
                    .foregroundStyle(theme.indigo.opacity(0.54))
            }
            .frame(width: 50, alignment: .leading)

            VStack(spacing: 0) {
                JourneyRouteNode(kind: .now)
                Rectangle()
                    .fill(theme.vermilion)
                    .frame(width: 2, height: 78)
                Rectangle()
                    .stroke(theme.indigo, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(45))
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 9) {
                Text("路线从今天开始。")
                    .font(theme.display(27, relativeTo: .title2))
                    .foregroundStyle(theme.indigoDeep)
                Text("点上方“记录旅程”，真正想留下什么时再记一句。这里不会催你连续打卡。")
                    .font(.body)
                    .foregroundStyle(theme.indigo.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 12)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("尚无记录。路线从今天开始。点记录旅程，真正想留下什么时再记一句。")
    }
}
