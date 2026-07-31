import SwiftUI

enum PocketAppendixExternalTargetFactory {
    static func source(
        _ source: OfflineContextualContentSource,
        statusDate: Date
    ) -> FixedExternalLinkTarget? {
        let status =
            OfflineContextualContentSourceLinkStatus.resolve(
                source,
                statusDate: statusDate
            )
        guard status != .unavailable else {
            return nil
        }
        return FixedExternalLinkTarget(
            id: "source:\(source.id)",
            title: source.title,
            institution: source.rightsHolder,
            boundary: source.boundary,
            urlString: source.url,
            freshness:
                status == .needsReverification
                ? .needsReverification
                : .current,
            applicableRegions: source.applicableRegions,
            applicablePopulations:
                source.applicablePopulations
        )
    }

    static func original(
        _ card: OfflineContextualContentCardSnapshot
    ) -> FixedExternalLinkTarget {
        FixedExternalLinkTarget(
            id: "original:\(card.id)",
            title: card.title,
            institution: "MTF不全书",
            boundary:
                "这是该摘要对应的项目原文入口。完整文章可能包含更多上下文；App 不会把你的搜索词、收藏或个人记录附加到 URL。",
            urlString: card.card.originalURL,
            freshness:
                card.status == .stale
                ? .needsReverification
                : .current,
            applicableRegions: [],
            applicablePopulations: []
        )
    }

    static func repository(
        _ attribution:
            OfflineContextualContentAttribution
    ) -> FixedExternalLinkTarget {
        FixedExternalLinkTarget(
            id: "attribution:repository",
            title: "查看冻结来源仓库",
            institution: attribution.creator,
            boundary:
                "这是摘要来源仓库的固定入口。App 展示的摘要仍以当前已校验内容包和精确提交为准。",
            urlString: attribution.sourceRepository,
            freshness: .current,
            applicableRegions: [],
            applicablePopulations: []
        )
    }

    static func license(
        _ attribution:
            OfflineContextualContentAttribution
    ) -> FixedExternalLinkTarget {
        FixedExternalLinkTarget(
            id: "attribution:license",
            title: attribution.licenseIdentifier,
            institution: "Creative Commons",
            boundary:
                "此入口用于阅读摘要内容的许可条款；外部机构资料与链接目标仍保留各自权利。",
            urlString: attribution.licenseURL,
            freshness: .current,
            applicableRegions: [],
            applicablePopulations: []
        )
    }
}

struct PocketAppendixReaderView: View {
    @Environment(AppTheme.self) private var theme

    let snapshot: OfflineContextualContentSnapshot
    let card: OfflineContextualContentCardSnapshot
    let favorite: ContentFavoriteSnapshot?
    let isWriting: Bool
    let favoriteIsAvailable: Bool
    let favoriteFeedback:
        PocketAppendixFavoriteFeedback?
    let openAttribution: () -> Void
    let openExternal: (FixedExternalLinkTarget) -> Void
    let toggleFavorite: () -> Void
    let showsFavoriteAction: Bool

    init(
        snapshot: OfflineContextualContentSnapshot,
        card: OfflineContextualContentCardSnapshot,
        favorite: ContentFavoriteSnapshot?,
        isWriting: Bool,
        favoriteIsAvailable: Bool,
        favoriteFeedback:
            PocketAppendixFavoriteFeedback?,
        openAttribution: @escaping () -> Void,
        openExternal:
            @escaping (FixedExternalLinkTarget) -> Void,
        toggleFavorite: @escaping () -> Void,
        showsFavoriteAction: Bool = true
    ) {
        self.snapshot = snapshot
        self.card = card
        self.favorite = favorite
        self.isWriting = isWriting
        self.favoriteIsAvailable =
            favoriteIsAvailable
        self.favoriteFeedback = favoriteFeedback
        self.openAttribution = openAttribution
        self.openExternal = openExternal
        self.toggleFavorite = toggleFavorite
        self.showsFavoriteAction =
            showsFavoriteAction
    }

    private var isFavorite: Bool {
        favorite?.isFavorite == true
    }

