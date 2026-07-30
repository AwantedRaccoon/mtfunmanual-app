import Accessibility
import SwiftUI

struct RegimenAnalysisAccessibilityUpdate: Equatable {
    let semanticKey: String
    let announcement: String

    init(snapshot: RegimenAnalysisSnapshot) {
        switch snapshot.semanticStatus {
        case .unanswered:
            semanticKey = "unanswered"
            announcement =
                "分析状态已更新：请先回答仍未选择的安全边界。"
        case .ready:
            semanticKey = "ready"
            announcement =
                "分析状态已更新：可以显示教育性讨论材料。"
        case .limited:
            semanticKey = "limited"
            announcement =
                "分析状态已更新：当前只能显示有限内容，不会按名称猜测未知成分。"
        case .stopped:
            let primaryStop = snapshot.stopCards.first
            semanticKey = "stopped:" + (primaryStop?.id ?? "unknown")
            announcement =
                "分析状态已更新：已停止 App 分析。"
                + (primaryStop.map { " \($0.title)。" } ?? "")
        }
    }
}

struct RegimenAnalysisView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let regimen: CoreRegimenVersionSnapshot
    let isHistorical: Bool
    let loadState: RegimenAnalysisLoadState

    @State private var ageBand: RegimenAnalysisAgeBand?
    @State private var pregnancyPossibility: RegimenAnalysisAnswer?
    @State private var acuteConcern: RegimenAnalysisAnswer?
    @State private var knownVteHistoryOrRisk: RegimenAnalysisAnswer?
    @State private var knownMeningiomaHistory: RegimenAnalysisAnswer?
    @State private var pendingSource: RegimenAnalysisSourceCard?

    init(
        regimen: CoreRegimenVersionSnapshot,
        isHistorical: Bool? = nil,
        loadState: RegimenAnalysisLoadState = RegimenAnalysisContent.loadState,
        initialSafetyContext: RegimenAnalysisSafetyContext = .unanswered
    ) {
        self.regimen = regimen
        self.isHistorical =
            isHistorical ?? (regimen.effectiveEndDate != nil)
        self.loadState = loadState
        _ageBand = State(initialValue: initialSafetyContext.ageBand)
        _pregnancyPossibility = State(
            initialValue: initialSafetyContext.pregnancyPossibility
        )
        _acuteConcern = State(
            initialValue: initialSafetyContext.acuteConcern
        )
        _knownVteHistoryOrRisk = State(
            initialValue: initialSafetyContext.knownVteHistoryOrRisk
        )
        _knownMeningiomaHistory = State(
            initialValue: initialSafetyContext.knownMeningiomaHistory
        )
    }

    private var request: RegimenAnalysisRequestV1 {
        RegimenAnalysisRequestV1(regimen: regimen)
    }

    private var safetyContext: RegimenAnalysisSafetyContext {
        RegimenAnalysisSafetyContext(
            ageBand: ageBand,
            pregnancyPossibility: pregnancyPossibility,
            acuteConcern: acuteConcern,
            knownVteHistoryOrRisk: knownVteHistoryOrRisk,
            knownMeningiomaHistory: knownMeningiomaHistory
        )
    }

    private var matchingFlags: Set<RegimenAnalysisSafetyFlag> {
        guard let pack = loadState.pack else { return [] }
        let profiles: [String: RegimenAnalysisIngredientProfile] =
            pack.ingredientProfiles.reduce(into: [:]) { result, profile in
            if result[profile.ingredientID] == nil {
                result[profile.ingredientID] = profile
            }
        }
        return Set(
            request.ingredientIDs
                .compactMap { profiles[$0] }
                .flatMap(\.safetyFlags)
        )
    }

    private var accessibilityUpdate: RegimenAnalysisAccessibilityUpdate? {
        guard let pack = loadState.pack else { return nil }
        return RegimenAnalysisAccessibilityUpdate(
            snapshot: RegimenAnalysisEngine.evaluate(
                request: request,
                safetyContext: safetyContext,
                pack: pack
            )
        )
    }

    var body: some View {
        NavigationStack {
            V25Page {
                VStack(alignment: .leading, spacing: 0) {
                    V25PageHeader(
                        register: "REGIMEN / REVIEW",
                        title: "方案分析",
                        subtitle: "整理记录与公开讨论主题，不判断方案是否适合你。",
                        status: regimen.code
                    )

                    if isHistorical {
                        let historyMessage =
                            "这是历史方案。页面使用当前规则包重新整理，不是永久保存的历史分析结论。"
                        VStack(alignment: .leading) {
                            Text(historyMessage)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.indigoDeep)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                        .padding(12)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .background(theme.mustard.opacity(0.18))
                        .overlay {
                            Rectangle().stroke(
                                theme.indigo,
                                lineWidth: 1.5
                            )
                        }
                        .padding(.bottom, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(historyMessage)
                        .accessibilityIdentifier(
                            "analysis.historyContext"
                        )
                    }

                    RegimenAnalysisSummarySection(request: request)

                    switch loadState {
                    case let .available(pack):
                        let snapshot = RegimenAnalysisEngine.evaluate(
                            request: request,
                            safetyContext: safetyContext,
                            pack: pack
                        )
                        RegimenAnalysisStatusLocator(
                            status: snapshot.semanticStatus
                        )
                        safetySection
                        RegimenAnalysisResultSection(
                            snapshot: snapshot,
                            openSource: { pendingSource = $0 }
                        )
                    case let .unavailable(reason):
                        RegimenAnalysisUnavailableView(reason: reason)
                    }
                }
                .padding(.bottom, 36)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        clearTransientSafetyAnswers()
                        dismiss()
                    }
                        .accessibilityIdentifier("analysis.close")
                }
            }
        }
        .sheet(item: $pendingSource) { source in
            RegimenAnalysisExternalSourceBoundary(source: source)
                .environment(theme)
        }
        .onChange(of: accessibilityUpdate) { previous, current in
            guard let current,
                  previous?.semanticKey != current.semanticKey else {
                return
            }
            AccessibilityNotification.Announcement(
                current.announcement
            ).post()
        }
        .onDisappear(perform: clearTransientSafetyAnswers)
    }

    private func clearTransientSafetyAnswers() {
        ageBand = nil
        pregnancyPossibility = nil
        acuteConcern = nil
        knownVteHistoryOrRisk = nil
        knownMeningiomaHistory = nil
    }

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            V25SectionHeader(
                title: "安全边界",
                detail: "仅本页内存 · 关闭后不保存"
            )

            Text("请按你已经知道的事实选择；可以选“不确定”或“不适用”。App 不会从身份或其他记录推断答案。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            RegimenAnalysisChoiceRow(
                title: "年龄范围",
                choices: [
                    .init(value: .adult, label: "18 岁及以上", column: 0),
                    .init(value: .under18, label: "未满 18 岁", column: 1),
                    .init(value: .unknown, label: "不确定", column: 3)
                ],
                selection: $ageBand,
                identifierPrefix: "analysis.age"
            )

            RegimenAnalysisChoiceRow(
                title: "妊娠可能是否适用",
                choices: [
                    .init(value: .no, label: "没有", column: 0),
                    .init(value: .yes, label: "可能有", column: 1),
                    .init(
                        value: .notApplicable,
                        label: "不适用",
                        column: 2
                    ),
                    .init(value: .unknown, label: "不确定", column: 3)
                ],
                selection: $pregnancyPossibility,
                identifierPrefix: "analysis.pregnancy"
            )

            RegimenAnalysisChoiceRow(
                title: "是否正因急性情况寻求判断",
                choices: [
                    .init(value: .no, label: "没有", column: 0),
                    .init(value: .yes, label: "是", column: 1),
                    .init(value: .unknown, label: "不确定", column: 3)
                ],
                selection: $acuteConcern,
                identifierPrefix: "analysis.acute"
            )

            if matchingFlags.contains(.estrogenRelated) {
                RegimenAnalysisChoiceRow(
                    title: "已知血栓病史或医生提过相关风险",
                    choices: [
                        .init(
                            value: .no,
                            label: "没有已知信息",
                            column: 0
                        ),
                        .init(value: .yes, label: "有", column: 1),
                        .init(value: .unknown, label: "不确定", column: 3)
                    ],
                    selection: $knownVteHistoryOrRisk,
                    identifierPrefix: "analysis.vte"
                )
            }

            if matchingFlags.contains(.cyproteroneAcetate) {
                RegimenAnalysisChoiceRow(
                    title: "已知脑膜瘤病史",
                    choices: [
                        .init(
                            value: .no,
                            label: "没有已知信息",
                            column: 0
                        ),
                        .init(value: .yes, label: "有", column: 1),
                        .init(value: .unknown, label: "不确定", column: 3)
                    ],
                    selection: $knownMeningiomaHistory,
                    identifierPrefix: "analysis.meningioma"
                )
            }
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

