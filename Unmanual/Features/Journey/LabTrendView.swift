import Charts
import SwiftUI

enum LabTrendReadContext: Equatable {
    case firstPage
    case olderPage
}

enum LabTrendReadFailureAction: Equatable {
    case ignore
    case retryable(String)
    case requireRecovery(String)
}

enum LabTrendReadFailurePolicy {
    static func action(
        for error: Error,
        context: LabTrendReadContext,
        requestIsCurrent: Bool,
        gentleModeEnabled: Bool = false
    ) -> LabTrendReadFailureAction {
        guard requestIsCurrent else { return .ignore }
        if error as? AppDataFailure == .corruptionSuspected {
            let title = LabSurfaceDisplayPolicy.copy(
                gentleModeEnabled: gentleModeEnabled
            ).trendTitle
            return .requireRecovery(
                "\(title)没有通过本地完整性检查。App 将进入恢复模式，不会把损坏资料显示成空状态。"
            )
        }
        switch context {
        case .firstPage:
            return .retryable(
                "暂时无法读取这组趋势，原始记录没有被修改。"
            )
        case .olderPage:
            return .retryable(
                "更早的记录暂时无法读取；已经显示的内容没有被修改。"
            )
        }
    }
}

@MainActor
struct LabTrendView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var reader
    @Environment(\.attachmentIntegrityFailureHandler)
    private var integrityFailureHandler
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let seed: LabResultSnapshot
    let gentleModeEnabled: Bool

    @State private var points: [LabTrendPoint] = []
    @State private var compatibleUnits: [LabUnitRule] = []
    @State private var selectedUnitID: String?
    @State private var nextCursor: LabTrendCursor?
    @State private var excludedCount = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var requestEpoch = TimelineRequestEpochGate()
    @State private var errorMessage: String?
    @State private var paginationErrorMessage: String?
    private let automaticallyLoads: Bool

    init(
        seed: LabResultSnapshot,
        initialPage: LabTrendPage? = nil,
        startsLoading: Bool = true,
        initialErrorMessage: String? = nil,
        initialPaginationErrorMessage: String? = nil,
        automaticallyLoads: Bool = true,
        gentleModeEnabled: Bool = false
    ) {
        self.seed = seed
        self.gentleModeEnabled = gentleModeEnabled
        _points = State(initialValue: initialPage?.points ?? [])
        _compatibleUnits = State(
            initialValue: initialPage?.compatibleUnits ?? []
        )
        _nextCursor = State(initialValue: initialPage?.nextCursor)
        _excludedCount = State(
            initialValue:
                initialPage?.excludedIncompatibleUnitCount ?? 0
        )
        _isLoading = State(initialValue: startsLoading)
        _errorMessage = State(initialValue: initialErrorMessage)
        _paginationErrorMessage = State(
            initialValue: initialPaginationErrorMessage
        )
        self.automaticallyLoads = automaticallyLoads
    }

    var body: some View {
        let surfaceCopy = LabSurfaceDisplayPolicy.copy(
            gentleModeEnabled: gentleModeEnabled
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                V25PageHeader(
                    register: surfaceCopy.trendRegister,
                    title: surfaceCopy.trendTitle,
                    subtitle: seed.itemNameSnapshot,
                    status: "\(points.count) 条"
                )

                Text(
                    "只比较同一个项目身份和同一检测方法。原始值始终保留；换算只改变本页显示，不修改记录或报告参考区间。"
                )
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                if isLoading {
                    ProgressView("正在整理本地记录…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityIdentifier("labTrend.loading")
                } else if let errorMessage {
                    errorState(errorMessage)
                } else {
                    unitSelector
                    if excludedCount > 0 {
                        Text(
                            "另有 \(excludedCount) 条记录的单位无法按当前规则纳入；原记录没有被修改。"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilionText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("labTrend.excludedUnits")
                    }
                    trendContent
                }

                V25PrivacyFooter(text: SystemBackupDisclosure.compact)
            }
            .padding(V25Theme.pagePadding)
            .frame(maxWidth: V25Theme.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(theme.rice.ignoresSafeArea())
        .navigationTitle(surfaceCopy.trendTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedUnitID) {
            guard automaticallyLoads else { return }
            await reload()
        }
    }

    @ViewBuilder
    private var unitSelector: some View {
        if compatibleUnits.isEmpty {
            Text("当前单位没有可用的确定性换算规则；以下按报告原单位展示。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("labTrend.noConversion")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("显示单位")
                    .font(theme.utility(10))
                    .tracking(0.7)
                    .foregroundStyle(theme.vermilionText)
                Picker("显示单位", selection: $selectedUnitID) {
                    Text("原单位 \(seed.unitOriginal)")
                        .tag(nil as String?)
                    ForEach(compatibleUnits) { unit in
                        Text(unit.symbol).tag(Optional(unit.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("labTrend.unitPicker")
            }
            .padding(12)
            .background(theme.paper)
            .overlay {
                Rectangle().stroke(theme.indigo, lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private var trendContent: some View {
        if points.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("还没有可比较的记录")
                    .font(theme.display(24, relativeTo: .title3))
                Text("同一项目、同一检测方法和当前单位的记录会显示在这里。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .accessibilityIdentifier("labTrend.empty")
        } else {
            let exactPoints = points.filter(\.isExactPlotPoint)
            if !dynamicTypeSize.isAccessibilitySize,
               !exactPoints.isEmpty {
                LabTrendChart(points: exactPoints)
            }

            if exactPoints.count == 1 {
                Text("目前只有一个精确数值点；台账会保留记录，但暂时不能形成连续趋势。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            if points.contains(where: { !$0.isExactPlotPoint }) {
                Text("带 <、≤、> 或 ≥ 的结果是边界，不作为精确点连接折线。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.indigo)
            }

            V25SectionHeader(
                title: "原始记录台账",
                detail: "新到旧 · \(points.count) 条"
            )
            ForEach(points) { point in
                LabTrendLedgerRow(point: point)
            }

            if let paginationErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(paginationErrorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilionText)
                    Button("重试读取更早记录") {
                        Task { await loadMore() }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("labTrend.retryLoadMore")
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier("labTrend.paginationError")
            }

            if nextCursor != nil {
                Button {
                    Task { await loadMore() }
                } label: {
                    if isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Text("加载更早的记录")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(V25SecondaryButtonStyle())
                .disabled(isLoadingMore)
                .accessibilityIdentifier("labTrend.loadMore")
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.vermilionText)
            Button("重新读取") {
                Task { await reload() }
            }
            .buttonStyle(V25SecondaryButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(theme.vermilion, lineWidth: 1.5)
        }
        .accessibilityIdentifier("labTrend.error")
    }

    private func request() -> LabTrendRequest {
        LabTrendRequest(
            itemDefinitionID: seed.itemDefinitionID,
            assayOrVariantOriginal: seed.assayOrVariantOriginal,
            sourceUnitOriginal: seed.unitOriginal,
            displayUnitID: selectedUnitID
        )
    }

    private func reload() async {
        guard let reader else {
            isLoading = false
            errorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        let requestToken = requestEpoch.beginRefresh()
        let pageRequest = request()
        isLoading = true
        isLoadingMore = false
        points = []
        nextCursor = nil
        excludedCount = 0
        errorMessage = nil
        paginationErrorMessage = nil
        defer {
            if requestEpoch.isCurrent(requestToken) {
                isLoading = false
            }
        }
        do {
            let page = try await reader.labTrendPage(pageRequest)
            guard requestEpoch.isCurrent(requestToken) else { return }
            points = page.points
            compatibleUnits = page.compatibleUnits
            nextCursor = page.nextCursor
            excludedCount = page.excludedIncompatibleUnitCount
        } catch {
            applyReadFailure(
                error,
                context: .firstPage,
                requestToken: requestToken
            )
        }
    }

    private func loadMore() async {
        guard !isLoadingMore,
              let reader,
              let cursor = nextCursor else { return }
        let requestToken = requestEpoch.currentToken
        let pageRequest = request()
        isLoadingMore = true
        paginationErrorMessage = nil
        defer {
            if requestEpoch.isCurrent(requestToken) {
                isLoadingMore = false
            }
        }
        do {
            let page = try await reader.labTrendPage(
                pageRequest,
                after: cursor
            )
            guard requestEpoch.isCurrent(requestToken) else { return }
            let existingIDs = Set(points.map(\.id))
            points.append(
                contentsOf: page.points.filter {
                    !existingIDs.contains($0.id)
                }
            )
            nextCursor = page.nextCursor
            excludedCount = page.excludedIncompatibleUnitCount
        } catch {
            applyReadFailure(
                error,
                context: .olderPage,
                requestToken: requestToken
            )
        }
    }

    private func applyReadFailure(
        _ error: Error,
        context: LabTrendReadContext,
        requestToken: Int
    ) {
        switch LabTrendReadFailurePolicy.action(
            for: error,
            context: context,
            requestIsCurrent: requestEpoch.isCurrent(requestToken),
            gentleModeEnabled: gentleModeEnabled
        ) {
        case .ignore:
            return
        case let .retryable(message):
            if context == .olderPage {
                paginationErrorMessage = message
            } else {
                errorMessage = message
            }
        case let .requireRecovery(message):
            points = []
            nextCursor = nil
            excludedCount = 0
            paginationErrorMessage = nil
            errorMessage = message
            integrityFailureHandler?()
        }
    }
}

private struct LabTrendChart: View {
    @Environment(AppTheme.self) private var theme

    let points: [LabTrendPoint]

    var body: some View {
        Chart(points.reversed()) { point in
            if let value = Double(
                point.displayCanonicalDecimalString
            ), value.isFinite {
                LineMark(
                    x: .value("采样时间", point.timestamp.instant),
                    y: .value("显示数值", value)
                )
                .foregroundStyle(theme.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(
                    x: .value("采样时间", point.timestamp.instant),
                    y: .value("显示数值", value)
                )
                .foregroundStyle(theme.vermilion)
                .symbolSize(58)
            }
        }
        .frame(height: 190)
        .padding(12)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 1.5)
        }
        .accessibilityHidden(true)
        .transaction { $0.animation = nil }
    }
}

private struct LabTrendLedgerRow: View {
    @Environment(AppTheme.self) private var theme

    let point: LabTrendPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(point.timestamp.localDate.unmanualFullDateText)
                    .font(.headline.monospacedDigit())
                Spacer(minLength: 8)
                Text(point.rawValueOriginal + " " + point.unitOriginal)
                    .font(.headline.weight(.black))
                    .multilineTextAlignment(.trailing)
            }
            if let rule = point.conversionRuleID,
               let version = point.conversionRuleVersion {
                Text(
                    "显示为 \(point.displayCanonicalDecimalString) \(point.displayUnit) · \(rule) · \(version)"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.indigo)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let variant = point.assayOrVariantOriginal {
                Text(
                    variant.isEmpty
                        ? "检测方法字段为空"
                        : "检测方法 / 变体：\(variant)"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            } else {
                Text("未提供检测方法字段")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Text(
                regimenAssociationText
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.45)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var value =
            "\(point.timestamp.localDate.unmanualFullDateText)，原始值 \(point.rawValueOriginal) \(point.unitOriginal)"
        if point.conversionRuleID != nil {
            value +=
                "，换算显示 \(point.displayCanonicalDecimalString) \(point.displayUnit)"
        }
        if point.comparator != nil {
            value += "，这是边界值，不是精确点"
        }
        switch point.assayOrVariantOriginal {
        case nil:
            value += "，未提供检测方法字段"
        case .some(""):
            value += "，检测方法字段为空"
        case let .some(variant):
            value += "，检测方法或变体 \(variant)"
        }
        value += "，\(regimenAssociationText)"
        return value
    }

    private var regimenAssociationText: String {
        switch point.associationState {
        case .resolved:
            return point.regimenVersionID == nil
                ? "未关联方案"
                : "保留采样时的方案关联"
        case .missing:
            return "未找到可关联的当时方案，需要核对"
        case .ambiguous:
            return "找到多个候选方案，需要核对"
        }
    }
}