    var body: some View {
        List {
            header
                .pocketReaderListRow(theme: theme)

            if let favoriteFeedback {
                favoriteFeedbackNotice(favoriteFeedback)
                    .pocketReaderListRow(theme: theme)
            }

            if showsFavoriteAction
                && !favoriteIsAvailable {
                favoriteUnavailableNotice
                    .pocketReaderListRow(theme: theme)
            }

            section(
                register: "SUMMARY / LOCAL",
                title: "必要摘要",
                body: card.card.summary
            )
            .pocketReaderListRow(theme: theme)

            section(
                register: "BOUNDARY / USE",
                title: "适用边界",
                body: card.card.applicabilityBoundary
            )
            .pocketReaderListRow(theme: theme)

            metadata
                .pocketReaderListRow(theme: theme)

            sourceLedger
                .pocketReaderListRow(theme: theme)

            Button("打开 MTF不全书完整原文") {
                openExternal(
                    PocketAppendixExternalTargetFactory
                        .original(card)
                )
            }
            .buttonStyle(V25PrimaryButtonStyle())
            .accessibilityIdentifier(
                "pocketAppendix.reader.original"
            )
            .pocketReaderListRow(theme: theme)

            Button(
                "查看内容来源与许可",
                action: openAttribution
            )
            .buttonStyle(V25SecondaryButtonStyle())
            .accessibilityIdentifier(
                "pocketAppendix.reader.attribution"
            )
            .pocketReaderListRow(theme: theme)

            V25PrivacyFooter(
                text:
                    "这是教育性离线摘要，不是诊断、处方、剂量建议或个体化化验解读。"
            )
            .pocketReaderListRow(theme: theme)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.rice.ignoresSafeArea())
        .navigationTitle("离线摘要")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsFavoriteAction {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleFavorite) {
                        Label(
                            !favoriteIsAvailable
                                ? "收藏状态待核对"
                                : isFavorite
                                ? "取消收藏"
                                : "收藏",
                            systemImage:
                                !favoriteIsAvailable
                                ? "bookmark.slash"
                                : isFavorite
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(
                        !favoriteIsAvailable
                            || isWriting
                    )
                    .accessibilityLabel(
                        PocketAppendixFavoriteAccessibility
                            .label(
                                isFavorite: isFavorite,
                                isAvailable:
                                    favoriteIsAvailable
                            )
                    )
                    .accessibilityValue(
                        PocketAppendixFavoriteAccessibility
                            .value(
                                isFavorite: isFavorite,
                                isAvailable:
                                    favoriteIsAvailable
                            )
                    )
                    .accessibilityIdentifier(
                        "pocketAppendix.reader.favorite"
                    )
                }
            }
        }
        .toolbarBackground(theme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier(
            "pocketAppendix.reader"
        )
    }