private struct RegimenAnalysisStatusLocator: View {
    @Environment(AppTheme.self) private var theme

    let status: RegimenAnalysisSemanticStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("当前状态")
                .font(theme.utility(9))
                .tracking(0.7)
                .foregroundStyle(theme.vermilionText)
            Text(detail)
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.indigoDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(theme.mustard.opacity(0.14))
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前分析状态，\(detail)")
        .accessibilityValue(status.rawValue)
        .accessibilityIdentifier("analysis.semanticStatus")
    }

    private var detail: String {
        switch status {
        case .unanswered:
            "等待回答安全边界"
        case .ready:
            "可以查看教育性整理"
        case .limited:
            "只能生成有限整理"
        case .stopped:
            "分析已停止，请先查看停止说明"
        }
    }
}

private struct RegimenAnalysisSummarySection: View {
    @Environment(AppTheme.self) private var theme

    let request: RegimenAnalysisRequestV1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            V25SectionHeader(
                title: "方案原文",
                detail: "\(request.regimenCode) · \(request.effectiveStartDate)"
            )

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(request.regimenTitle)
                        .font(theme.display(23, relativeTo: .title3))
                    Spacer(minLength: 8)
                    Text("\(request.items.count) 项")
                        .font(theme.utility(9))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(12)

