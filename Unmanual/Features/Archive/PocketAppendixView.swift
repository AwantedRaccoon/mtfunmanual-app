import SwiftUI

struct PocketAppendixFavoritesAccess: Sendable {
    let load:
        @Sendable () async throws
            -> [ContentFavoriteSnapshot]
    let set:
        @Sendable (SetContentFavoriteCommand) async throws
            -> SetContentFavoriteResult
}

enum PocketAppendixContentPhase:
    Equatable, Sendable {
    case loading
    case available(OfflineContextualContentSnapshot)
    case unavailable(
        OfflineContextualContentUnavailableReason
    )
}

enum PocketAppendixRoute: Hashable {
    case card(String)
    case attribution(String?)
}

@MainActor
struct PocketAppendixView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReadActor) private var appReadActor
    @Environment(\.appDataWriter) private var appDataWriter

    private let contentLoader:
        OfflineContextualContentLoader
    private let favoritesAccessOverride:
        PocketAppendixFavoritesAccess?
    private let loadsOnTask: Bool

    @State private var contentPhase:
        PocketAppendixContentPhase
    @State private var favoriteState:
        PocketAppendixFavoriteLoadState
    @State private var query = ""
    @State private var selectedCategory:
        OfflineContextualContentCategory?
    @State private var favoritesOnly = false
    @State private var path: [PocketAppendixRoute] = []
    @State private var externalTarget:
        FixedExternalLinkTarget?
    @State private var writingContentID: String?
    @State private var favoriteFeedback:
        PocketAppendixFavoriteFeedback?

    init(
        contentLoader:
            OfflineContextualContentLoader = .live,
        favoritesAccess:
            PocketAppendixFavoritesAccess? = nil
    ) {
        self.contentLoader = contentLoader
        self.favoritesAccessOverride = favoritesAccess
        self.loadsOnTask = true
        _contentPhase = State(initialValue: .loading)
        _favoriteState = State(initialValue: .loading)
    }

    init(
        previewContentState:
            OfflineContextualContentLoadState,
        previewFavoriteState:
            PocketAppendixFavoriteLoadState,
        previewQuery: String = "",
        previewCategory:
            OfflineContextualContentCategory? = nil,
        previewFavoritesOnly: Bool = false,
        previewFeedback:
            PocketAppendixFavoriteFeedback? = nil
    ) {
        let phase: PocketAppendixContentPhase
        switch previewContentState {
        case let .available(snapshot):
            phase = .available(snapshot)
        case let .unavailable(reason):
            phase = .unavailable(reason)
        }
        self.init(
            previewContentPhase: phase,
            previewFavoriteState:
                previewFavoriteState,
            previewQuery: previewQuery,
            previewCategory: previewCategory,
            previewFavoritesOnly: previewFavoritesOnly,
            previewFeedback: previewFeedback
        )
    }

    init(
        previewContentPhase:
            PocketAppendixContentPhase,
        previewFavoriteState:
            PocketAppendixFavoriteLoadState,
        previewQuery: String = "",
        previewCategory:
            OfflineContextualContentCategory? = nil,
        previewFavoritesOnly: Bool = false,
        previewFeedback:
            PocketAppendixFavoriteFeedback? = nil
    ) {
        self.contentLoader = .immediate(
            .unavailable(.missingResource)
        )
        self.favoritesAccessOverride = nil
        self.loadsOnTask = false
        _contentPhase = State(
            initialValue: previewContentPhase
        )
        _favoriteState = State(
            initialValue: previewFavoriteState
        )
        _query = State(initialValue: previewQuery)
        _selectedCategory = State(
            initialValue: previewCategory
        )
        _favoritesOnly = State(
            initialValue: previewFavoritesOnly
        )
        _favoriteFeedback = State(
            initialValue: previewFeedback
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            directory
                .navigationDestination(
                    for: PocketAppendixRoute.self
                ) { route in
                    destination(for: route)
                }
        }
        .sheet(item: $externalTarget) { target in
            FixedExternalLinkBoundaryView(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .interactiveDismissDisabled(
            writingContentID != nil
        )
        .task {
            guard loadsOnTask else { return }
            await loadFeature()
        }
        .onDisappear {
            query = ""
            selectedCategory = nil
            favoritesOnly = false
            path.removeAll()
            favoriteFeedback = nil
        }
        .accessibilityIdentifier(
            "pocketAppendix.sheet"
        )
    }

    @ViewBuilder
    private var directory: some View {
        switch contentPhase {
        case .loading:
            PocketAppendixLoadingView(
                close: dismiss.callAsFunction
            )
        case let .unavailable(reason):
            PocketAppendixUnavailableView(
                reason: reason,
                retry: {
                    Task { await loadFeature() }
                },
                close: dismiss.callAsFunction
            )
        case let .available(snapshot):
            let projection =
                PocketAppendixDirectoryProjection.make(
                    content: snapshot,
                    favoriteState: favoriteState,
                    query: query,
                    category: selectedCategory,
                    favoritesOnly: favoritesOnly
                )
            PocketAppendixDirectoryView(
                snapshot: snapshot,
                projection: projection,
                favoriteState: favoriteState,
                favoriteFeedback: favoriteFeedback,
                writingContentID: writingContentID,
                query: $query,
                selectedCategory: $selectedCategory,
                favoritesOnly: $favoritesOnly,
                close: dismiss.callAsFunction,
                openCard: {
                    path.append(.card($0))
                },
                openAttribution: {
                    path.append(.attribution(nil))
                },
                toggleFavorite: { card, fact in
                    Task {
                        await toggleFavorite(
                            card: card,
                            fact: fact
                        )
                    }
                },
                cancelUnavailableFavorite: { fact in
                    Task {
                        await toggleFavorite(
                            card: nil,
                            fact: fact
                        )
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func destination(
        for route: PocketAppendixRoute
    ) -> some View {
        switch contentPhase {
        case .loading, .unavailable:
            PocketAppendixRouteUnavailableView {
                path.removeLast()
            }
        case let .available(snapshot):
            switch route {
            case let .card(cardID):
                if let card = snapshot.cards(
                    for: .pocketAppendix
                ).first(where: { $0.id == cardID }) {
                    PocketAppendixReaderView(
                        snapshot: snapshot,
                        card: card,
                        favorite:
                            favoriteState.facts?.first {
                                $0.contentID == card.id
                            },
                        isWriting:
                            writingContentID == card.id,
                        favoriteIsAvailable:
                            favoriteState.facts != nil,
                        favoriteFeedback:
                            favoriteFeedback?.contentID
                                == card.id
                            ? favoriteFeedback
                            : nil,
                        openAttribution: {
                            path.append(
                                .attribution(card.id)
                            )
                        },
                        openExternal: {
                            externalTarget = $0
                        },
                        toggleFavorite: {
                            Task {
                                await toggleFavorite(
                                    card: card,
                                    fact:
                                        favoriteState.facts?
                                            .first {
                                                $0.contentID
                                                    == card.id
                                            }
                                )
                            }
                        }
                    )
                } else {
                    PocketAppendixRouteUnavailableView {
                        path.removeLast()
                    }
                }
            case let .attribution(cardID):
                PocketAppendixAttributionView(
                    snapshot: snapshot,
                    card: cardID.flatMap { id in
                        snapshot.cards.first {
                            $0.id == id
                        }
                    },
                    openExternal: {
                        externalTarget = $0
                    }
                )
            }
        }
    }

    private var resolvedFavoritesAccess:
        PocketAppendixFavoritesAccess? {
        if let favoritesAccessOverride {
            return favoritesAccessOverride
        }
        guard let appReadActor, let appDataWriter else {
            return nil
        }
        return PocketAppendixFavoritesAccess(
            load: {
                try await appReadActor
                    .contentFavoriteSnapshots()
            },
            set: {
                try await appDataWriter
                    .setContentFavorite($0)
            }
        )
    }

    private func loadFeature() async {
        contentPhase = .loading
        favoriteState = .loading
        favoriteFeedback = nil
        let loaded = await contentLoader.load()
        guard !Task.isCancelled else { return }
        switch loaded {
        case let .available(snapshot):
            contentPhase = .available(snapshot)
        case let .unavailable(reason):
            contentPhase = .unavailable(reason)
            favoriteState = .unavailable
            return
        }
        _ = await reloadFavorites()
    }

    @discardableResult
    private func reloadFavorites() async -> Bool {
        guard let access = resolvedFavoritesAccess else {
            favoriteState = .unavailable
            return false
        }
        do {
            let facts = try await access.load()
            guard !Task.isCancelled else { return false }
            favoriteState = .available(facts)
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            favoriteState = .unavailable
            return false
        }
    }

    private func toggleFavorite(
        card: OfflineContextualContentCardSnapshot?,
        fact: ContentFavoriteSnapshot?
    ) async {
        guard writingContentID == nil,
              favoriteState.facts != nil,
              let access = resolvedFavoritesAccess else {
            return
        }
        let contentID = card?.id ?? fact?.contentID
        guard let contentID else { return }
        let desiredFavorite = fact?.isFavorite != true
        let command: SetContentFavoriteCommand
        do {
            command = try PocketAppendixFavoriteCommandBuilder
                .make(
                    card: card,
                    fact: fact,
                    desiredFavorite: desiredFavorite,
                    operationID: UUID(),
                    newRecordID: UUID(),
                    committedAt: Date()
                )
        } catch {
            favoriteFeedback = .invalidState(
                contentID: contentID
            )
            AccessibilityNotification.Announcement(
                favoriteFeedback?.announcement
                    ?? "收藏没有改变"
            ).post()
            return
        }
        writingContentID = contentID
        favoriteFeedback = nil
        defer { writingContentID = nil }
        do {
            let result = try await access.set(command)
            guard !Task.isCancelled else { return }
            replaceFavorite(result.snapshot)
            NotificationCenter.default.post(
                name: .unmanualLocalDataChanged,
                object: nil
            )
            favoriteFeedback = .success(
                contentID: contentID,
                isFavorite: result.snapshot.isFavorite
            )
            AccessibilityNotification.Announcement(
                favoriteFeedback?.announcement
                    ?? "收藏状态已更新"
            ).post()
        } catch let error as ContentFavoriteWriteFailure
            where error == .staleRecord
                || error == .operationConflict {
            let reloadSucceeded =
                await reloadFavorites()
            favoriteFeedback = .conflict(
                contentID: contentID,
                reloadSucceeded: reloadSucceeded
            )
            AccessibilityNotification.Announcement(
                favoriteFeedback?.announcement
                    ?? "收藏状态已更新"
            ).post()
        } catch {
            favoriteFeedback = .writeFailure(
                contentID: contentID
            )
            AccessibilityNotification.Announcement(
                favoriteFeedback?.announcement
                    ?? "收藏没有改变"
            ).post()
        }
    }

    private func replaceFavorite(
        _ snapshot: ContentFavoriteSnapshot
    ) {
        guard case let .available(facts) =
                favoriteState else {
            return
        }
        var next = facts.filter {
            $0.contentID != snapshot.contentID
        }
        next.append(snapshot)
        next.sort {
            ($0.createdAt, $0.contentID)
                < ($1.createdAt, $1.contentID)
        }
        favoriteState = .available(next)
    }
}

private struct PocketAppendixDirectoryView: View {
    @Environment(AppTheme.self) private var theme

    let snapshot: OfflineContextualContentSnapshot
    let projection: PocketAppendixDirectoryProjection
    let favoriteState: PocketAppendixFavoriteLoadState
    let favoriteFeedback:
        PocketAppendixFavoriteFeedback?
    let writingContentID: String?
    @Binding var query: String
    @Binding var selectedCategory:
        OfflineContextualContentCategory?
    @Binding var favoritesOnly: Bool
    let close: () -> Void
    let openCard: (String) -> Void
    let openAttribution: () -> Void
    let toggleFavorite: (
        OfflineContextualContentCardSnapshot,
        ContentFavoriteSnapshot?
    ) -> Void
    let cancelUnavailableFavorite:
        (ContentFavoriteSnapshot) -> Void

    var body: some View {
        List {
            header
                .pocketAppendixListRow(theme: theme)

            filters
                .pocketAppendixListRow(theme: theme)

            if favoriteState == .loading {
                statusMessage(
                    "正在核对本机收藏",
                    detail:
                        "摘要已经可以阅读；收藏核对完成前，收藏操作暂不可用。",
                    isError: false
                )
                .pocketAppendixListRow(theme: theme)
            } else if favoriteState == .unavailable {
                statusMessage(
                    "收藏资料暂不可用",
                    detail:
                        "收藏状态没有通过完整性检查；这里不会把失败显示成零收藏。",
                    isError: true
                )
                .pocketAppendixListRow(theme: theme)
            }

            if let favoriteFeedback {
                statusMessage(
                    favoriteFeedback.title,
                    detail: favoriteFeedback.message,
                    isError: favoriteFeedback.isError
                )
                .pocketAppendixListRow(theme: theme)
                .accessibilityIdentifier(
                    "pocketAppendix.favoriteFeedback"
                )
            }

            resultSummary
                .pocketAppendixListRow(theme: theme)

            if let issue = projection.queryIssue {
                queryIssue(issue)
                    .pocketAppendixListRow(theme: theme)
            } else if let empty = projection.emptyState {
                emptyState(empty)
                    .pocketAppendixListRow(theme: theme)
            } else {
                ForEach(projection.cards) { card in
                    PocketAppendixCardRow(
                        card: card,
                        favorite:
                            projection
                            .factsByContentID[card.id],
                        isWriting:
                            writingContentID == card.id,
                        favoriteIsAvailable:
                            favoriteState.facts != nil,
                        open: { openCard(card.id) },
                        toggleFavorite: {
                            toggleFavorite(
                                card,
                                projection
                                    .factsByContentID[
                                        card.id
                                    ]
                            )
                        }
                    )
                    .pocketAppendixListRow(theme: theme)
                }
            }

            if !projection.unavailableFavorites.isEmpty {
                V25SectionHeader(
                    title: "收藏内容当前不可用",
                    detail:
                        "\(projection.unavailableFavorites.count) 项"
                )
                .pocketAppendixListRow(theme: theme)
                ForEach(
                    projection.unavailableFavorites,
                    id: \.id
                ) { fact in
                    PocketAppendixUnavailableFavoriteRow(
                        fact: fact,
                        isWriting:
                            writingContentID
                                == fact.contentID,
                        cancel: {
                            cancelUnavailableFavorite(fact)
                        }
                    )
                    .pocketAppendixListRow(theme: theme)
                }
            }

            Button(
                "内容来源与许可",
                action: openAttribution
            )
            .buttonStyle(V25SecondaryButtonStyle())
            .accessibilityIdentifier(
                "pocketAppendix.attribution"
            )
            .pocketAppendixListRow(theme: theme)

            V25PrivacyFooter(
                text:
                    "搜索词只留在当前附页内存；公共摘要不写入病历，只有收藏作为敏感本地事实保存。"
            )
            .pocketAppendixListRow(theme: theme)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.rice.ignoresSafeArea())
        .searchable(
            text: $query,
            placement:
                .navigationBarDrawer(
                    displayMode: .always
                ),
            prompt: Text("搜索离线摘要")
        )
        .navigationTitle("随身附页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.paper, for: .navigationBar)
        .toolbarBackground(
            .visible,
            for: .navigationBar
        )
        .accessibilityIdentifier(
            "pocketAppendix.directory"
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("POCKET / APPENDIX")
                    .font(theme.utility(10))
                    .tracking(0.9)
                    .foregroundStyle(theme.vermilionText)
                Spacer(minLength: 8)
                Button("关闭附页", action: close)
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.indigo)
                    .frame(minWidth: 76, minHeight: 44)
                    .background(theme.paper)
                    .overlay {
                        Rectangle().stroke(
                            theme.indigo,
                            lineWidth: 1.5
                        )
                    }
                    .buttonStyle(V25PressStyle())
                    .disabled(writingContentID != nil)
                    .accessibilityIdentifier(
                        "pocketAppendix.close"
                    )
            }
            Text("附页目录")
                .font(
                    theme.display(
                        34,
                        relativeTo: .largeTitle
                    )
                )
            Text(
                "在本机查找必要摘要。完整文章仍由网站承担；这里不会根据你的药名、数值或备注猜测主题。"
            )
            .font(.body)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(
                horizontal: false,
                vertical: true
            )
            Text(
                "搜索范围：标题、别名、分类和摘要。关闭随身附页后，搜索词会被丢弃。"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.blueText)
            .fixedSize(
                horizontal: false,
                vertical: true
            )
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.indigo)
                .frame(height: 2)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            V25FieldSurface(
                "分类",
                note: "分类与收藏只改变可见集合，不改变搜索排序。"
            ) {
                Picker(
                    "分类",
                    selection: $selectedCategory
                ) {
                    Text("全部分类")
                        .tag(
                            nil as
                                OfflineContextualContentCategory?
                        )
                    ForEach(
                        OfflineContextualContentCategory
                            .allCases,
                        id: \.self
                    ) {
                        Text($0.displayTitle)
                            .tag(
                                Optional<
                                    OfflineContextualContentCategory
                                >($0)
                            )
                    }
                }
                .pickerStyle(.menu)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44,
                    alignment: .leading
                )
                .accessibilityIdentifier(
                    "pocketAppendix.category"
                )
            }

            Toggle(
                "只看收藏",
                isOn: $favoritesOnly
            )
            .font(.body.weight(.black))
            .tint(theme.indigo)
            .frame(minHeight: 44)
            .disabled(favoriteState.facts == nil)
            .accessibilityValue(
                favoritesOnly ? "已开启" : "已关闭"
            )
            .accessibilityIdentifier(
                "pocketAppendix.favoritesOnly"
            )
        }
        .padding(.vertical, 4)
    }

    private var resultSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(
                query.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                ? "附页目录"
                : "搜索结果"
            )
            .font(.headline.weight(.black))
            Spacer(minLength: 12)
            Text(projection.resultCountLabel)
                .font(theme.utility(10))
                .foregroundStyle(theme.secondaryText)
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "pocketAppendix.resultSummary"
        )
    }

    private func queryIssue(
        _ issue: OfflineContextualContentQueryIssue
    ) -> some View {
        let detail =
            issue == .tooLong
            ? "搜索词最多 80 个字符；这里不会截断后继续搜索。"
            : "搜索词最多拆成 8 个非空词；请减少关键词后再试。"
        return statusMessage(
            "搜索词需要调整",
            detail: detail,
            isError: true
        )
        .accessibilityIdentifier(
            "pocketAppendix.queryIssue"
        )
    }

    private func emptyState(
        _ state: PocketAppendixDirectoryEmptyState
    ) -> some View {
        let title: String
        let detail: String
        switch state {
        case .noResults:
            title = "没有匹配的离线摘要"
            detail =
                "可以清除搜索词、改回全部分类，或关闭“只看收藏”。"
        case .noFavorites:
            title = "还没有收藏"
            detail =
                "关闭“只看收藏”后可以查看全部附页，并在需要时收藏。"
        case .favoritesUnavailable:
            title = "收藏资料暂不可用"
            detail =
                "收藏状态没有通过完整性检查；这里不会显示成零收藏。"
        }
        return V25EmptyState(
            eyebrow: "EMPTY / NEXT",
            title: title,
            detail: detail
        )
        .accessibilityIdentifier(
            "pocketAppendix.emptyState"
        )
    }

    private func statusMessage(
        _ title: String,
        detail: String,
        isError: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(
                    isError
                        ? theme.vermilion
                        : theme.blue
                )
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(
                        theme.secondaryText
                    )
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
                isError
                    ? theme.vermilion
                    : theme.indigo,
                lineWidth: 1.5
            )
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PocketAppendixCardRow: View {
    @Environment(AppTheme.self) private var theme

    let card: OfflineContextualContentCardSnapshot
    let favorite: ContentFavoriteSnapshot?
    let isWriting: Bool
    let favoriteIsAvailable: Bool
    let open: () -> Void
    let toggleFavorite: () -> Void

    private var isFavorite: Bool {
        favorite?.isFavorite == true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: 8
                    ) {
                        Text(
                            PocketAppendixDisplayOrder
                                .label(card.displayOrder)
                        )
                        .font(theme.utility(9))
                        .foregroundStyle(
                            theme.vermilionText
                        )
                        Text(card.title)
                            .font(.body.weight(.black))
                            .multilineTextAlignment(
                                .leading
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                    Text(card.category.displayTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.blueText)
                    if let label = card.status.visibleLabel {
                        Text(label)
                            .font(.caption.weight(.black))
                            .foregroundStyle(
                                card.status
                                    == .sourceUnavailable
                                    ? theme.vermilionText
                                    : theme.mustardText
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                    Text(card.summary)
                        .font(.caption)
                        .foregroundStyle(
                            theme.secondaryText
                        )
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(theme.indigoDeep)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                PocketAppendixCardAccessibility
                    .label(card)
            )
            .accessibilityIdentifier(
                "pocketAppendix.card.\(card.id)"
            )

            Button(action: toggleFavorite) {
                VStack(spacing: 4) {
                    if isWriting {
                        ProgressView()
                    } else {
                        Image(
                            systemName:
                                !favoriteIsAvailable
                                ? "bookmark.slash"
                                : isFavorite
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                        .font(.body.weight(.bold))
                    }
                    Text(
                        !favoriteIsAvailable
                            ? "待核对"
                            : isFavorite
                            ? "已收藏"
                            : "收藏"
                    )
                    .font(.caption2.weight(.black))
                }
                .frame(minWidth: 58, minHeight: 52)
                .foregroundStyle(
                    isFavorite
                        ? theme.paper
                        : theme.indigo
                )
                .background(
                    isFavorite
                        ? theme.indigo
                        : theme.paper
                )
                .overlay {
                    Rectangle().stroke(
                        theme.indigo,
                        lineWidth: 1.5
                    )
                }
            }
            .buttonStyle(V25PressStyle())
            .disabled(
                !favoriteIsAvailable || isWriting
            )
            .opacity(
                favoriteIsAvailable ? 1 : 0.46
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
                "pocketAppendix.favorite.\(card.id)"
            )
        }
        .padding(12)
        .background(theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.indigo)
                .frame(height: 1)
        }
    }
}

private struct PocketAppendixUnavailableFavoriteRow:
    View {
    @Environment(AppTheme.self) private var theme

    let fact: ContentFavoriteSnapshot
    let isWriting: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("收藏内容当前不可用")
                .font(.headline.weight(.black))
            Text(
                "稳定内容 ID：\(fact.contentID)。当前内容包没有这张卡；这里不会按同名内容替换。"
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(
                horizontal: false,
                vertical: true
            )
            Button(
                isWriting ? "正在取消" : "取消这项收藏",
                action: cancel
            )
            .buttonStyle(V25SecondaryButtonStyle())
            .disabled(isWriting)
            .accessibilityValue("已收藏")
            .accessibilityIdentifier(
                "pocketAppendix.unavailableFavorite."
                    + fact.contentID
            )
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
    }
}

private struct PocketAppendixLoadingView: View {
    @Environment(AppTheme.self) private var theme
    let close: () -> Void

    var body: some View {
        V25EditorPage(
            register: "POCKET / LOADING",
            eyebrow: "随身附页",
            title: "正在核对离线内容",
            detail:
                "会先验证完整内容包，再读取这台设备上的收藏。",
            cancel: close
        ) {
            ProgressView()
                .frame(
                    maxWidth: .infinity,
                    minHeight: 160
                )
            V25PrivacyFooter(
                text:
                    "不会联网，也不会把搜索词、内容或收藏写入日志。"
            )
        }
        .accessibilityIdentifier(
            "pocketAppendix.loading"
        )
    }
}

private struct PocketAppendixUnavailableView: View {
    @Environment(AppTheme.self) private var theme

    let reason: OfflineContextualContentUnavailableReason
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        V25EditorPage(
            register: "POCKET / UNAVAILABLE",
            eyebrow: "随身附页",
            title: "离线内容暂不可用",
            detail: reason.detail,
            cancel: close
        ) {
            V25EmptyState(
                eyebrow: "FAIL CLOSED",
                title: reason.title,
                detail:
                    "这里不会显示部分内容，也不会把审核门禁伪装成零条结果。"
            )
            Button("重新核对", action: retry)
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier(
                    "pocketAppendix.retry"
                )
            V25PrivacyFooter(
                text:
                    "现有个人记录和收藏事实没有被自动删除。"
            )
        }
        .accessibilityIdentifier(
            "pocketAppendix.unavailable"
        )
    }
}

private struct PocketAppendixRouteUnavailableView:
    View {
    let back: () -> Void

    var body: some View {
        V25EditorPage(
            register: "POCKET / ROUTE",
            eyebrow: "随身附页",
            title: "这项内容当前不可用",
            detail:
                "当前已校验内容包中没有这张卡。",
            cancel: back
        ) {
            V25PrivacyFooter(
                text:
                    "不会用标题相近的内容代替稳定内容 ID。"
            )
        }
        .accessibilityIdentifier(
            "pocketAppendix.routeUnavailable"
        )
    }
}

private extension View {
    func pocketAppendixListRow(
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

extension OfflineContextualContentCardStatus {
    var visibleLabel: String? {
        switch self {
        case .current:
            nil
        case .stale:
            "需要重新核验"
        case .sourceUnavailable:
            "来源入口当前不可用"
        case .unavailable:
            "内容当前不可用"
        }
    }
}

private extension OfflineContextualContentUnavailableReason {
    var title: String {
        switch self {
        case .missingResource:
            "没有找到可用内容包"
        case .pendingHumanReviewAndClassification:
            "仍待真实人类复核"
        case .rejectedByHumanReview:
            "这批内容未获批准"
        case .invalidContent:
            "内容没有通过完整性检查"
        case .unreadableContent:
            "内容文件无法读取"
        }
    }

    var detail: String {
        switch self {
        case .missingResource:
            "当前版本没有包含可供阅读的正式离线摘要。"
        case .pendingHumanReviewAndClassification:
            "内容、医疗或发行分类复核尚未完成；Release 不会回退到候选内容。"
        case .rejectedByHumanReview:
            "这批内容已被拒绝，因此不会展示摘要。"
        case .invalidContent:
            "内容包的结构、来源、许可或摘要没有通过同一次核对。"
        case .unreadableContent:
            "本机无法完整读取内容文件，请稍后重试。"
        }
    }
}
