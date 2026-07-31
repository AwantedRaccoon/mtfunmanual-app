import Foundation

enum PocketAppendixDisplayOrder {
    static func label(_ authoredOrder: Int) -> String {
        String(format: "%02d", authoredOrder)
    }
}

enum PocketAppendixCardAccessibility {
    static func label(
        _ card: OfflineContextualContentCardSnapshot
    ) -> String {
        [
            card.title,
            card.status.visibleLabel,
            "查看离线摘要"
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

enum PocketAppendixFavoriteAccessibility {
    static func label(
        isFavorite: Bool,
        isAvailable: Bool
    ) -> String {
        guard isAvailable else {
            return "收藏状态暂时无法核对"
        }
        return isFavorite ? "取消收藏" : "收藏"
    }

    static func value(
        isFavorite: Bool,
        isAvailable: Bool
    ) -> String {
        guard isAvailable else { return "未知" }
        return isFavorite ? "已收藏" : "未收藏"
    }
}

struct PocketAppendixAttributionDisclosure:
    Equatable, Sendable {
    let sourceRepository: String
    let licenseURL: String
    let cardAdaptationStatus:
        OfflineContextualContentAdaptationStatus?

    static func make(
        snapshot: OfflineContextualContentSnapshot,
        card: OfflineContextualContentCardSnapshot?
    ) -> Self {
        Self(
            sourceRepository:
                snapshot.attribution.sourceRepository,
            licenseURL:
                snapshot.attribution.licenseURL,
            cardAdaptationStatus:
                card?.card.provenance.adaptationStatus
        )
    }
}

struct PocketAppendixFavoriteFeedback:
    Equatable, Sendable {
    let contentID: String
    let title: String
    let message: String
    let announcement: String
    let isError: Bool

    static func success(
        contentID: String,
        isFavorite: Bool
    ) -> Self {
        let message =
            isFavorite ? "已收藏" : "已取消收藏"
        return Self(
            contentID: contentID,
            title: "收藏",
            message: message,
            announcement: message,
            isError: false
        )
    }

    static func conflict(
        contentID: String,
        reloadSucceeded: Bool
    ) -> Self {
        let message =
            reloadSucceeded
            ? "收藏状态已在另一处更新，请重新操作。"
            : "收藏状态已在另一处更新，但本机收藏暂时无法重新核对。"
        return Self(
            contentID: contentID,
            title:
                reloadSucceeded
                ? "收藏状态已刷新"
                : "收藏状态需要核对",
            message: message,
            announcement:
                reloadSucceeded
                ? "收藏状态已更新"
                : "收藏状态暂时无法重新核对",
            isError: true
        )
    }

    static func invalidState(
        contentID: String
    ) -> Self {
        Self(
            contentID: contentID,
            title: "收藏没有改变",
            message:
                "这项内容当前无法核对，收藏状态没有改变。",
            announcement: "收藏没有改变",
            isError: true
        )
    }

    static func writeFailure(
        contentID: String
    ) -> Self {
        Self(
            contentID: contentID,
            title: "收藏没有改变",
            message:
                "收藏资料没有通过完整核对，现有摘要仍可离线阅读。",
            announcement: "收藏没有改变",
            isError: true
        )
    }
}

enum PocketAppendixFavoriteLoadState:
    Equatable, Sendable {
    case loading
    case available([ContentFavoriteSnapshot])
    case unavailable

    var facts: [ContentFavoriteSnapshot]? {
        guard case let .available(facts) = self else {
            return nil
        }
        return facts
    }
}

struct PocketAppendixSourceMetadata:
    Equatable, Sendable {
    let retrievedAt: String
    let expiresAt: String
    let statusLabel: String
    let applicableRegionsLabel: String
    let applicablePopulationsLabel: String

    static func make(
        source: OfflineContextualContentSource,
        statusDate: Date
    ) -> Self {
        let status =
            OfflineContextualContentSourceLinkStatus.resolve(
                source,
                statusDate: statusDate
            )
        let statusLabel: String
        switch status {
        case .current:
            statusLabel = "当前"
        case .needsReverification:
            statusLabel = "需要重新核验"
        case .unavailable:
            statusLabel = "来源不可用"
        }
        return Self(
            retrievedAt: source.retrievedAt,
            expiresAt: source.expiresAt,
            statusLabel: statusLabel,
            applicableRegionsLabel:
                joinedMetadataValues(
                    source.applicableRegions
                ),
            applicablePopulationsLabel:
                joinedMetadataValues(
                    source.applicablePopulations
                )
        )
    }

    private static func joinedMetadataValues(
        _ values: [String]
    ) -> String {
        values.isEmpty
            ? "未注明"
            : values.joined(separator: "、")
    }
}

enum PocketAppendixDirectoryEmptyState:
    Equatable, Sendable {
    case noResults
    case noFavorites
    case favoritesUnavailable
}

struct PocketAppendixDirectoryProjection:
    Equatable, Sendable {
    let cards: [OfflineContextualContentCardSnapshot]
    let unavailableFavorites: [ContentFavoriteSnapshot]
    let activeFavoriteIDs: Set<String>
    let factsByContentID: [String: ContentFavoriteSnapshot]
    let queryIssue: OfflineContextualContentQueryIssue?
    let emptyState: PocketAppendixDirectoryEmptyState?

    var resultCountLabel: String {
        guard !unavailableFavorites.isEmpty else {
            return "\(cards.count) 项"
        }
        return "\(cards.count) 张摘要 + "
            + "\(unavailableFavorites.count) 条待核对收藏"
    }

    static func make(
        content: OfflineContextualContentSnapshot,
        favoriteState: PocketAppendixFavoriteLoadState,
        query: String,
        category: OfflineContextualContentCategory?,
        favoritesOnly: Bool
    ) -> Self {
        let facts = favoriteState.facts ?? []
        let factsByContentID = facts.reduce(
            into: [String: ContentFavoriteSnapshot]()
        ) {
            $0[$1.contentID] = $1
        }
        let activeFacts = facts.filter(\.isFavorite)
        let activeFavoriteIDs = Set(
            activeFacts.map(\.contentID)
        )
        let pocketCards = content.cards(
            for: .pocketAppendix
        )
        let pocketIDs = Set(pocketCards.map(\.id))
        let allUnavailableFavorites = activeFacts
            .filter { !pocketIDs.contains($0.contentID) }
            .sorted {
                ($0.createdAt, $0.contentID)
                    < ($1.createdAt, $1.contentID)
            }
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let unavailableFavorites =
            normalizedQuery.isEmpty && category == nil
            ? allUnavailableFavorites
            : []

        guard favoriteState.facts != nil
                || !favoritesOnly else {
            return Self(
                cards: [],
                unavailableFavorites: [],
                activeFavoriteIDs: [],
                factsByContentID: [:],
                queryIssue: nil,
                emptyState: .favoritesUnavailable
            )
        }

        let search = OfflineContextualContentSearch.search(
            cards: pocketCards,
            query: query,
            category: category,
            favoriteIDs: activeFavoriteIDs,
            favoritesOnly: favoritesOnly
        )
        let emptyState:
            PocketAppendixDirectoryEmptyState?
        if search.issue != nil {
            emptyState = nil
        } else if !search.cards.isEmpty
                    || (
                        favoritesOnly
                            && !unavailableFavorites.isEmpty
                    ) {
            emptyState = nil
        } else if favoritesOnly
                    && activeFavoriteIDs.isEmpty {
            emptyState = .noFavorites
        } else {
            emptyState = .noResults
        }
        return Self(
            cards: search.cards,
            unavailableFavorites: unavailableFavorites,
            activeFavoriteIDs: activeFavoriteIDs,
            factsByContentID: factsByContentID,
            queryIssue: search.issue,
            emptyState: emptyState
        )
    }
}

enum PocketAppendixFavoriteCommandError:
    Error, Equatable, Sendable {
    case contentUnavailable
    case invalidState
}

enum PocketAppendixFavoriteCommandBuilder {
    static func make(
        card: OfflineContextualContentCardSnapshot?,
        fact: ContentFavoriteSnapshot?,
        desiredFavorite: Bool,
        operationID: UUID,
        newRecordID: UUID,
        committedAt: Date
    ) throws -> SetContentFavoriteCommand {
        if let card, let fact,
           card.id != fact.contentID {
            throw PocketAppendixFavoriteCommandError.invalidState
        }
        if desiredFavorite {
            guard let card else {
                throw PocketAppendixFavoriteCommandError
                    .contentUnavailable
            }
            guard fact?.isFavorite != true else {
                throw PocketAppendixFavoriteCommandError.invalidState
            }
            return SetContentFavoriteCommand(
                operationID: operationID,
                recordID: fact?.id ?? newRecordID,
                contentID: card.id,
                contentVersion: card.card.contentVersion,
                cardDigest: card.card.cardDigest,
                desiredFavorite: true,
                expectedLocalRevision:
                    fact?.localRevision,
                expectedDigestHex: fact?.digestHex,
                committedAt: committedAt
            )
        }

        guard let fact, fact.isFavorite else {
            throw PocketAppendixFavoriteCommandError.invalidState
        }
        return SetContentFavoriteCommand(
            operationID: operationID,
            recordID: fact.id,
            contentID: fact.contentID,
            contentVersion: fact.contentVersion,
            cardDigest: fact.cardDigest,
            desiredFavorite: false,
            expectedLocalRevision: fact.localRevision,
            expectedDigestHex: fact.digestHex,
            committedAt: committedAt
        )
    }
}