    private var favoriteUnavailableNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(theme.vermilion)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text("收藏状态暂时无法核对")
                    .font(.headline.weight(.black))
                Text(
                    "收藏资料没有通过完整核对；这里不会把未知状态显示成未收藏。当前摘要仍可离线阅读。"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(
                theme.vermilion,
                lineWidth: 1.5
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "pocketAppendix.reader.favoriteUnavailable"
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.card.contentType.displayTitle)
                    .font(theme.utility(10))
                    .tracking(0.7)
                    .foregroundStyle(theme.vermilionText)
                Spacer(minLength: 10)
                Text(card.card.category.displayTitle)
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.blueText)
            }
            Text(card.card.title)
                .font(
                    theme.display(
                        34,
                        relativeTo: .largeTitle
                    )
                )
                .foregroundStyle(theme.indigoDeep)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            statusNotice
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.indigo)
                .frame(height: 2)
        }
    }

    private var statusNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle()
                .fill(statusColor)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline.weight(.black))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(11)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(
                statusColor,
                lineWidth: 1.5
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "pocketAppendix.reader.status"
        )
    }

    private func favoriteFeedbackNotice(
        _ feedback: PocketAppendixFavoriteFeedback
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(
                    feedback.isError
                        ? theme.vermilion
                        : theme.blue
                )
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(feedback.title)
                    .font(.headline.weight(.black))
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(
                feedback.isError
                    ? theme.vermilion
                    : theme.indigo,
                lineWidth: 1.5
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "pocketAppendix.reader.favoriteFeedback"
        )
    }

    private var statusTitle: String {
        switch card.status {
        case .current:
            "当前内容"
        case .stale:
            "需要重新核验"
        case .sourceUnavailable:
            "部分来源入口当前不可用"
        case .unavailable:
            "内容当前不可用"
        }
    }

    private var statusDetail: String {
        switch card.status {
        case .current:
            "摘要、适用边界和来源台账已通过当前内容包核对。"
        case .stale:
            "缓存摘要仍可阅读；请核对查阅日期，并在引用来源前确认是否有更新。"
        case .sourceUnavailable:
            "缓存摘要仍可阅读；不可用来源会留在台账中，但不能打开。"
        case .unavailable:
            "当前内容包无法提供这项摘要。"
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .current:
            theme.moss
        case .stale:
            theme.mustard
        case .sourceUnavailable, .unavailable:
            theme.vermilion
        }
    }

    private func section(
        register: String,
        title: String,
        body: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(register)
                .font(theme.utility(9))
                .tracking(0.6)
                .foregroundStyle(theme.vermilionText)
            Text(title)
                .font(.title3.weight(.black))
            Text(body)
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.vertical, 6)
    }

    private var metadata: some View {
        return VStack(alignment: .leading, spacing: 0) {
            V25SectionHeader(
                title: "版本与日期",
                detail: "本机内容包"
            )
            metadataRow(
                "内容版本",
                card.card.contentVersion,
                accessibilityValue:
                    accessibleContentVersion
            )
            metadataRow(
                "查阅日期",
                card.card.retrievedAt
            )
            metadataRow(
                "重新核验日期",
                card.card.expiresAt
            )
            metadataRow(
                "内容类型",
                card.card.contentType.displayTitle
            )
        }
    }

    private func metadataRow(
        _ label: String,
        _ value: String,
        accessibilityValue: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.secondaryText.opacity(0.5))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label)：\(accessibilityValue ?? value)"
        )
    }

    private var accessibleContentVersion: String {
        let version = card.card.contentVersion
        let candidatePrefix =
            "offline-contextual-content-candidate."
        if version.hasPrefix(candidatePrefix) {
            return
                "本地离线上下文资料候选版，第 "
                + version.dropFirst(candidatePrefix.count)
                + " 版"
        }
        return "本地内容包，版本标识 \(version)"
    }

    private var sourceLedger: some View {
        VStack(alignment: .leading, spacing: 0) {
            V25SectionHeader(
                title: "来源台账",
                detail: "\(card.sources.count) 项"
            )
            ForEach(card.sources) { source in
                sourceRow(source)
            }
        }
    }

    private func sourceRow(
        _ source: OfflineContextualContentSource
    ) -> some View {
        let status =
            OfflineContextualContentSourceLinkStatus.resolve(
                source,
                statusDate: snapshot.statusDate
            )
        let sourceMetadata =
            PocketAppendixSourceMetadata.make(
                source: source,
                statusDate: snapshot.statusDate
            )
        let target =
            PocketAppendixExternalTargetFactory.source(
                source,
                statusDate: snapshot.statusDate
            )
        return VStack(alignment: .leading, spacing: 8) {
            Text(source.rightsHolder)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.vermilionText)
            Text(source.title)
                .font(.body.weight(.black))
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            Text(source.versionOrPublishedAt)
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryText)
                .accessibilityLabel(
                    "版本或发布日期："
                        + source.versionOrPublishedAt
                )
            sourceMetadataRow(
                "查阅日期",
                sourceMetadata.retrievedAt
            )
            sourceMetadataRow(
                "重新核验日期",
                sourceMetadata.expiresAt
            )
            sourceMetadataRow(
                "来源状态",
                sourceMetadata.statusLabel
            )
            sourceMetadataRow(
                "适用地区",
                sourceMetadata.applicableRegionsLabel
            )
            sourceMetadataRow(
                "适用人群",
                sourceMetadata.applicablePopulationsLabel
            )
            Text(source.boundary)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            if let target {
                Button(
                    status == .needsReverification
                        ? "核对后打开来源"
                        : "核对并打开来源"
                ) {
                    openExternal(target)
                }
                .buttonStyle(V25SecondaryButtonStyle())
                .accessibilityIdentifier(
                    "pocketAppendix.reader.source."
                        + source.id
                )
            } else {
                Text("来源入口当前不可用")
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.vermilionText)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44,
                        alignment: .leading
                    )
                    .accessibilityIdentifier(
                        "pocketAppendix.reader.sourceUnavailable."
                            + source.id
                    )
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .background(theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.indigo)
                .frame(height: 1)
        }
        .accessibilityIdentifier(
            "pocketAppendix.reader.sourceMetadata."
                + source.id
        )
    }

    private func sourceMetadataRow(
        _ label: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption2.weight(.black))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2.monospaced())
                .multilineTextAlignment(.trailing)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .foregroundStyle(theme.indigoDeep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)：\(value)")
    }
}