                if request.items.isEmpty {
                    Text("这个版本没有方案组成项。")
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(
                        request.items.sorted {
                            ($0.position, $0.itemID.uuidString)
                                < ($1.position, $1.itemID.uuidString)
                        },
                        id: \.itemID
                    ) { item in
                        Rectangle().fill(theme.indigo).frame(height: 1)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(
                                "\(item.position + 1). "
                                    + (item.displayNameOriginal.isEmpty
                                        ? "未记录名称"
                                        : item.displayNameOriginal)
                            )
                            .font(.headline.weight(.black))
                            Text(
                                [
                                    item.dosageFormOriginal,
                                    item.routeOriginal,
                                    [item.doseOriginal, item.unitOriginal]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " "),
                                    item.scheduleSummaryOriginal
                                ]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            )
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .background(theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }

            Text("用量与单位只显示你保存的原文；App 不解析、换算或据此改变分析主题。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .accessibilityIdentifier("analysis.summary")
    }
}

private struct RegimenAnalysisChoice<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    let column: Int

    var id: Value { value }
}

private struct RegimenAnalysisChoiceRow<Value: Hashable>: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let choices: [RegimenAnalysisChoice<Value>]
    @Binding var selection: Value?
    let identifierPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.black))
                .foregroundStyle(theme.indigoDeep)
                .fixedSize(horizontal: false, vertical: true)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 7) {
                    choiceButtons
                }
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 7),
                        count: 4
                    ),
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(0..<4, id: \.self) { column in
                        if let choice = choices.first(
                            where: { $0.column == column }
                        ) {
                            choiceButton(choice)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .padding(11)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
    }

    @ViewBuilder
    private var choiceButtons: some View {
        ForEach(choices.sorted { $0.column < $1.column }) { choice in
            choiceButton(choice)
        }
    }

    private func choiceButton(
        _ choice: RegimenAnalysisChoice<Value>
    ) -> some View {
        let isSelected = selection == choice.value
        return Button {
            selection = choice.value
        } label: {
            Text(choice.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(
                    isSelected ? theme.paper : theme.indigoDeep
                )
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 4)
                .background(isSelected ? theme.indigo : theme.rice)
                .overlay {
                    Rectangle().stroke(
                        isSelected ? theme.mustard : theme.indigo,
                        lineWidth: isSelected ? 2 : 1
                    )
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            identifierPrefix + "." + String(describing: choice.value)
        )
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

private struct RegimenAnalysisResultSection: View {
    @Environment(AppTheme.self) private var theme

    let snapshot: RegimenAnalysisSnapshot
    let openSource: (RegimenAnalysisSourceCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            V25SectionHeader(title: "分析状态", detail: statusDetail)

            switch snapshot.semanticStatus {
            case .unanswered:
                Text("安全边界尚未回答完整。请选择仍未作答的项目；“不确定”必须由你主动选择。")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.indigoDeep)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.blue.opacity(0.14))
                    .overlay {
                        Rectangle().stroke(theme.indigo, lineWidth: 1.5)
                    }
                    .accessibilityIdentifier("analysis.unanswered")
            case .limited:
                Text("当前只能生成有限分析：保留原始方案和边界，不按名称猜测未知成分。")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.indigoDeep)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.mustard.opacity(0.2))
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                    .accessibilityIdentifier("analysis.limited")
            case .ready:
                Text("安全边界已回答；以下仅是教育性讨论整理，不是个人医疗结论。")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.indigoDeep)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.moss.opacity(0.16))
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                    .accessibilityIdentifier("analysis.ready")
            case .stopped:
                if let stop = snapshot.stopCards.first {
                    RegimenAnalysisStopCard(card: stop)
                        .accessibilityIdentifier("analysis.stop")
                } else {
                    Text("分析已停止，但停止说明不可用。")
                        .accessibilityIdentifier("analysis.stop")
                }
            }

            cardSection(
                title: "记录情况",
                detail: "\(snapshot.recordFindings.count) 项",
                values: snapshot.recordFindings
            )

            if !snapshot.componentExplanations.isEmpty {
                V25SectionHeader(
                    title: "逐项说明",
                    detail: "\(snapshot.componentExplanations.count) 个精确成分"
                )
                ForEach(snapshot.componentExplanations) { explanation in
                    RegimenAnalysisComponentExplanationView(
                        explanation: explanation,
                        openSource: openSource
                    )
                }
            }

            if !snapshot.frameworkCards.isEmpty {
                analysisCardSection(
                    title: "公开框架",
                    cards: snapshot.frameworkCards
                )
            }
            if !snapshot.confirmationCards.isEmpty {
                analysisCardSection(
                    title: "需要确认",
                    cards: snapshot.confirmationCards
                )
            }
            if !snapshot.monitoringCards.isEmpty {
                analysisCardSection(
                    title: "监测与复诊准备",
                    cards: snapshot.monitoringCards
                )
                .accessibilityIdentifier("analysis.monitoring")
            }
            if !snapshot.boundaryCards.isEmpty {
                analysisCardSection(
                    title: "适用边界",
                    cards: snapshot.boundaryCards
                )
            }

            if !snapshot.sources.isEmpty {
                V25SectionHeader(
                    title: "来源",
                    detail: "\(snapshot.sources.count) 项固定入口"
                )
                ForEach(snapshot.sources) { source in
                    RegimenAnalysisSourceRow(
                        source: source,
                        open: { openSource(source) }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("规则 \(snapshot.ruleSetVersion)")
                Text("内容 \(snapshot.contentPackVersion)")
                Text("输入摘要 \(snapshot.semanticInputDigest)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(theme.utility(9))
            .foregroundStyle(theme.secondaryText)
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("analysis.provenance")
        }
    }

    private var statusDetail: String {
        switch snapshot.semanticStatus {
        case .unanswered: "等待安全边界回答"
        case .ready: "可显示讨论材料"
        case .limited: "仅显示有限内容"
        case .stopped: "药品特异分析已停止"
        }
    }

    private func cardSection(
        title: String,
        detail: String,
        values: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            V25SectionHeader(title: title, detail: detail)
            VStack(spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    if index > 0 {
                        Rectangle().fill(theme.indigo).frame(height: 1)
                    }
                    Text(value)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(theme.indigoDeep)
            .background(theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
        }
    }

    private func analysisCardSection(
        title: String,
        cards: [RegimenAnalysisCard]
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            V25SectionHeader(title: title, detail: "\(cards.count) 项")
            ForEach(cards) { card in
                RegimenAnalysisEditorialCard(card: card)
            }
        }
    }
}

private struct RegimenAnalysisStopCard: View {
    @Environment(AppTheme.self) private var theme

    let card: RegimenAnalysisCard

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("STOP / 停止 App 分析")
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.paper)
            Text(card.title)
                .font(theme.display(25, relativeTo: .title2))
                .foregroundStyle(theme.paper)
            Text(card.body)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.paper)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(theme.paper).frame(height: 1)
            Text(card.boundary)
                .font(.caption)
                .foregroundStyle(theme.paper)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(theme.vermilion)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
        .accessibilityElement(children: .combine)
    }
}

