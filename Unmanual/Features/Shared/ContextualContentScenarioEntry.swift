import SwiftUI

struct OfflineContextualContentScenarioResolution:
    Equatable, Sendable {
    let anchor: OfflineContextualContentScenarioAnchor
    let card: OfflineContextualContentCardSnapshot
}

enum OfflineContextualContentScenarioResolver {
    static func resolve(
        scenario: OfflineContextualContentScenario,
        snapshot: OfflineContextualContentSnapshot
    ) -> OfflineContextualContentScenarioResolution? {
        guard scenario != .pocketAppendix else {
            return nil
        }
        let anchors = snapshot.scenarioAnchors.filter {
            $0.scenario == scenario
        }
        guard anchors.count == 1,
              let anchor = anchors.first else {
            return nil
        }
        let cards = snapshot.cards.filter {
            $0.id == anchor.cardID
        }
        guard cards.count == 1,
              let card = cards.first else {
            return nil
        }
        return OfflineContextualContentScenarioResolution(
            anchor: anchor,
            card: card
        )
    }
}

enum ContextualContentEligibility {
    static func scenario(
        for status: RegimenAnalysisSemanticStatus
    ) -> OfflineContextualContentScenario? {
        switch status {
        case .ready, .limited:
            .regimenAnalysisSource
        case .unanswered, .stopped:
            nil
        }
    }

    static func scenario(
        for kind: PersonalTimelineItemKind
    ) -> OfflineContextualContentScenario? {
        switch kind {
        case .labSample:
            .timelineRecord
        case .statusObservation, .journeyEntry,
             .administration, .countdown,
             .regimenVersion, .hrtJourney:
            nil
        }
    }
}

struct ContextualContentScenarioPresentation:
    Equatable, Sendable {
    let register: String
    let title: String
    let detail: String
    let actionTitle: String
    let identifier: String

    static func make(
        for scenario: OfflineContextualContentScenario
    ) -> Self? {
        switch scenario {
        case .regimenField:
            Self(
                register: "FIELD / GUIDE",
                title: "把方案字段当作忠实记录",
                detail:
                    "名称、剂型与给药途径分别记录；不会推荐或换算剂量。",
                actionTitle: "查看方案字段说明",
                identifier: "contextual.regimenField"
            )
        case .labRecording:
            Self(
                register: "LAB / RECORD",
                title: "保留化验原件与采样上下文",
                detail:
                    "原始值、单位、参考范围、采样条件和报告附件分别保留；App 不解释单个数值。",
                actionTitle: "查看化验记录说明",
                identifier: "contextual.labRecording"
            )
        case .regimenAnalysisSource:
            Self(
                register: "ANALYSIS / SOURCE",
                title: "离线查看监测与复诊说明",
                detail:
                    "这是固定教育摘要，不会根据方案成分或安全回答改选内容。",
                actionTitle: "查看对应离线摘要",
                identifier:
                    "contextual.regimenAnalysisSource"
            )
        case .visitPreparation:
            Self(
                register: "VISIT / CHECKLIST",
                title: "首诊与复诊准备清单",
                detail:
                    "独立查看，不会进入就诊摘要、PDF 或 CSV。",
                actionTitle: "打开复诊准备清单",
                identifier: "contextual.visitPreparation"
            )
        case .timelineRecord:
            Self(
                register: "TIMELINE / RECORD",
                title: "保留原件与记录上下文",
                detail:
                    "按记录的闭集类型提供说明，不读取数值、单位或备注做匹配。",
                actionTitle: "查看这类记录的说明",
                identifier: "contextual.timelineRecord"
            )
        case .pocketAppendix:
            nil
        }
    }
}

enum ContextualContentUnavailableCopy {
    static func detail(
        for reason:
            OfflineContextualContentUnavailableReason
    ) -> String {
        switch reason {
        case .pendingHumanReviewAndClassification:
            "内容尚未通过真实人类复核，不影响当前操作。"
        case .rejectedByHumanReview:
            "这批内容未获批准，因此不会展示；不影响当前操作。"
        case .missingResource:
            "当前版本没有可用的正式离线说明，不影响当前操作。"
        case .invalidContent:
            "离线说明没有通过完整性检查，不影响当前操作。"
        case .unreadableContent:
            "离线说明暂时无法读取，不影响当前操作。"
        }
    }
}

enum ContextualContentEntryPhase:
    Equatable, Sendable {
    case loading
    case available(OfflineContextualContentSnapshot)
    case unavailable(
        OfflineContextualContentUnavailableReason
    )
}

private struct ContextualContentSelection:
    Identifiable {
    let snapshot: OfflineContextualContentSnapshot
    let resolution:
        OfflineContextualContentScenarioResolution

    var id: String {
        "\(resolution.anchor.scenario.rawValue):"
            + resolution.card.id
    }
}

@MainActor
struct ContextualContentScenarioEntry: View {
    @Environment(AppTheme.self) private var theme

    let scenario: OfflineContextualContentScenario
    private let loader: OfflineContextualContentLoader
    private let loadsOnTask: Bool

    @State private var phase:
        ContextualContentEntryPhase
    @State private var selection:
        ContextualContentSelection?

    init(
        scenario: OfflineContextualContentScenario,
        loader:
            OfflineContextualContentLoader = .live
    ) {
        self.scenario = scenario
        self.loader = loader
        self.loadsOnTask = true
        _phase = State(initialValue: .loading)
    }