struct PocketAppendixAttributionView: View {
    @Environment(AppTheme.self) private var theme

    let snapshot: OfflineContextualContentSnapshot
    let card: OfflineContextualContentCardSnapshot?
    let openExternal: (FixedExternalLinkTarget) -> Void

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                Text("SOURCE / LICENSE")
                    .font(theme.utility(10))
                    .tracking(0.7)
                    .foregroundStyle(theme.vermilionText)
                Text("内容来源与许可")
                    .font(
                        theme.display(
                            34,
                            relativeTo: .largeTitle
                        )
                    )
                Text(
                    "这里说明项目原创摘要如何从冻结来源进入当前内容包；外部机构资料仍保留各自权利。"
                )
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.vertical, 10)
            .pocketReaderListRow(theme: theme)

            ledger
                .pocketReaderListRow(theme: theme)

            if let card {
                cardProvenance(card)
                    .pocketReaderListRow(theme: theme)
            }

            Button("核对来源仓库") {
                openExternal(
                    PocketAppendixExternalTargetFactory
                        .repository(snapshot.attribution)
                )
            }
            .buttonStyle(V25PrimaryButtonStyle())
            .accessibilityIdentifier(
                "pocketAppendix.attribution.repository"
            )
            .pocketReaderListRow(theme: theme)

            Button("阅读 CC BY-SA 4.0") {
                openExternal(
                    PocketAppendixExternalTargetFactory
                        .license(snapshot.attribution)
                )
            }
            .buttonStyle(V25SecondaryButtonStyle())
            .accessibilityIdentifier(
                "pocketAppendix.attribution.license"
            )
            .pocketReaderListRow(theme: theme)

            V25PrivacyFooter(
                text:
                    snapshot.attribution.shareAlikeStatement
            )
            .pocketReaderListRow(theme: theme)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.rice.ignoresSafeArea())
        .navigationTitle("来源与许可")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier(
            "pocketAppendix.attribution.page"
        )
    }

    private var ledger: some View {
        let disclosure =
            PocketAppendixAttributionDisclosure.make(
                snapshot: snapshot,
                card: card
            )
        return VStack(alignment: .leading, spacing: 0) {
            V25SectionHeader(
                title: "内容包署名",
                detail: snapshot.attribution.licenseIdentifier
            )
            ledgerRow(
                "创作者",
                snapshot.attribution.creator
            )
            ledgerRow(
                "精确提交",
                snapshot.attribution.sourceCommit
            )
            ledgerRow(
                "来源仓库 URL",
                disclosure.sourceRepository
            )
            ledgerRow(
                "正式许可证 URL",
                disclosure.licenseURL
            )
            ledgerRow(
                "改编状态",
                snapshot.attribution.adaptationStatus
                    .displayTitle
            )
            ledgerRow(
                "修改说明",
                snapshot.attribution.modificationNote
            )
        }
    }

    private func cardProvenance(
        _ card: OfflineContextualContentCardSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            V25SectionHeader(
                title: "本摘要的来源谱系",
                detail: card.card.id
            )
            ledgerRow(
                "来源路径",
                card.card.provenance.sourcePath
            )
            ledgerRow(
                "来源 SHA-256",
                card.card.provenance.sourceFileSHA256
            )
            ledgerRow(
                "本摘要改编状态",
                card.card.provenance.adaptationStatus
                    .displayTitle
            )
            ledgerRow(
                "卡片 digest",
                card.card.cardDigest
            )
            ledgerRow(
                "改编说明",
                card.card.provenance.modificationNote
            )
        }
    }

    private func ledgerRow(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.vermilionText)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(theme.indigoDeep)
                .textSelection(.enabled)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.secondaryText.opacity(0.5))
                .frame(height: 1)
        }
    }
}

private extension View {
    func pocketReaderListRow(
        theme: AppTheme
    ) -> some View {
        listRowInsets(
            EdgeInsets(
                top: 6,
                leading: V25Theme.pagePadding,
                bottom: 6,
                trailing: V25Theme.pagePadding
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(theme.rice)
    }
}

private extension OfflineContextualContentAdaptationStatus {
    var displayTitle: String {
        switch self {
        case .unmodified:
            "未修改"
        case .modified:
            "已摘编"
        }
    }
}