private struct RegimenAnalysisComponentExplanationView: View {
    @Environment(AppTheme.self) private var theme

    let explanation: RegimenAnalysisComponentExplanation
    let openSource: (RegimenAnalysisSourceCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(
                "\(explanation.itemPosition + 1). "
                    + (explanation.itemNameOriginal.isEmpty
                        ? "未记录名称"
                        : explanation.itemNameOriginal)
            )
            .font(.caption.weight(.black))
            .foregroundStyle(theme.vermilionText)
            Text(explanation.ingredientNameZH)
                .font(theme.display(22, relativeTo: .title3))
            Text("是什么 · 目录精确成分 \(explanation.ingredientID)")
                .font(.subheadline.weight(.semibold))
            Text("为什么出现 · \(explanation.correspondenceExplanation)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text("适用边界 · \(explanation.boundary)")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !explanation.discussionCards.isEmpty {
                Text("可带去讨论")
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.blueText)
                    .padding(.top, 2)
                ForEach(explanation.discussionCards) { card in
                    Text("• \(card.title)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !explanation.sources.isEmpty {
                Text("原始资料")
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.blueText)
                    .padding(.top, 2)
                ForEach(explanation.sources) { source in
                    Button(
                        "查看来源 · \(source.institution)",
                        action: { openSource(source) }
                    )
                    .buttonStyle(V25SecondaryButtonStyle())
                    .accessibilityIdentifier(
                        "analysis.component.\(explanation.ingredientID).source.\(source.id)"
                    )
                }
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.blue).frame(width: 5)
        }
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
        .padding(.bottom, 9)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "analysis.component.\(explanation.ingredientID)"
        )
    }
}