    init(
        previewScenario scenario:
            OfflineContextualContentScenario,
        phase: ContextualContentEntryPhase
    ) {
        self.scenario = scenario
        self.loader = .immediate(
            .unavailable(.missingResource)
        )
        self.loadsOnTask = false
        _phase = State(initialValue: phase)
    }

    var body: some View {
        Group {
            if let presentation =
                ContextualContentScenarioPresentation
                    .make(for: scenario) {
                content(presentation)
            }
        }
        .task {
            guard loadsOnTask else { return }
            await load()
        }
        .sheet(item: $selection) { selection in
            ContextualContentReaderSheet(
                snapshot: selection.snapshot,
                card: selection.resolution.card
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func content(
        _ presentation:
            ContextualContentScenarioPresentation
    ) -> some View {
        switch phase {
        case .loading:
            loading(presentation)
        case let .unavailable(reason):
            unavailable(
                presentation,
                detail:
                    ContextualContentUnavailableCopy
                        .detail(for: reason)
            )
        case let .available(snapshot):
            if let resolution =
                OfflineContextualContentScenarioResolver
                    .resolve(
                        scenario: scenario,
                        snapshot: snapshot
                    ),
               resolution.card.status != .unavailable {
                available(
                    presentation,
                    snapshot: snapshot,
                    resolution: resolution
                )
            } else {
                unavailable(
                    presentation,
                    detail:
                        "离线说明的固定映射没有通过核对，不影响当前操作。"
                )
            }
        }
    }

    private func loading(
        _ presentation:
            ContextualContentScenarioPresentation
    ) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在读取离线说明…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 44,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            presentation.identifier + ".loading"
        )
    }

    private func unavailable(
        _ presentation:
            ContextualContentScenarioPresentation,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.register)
                .font(theme.utility(9))
                .tracking(0.6)
                .foregroundStyle(theme.vermilionText)
            Text("离线说明暂时不可用")
                .font(.headline.weight(.black))
            Text(detail)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .frame(
            maxWidth: .infinity,
            minHeight: 44,
            alignment: .leading
        )
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(
                theme.vermilion,
                lineWidth: 1.5
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            presentation.identifier + ".unavailable"
        )
    }

    private func available(
        _ presentation:
            ContextualContentScenarioPresentation,
        snapshot: OfflineContextualContentSnapshot,
        resolution:
            OfflineContextualContentScenarioResolution
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.register)
                    .font(theme.utility(9))
                    .tracking(0.6)
                    .foregroundStyle(
                        theme.vermilionText
                    )
                Spacer(minLength: 8)
                Text(statusLabel(resolution.card.status))
                    .font(.caption.weight(.black))
                    .foregroundStyle(
                        statusColor(
                            resolution.card.status
                        )
                    )
            }
            Text(presentation.title)
                .font(.headline.weight(.black))
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            Button(presentation.actionTitle) {
                selection = ContextualContentSelection(
                    snapshot: snapshot,
                    resolution: resolution
                )
            }
            .buttonStyle(V25SecondaryButtonStyle())
            .frame(minHeight: 44)
            .accessibilityValue(
                statusLabel(resolution.card.status)
            )
            .accessibilityIdentifier(
                presentation.identifier
            )
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(
                theme.indigo,
                lineWidth: 1.5
            )
        }
    }

    private func statusLabel(
        _ status: OfflineContextualContentCardStatus
    ) -> String {
        switch status {
        case .current:
            "当前内容"
        case .stale:
            "需要重新核验"
        case .sourceUnavailable:
            "来源入口不可用"
        case .unavailable:
            "内容不可用"
        }
    }

    private func statusColor(
        _ status: OfflineContextualContentCardStatus
    ) -> Color {
        switch status {
        case .current:
            theme.mossText
        case .stale:
            theme.mustardText
        case .sourceUnavailable, .unavailable:
            theme.vermilionText
        }
    }

    private func load() async {
        phase = .loading
        switch await loader.load() {
        case let .available(snapshot):
            phase = .available(snapshot)
        case let .unavailable(reason):
            phase = .unavailable(reason)
        }
    }
}

private enum ContextualContentReaderRoute:
    Hashable {
    case attribution
}

@MainActor
struct ContextualContentReaderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let snapshot: OfflineContextualContentSnapshot
    let card: OfflineContextualContentCardSnapshot

    @State private var path:
        [ContextualContentReaderRoute] = []
    @State private var externalTarget:
        FixedExternalLinkTarget?

    var body: some View {
        NavigationStack(path: $path) {
            PocketAppendixReaderView(
                snapshot: snapshot,
                card: card,
                favorite: nil,
                isWriting: false,
                favoriteIsAvailable: false,
                favoriteFeedback: nil,
                openAttribution: {
                    path.append(.attribution)
                },
                openExternal: {
                    externalTarget = $0
                },
                toggleFavorite: {},
                showsFavoriteAction: false
            )
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button {
                        dismiss()
                    } label: {
                        Text("关闭")
                            .frame(
                                minWidth: 44,
                                minHeight: 44
                            )
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(
                        "contextual.reader.close"
                    )
                }
            }
            .navigationDestination(
                for: ContextualContentReaderRoute.self
            ) { route in
                switch route {
                case .attribution:
                    PocketAppendixAttributionView(
                        snapshot: snapshot,
                        card: card,
                        openExternal: {
                            externalTarget = $0
                        }
                    )
                }
            }
        }
        .sheet(item: $externalTarget) { target in
            FixedExternalLinkBoundaryView(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier(
            "contextual.reader.sheet"
        )
    }
}