private struct RegimenAnalysisEditorialCard: View {
    @Environment(AppTheme.self) private var theme

    let card: RegimenAnalysisCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                card.evidenceBasis == .externalAuthority
                    ? "公开资料整理"
                    : "产品规则"
            )
                .font(theme.utility(8))
                .tracking(0.6)
                .foregroundStyle(theme.vermilionText)
            Text(card.title)
                .font(theme.display(21, relativeTo: .title3))
            Text(card.body)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.boundary)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.mustard).frame(width: 5)
        }
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

private struct RegimenAnalysisSourceRow: View {
    @Environment(AppTheme.self) private var theme

    let source: RegimenAnalysisSourceCard
    let open: () -> Void

    private var domain: String {
        URL(string: source.officialURL)?.host ?? "未知域名"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.institution)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.vermilionText)
            Text(source.title)
                .font(.headline.weight(.black))
                .fixedSize(horizontal: false, vertical: true)
            Text(source.versionOrPublishedAt + " · 查阅 " + source.retrievedAt)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text("适用人群 · \(source.applicablePopulation)")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("适用地区 · \(source.applicableRegions.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(source.boundary)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("查看原始来源 · \(domain)", action: open)
                .buttonStyle(V25SecondaryButtonStyle())
                .accessibilityIdentifier("analysis.source.\(source.id)")
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
        .padding(.bottom, 8)
    }
}

private struct RegimenAnalysisUnavailableView: View {
    @Environment(AppTheme.self) private var theme

    let reason: RegimenAnalysisUnavailableReason

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            V25SectionHeader(title: "分析不可用", detail: "原始方案保持不变")
            Text(reason.title)
                .font(theme.display(25, relativeTo: .title2))
                .accessibilityIdentifier("analysis.unavailable")
            Text(reason.detail)
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("你仍可以查看和编辑自己的方案；这里没有静默改用占位规则。")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.bottom, 20)
    }
}

private struct RegimenAnalysisExternalSourceBoundary: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let source: RegimenAnalysisSourceCard

    private var url: URL? { URL(string: source.officialURL) }
    private var domain: String { url?.host ?? "未知域名" }

    var body: some View {
        NavigationStack {
            V25Page {
                VStack(alignment: .leading, spacing: 0) {
                    V25PageHeader(
                        register: "SOURCE / BOUNDARY",
                        title: "将离开 App",
                        subtitle: "先核对目标域名和数据边界。",
                        status: domain
                    )
                    V25SectionHeader(title: source.institution, detail: "固定来源入口")
                    Text(source.title)
                        .font(theme.display(26, relativeTo: .title2))
                        .foregroundStyle(theme.indigoDeep)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(source.boundary)
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("适用人群与地区")
                            .font(.caption.weight(.black))
                            .foregroundStyle(theme.vermilionText)
                        Text(source.applicablePopulation)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(source.applicableRegions.joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(theme.indigoDeep)
                    .padding(12)
                    .background(theme.paper)
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
                    .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("目标域名")
                            .font(.caption.weight(.black))
                            .foregroundStyle(theme.vermilionText)
                        Text(domain)
                            .font(.headline.monospaced())
                        Text("这个固定 URL 不包含你的方案、药名、搜索词、用户或设备标识。系统浏览器中的后续活动不再受 App Lock 控制。")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(theme.indigoDeep)
                    .padding(12)
                    .background(theme.paper)
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                    .padding(.top, 16)

                    Button("在系统浏览器中打开") {
                        guard let url else { return }
                        openURL(url)
                    }
                    .buttonStyle(V25PrimaryButtonStyle())
                    .disabled(url == nil)
                    .padding(.top, 16)
                    .accessibilityIdentifier("analysis.external.open")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("analysis.external.cancel")
                }
            }
        }
        .accessibilityIdentifier("analysis.externalBoundary")
    }
}

#if DEBUG
enum RegimenAnalysisDebugFixture {
    static var regimen: CoreRegimenVersionSnapshot {
        guard let entry = MedicationCatalog.entries.first(
            where: { $0.id == "estradiol" }
        ),
            let product = entry.products.first(
                where: { $0.id == "record.estradiol.transdermal-patch" }
            ) else {
            preconditionFailure("Batch 8B DEBUG fixture requires Batch 8A seed.")
        }
        let draft = entry.draft(for: product)
        return CoreRegimenVersionSnapshot(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            code: "R-08B",
            title: "当前记录方案",
            effectiveStartDate: try! CivilDateFact(
                year: 2026,
                month: 7,
                day: 30
            ),
            effectiveEndDate: nil,
            previousVersionID: nil,
            changeReason: "DEBUG fixture",
            editState: .sealed,
            requiresReview: false,
            items: [
                CoreRegimenItemSnapshot(
                    id: UUID(
                        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                    )!,
                    catalogProductID: draft.catalogID,
                    catalogVersion: draft.catalogVersion,
                    displayName: draft.name,
                    genericName: draft.englishName,
                    dosageForm: draft.dosageForm,
                    route: draft.route,
                    doseOriginal: "用户原文",
                    unitOriginal: "用户单位",
                    productSnapshot: draft.productSnapshot,
                    schedule: nil,
                    scheduleSummary: "每天 · 08:00"
                )
            ]
        )
    }
}
#endif
