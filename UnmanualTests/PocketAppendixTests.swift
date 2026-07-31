import Foundation
import XCTest
@testable import Unmanual

final class PocketAppendixTests: XCTestCase {
    private let activeDigest =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let currentDigest =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    func testSourceLinkStatusUsesInjectedUTCStatusDate() throws {
        let source = try XCTUnwrap(contentSnapshot().sources.first)
        let expiry = try XCTUnwrap(
            UTCDateParser.date(source.expiresAt)
        )
        let nextDay = try XCTUnwrap(
            UTCDateParser.calendar.date(
                byAdding: .day,
                value: 1,
                to: expiry
            )
        )

        XCTAssertEqual(
            OfflineContextualContentSourceLinkStatus.resolve(
                source,
                statusDate: expiry
            ),
            .current
        )
        XCTAssertEqual(
            OfflineContextualContentSourceLinkStatus.resolve(
                source,
                statusDate: nextDay
            ),
            .needsReverification
        )
        XCTAssertEqual(
            OfflineContextualContentSourceLinkStatus.resolve(
                sourceWithStatus(
                    source,
                    status: .knownUnavailable
                ),
                statusDate: expiry
            ),
            .unavailable
        )
    }

    func testSourceMetadataExposesDatesStatusRegionsAndPopulations()
        throws {
        let source = try XCTUnwrap(contentSnapshot().sources.first)
        let expiry = try XCTUnwrap(
            UTCDateParser.date(source.expiresAt)
        )
        let nextDay = try XCTUnwrap(
            UTCDateParser.calendar.date(
                byAdding: .day,
                value: 1,
                to: expiry
            )
        )

        let current = PocketAppendixSourceMetadata.make(
            source: source,
            statusDate: expiry
        )
        XCTAssertEqual(current.retrievedAt, source.retrievedAt)
        XCTAssertEqual(current.expiresAt, source.expiresAt)
        XCTAssertEqual(current.statusLabel, "当前")
        XCTAssertEqual(
            current.applicableRegionsLabel,
            source.applicableRegions.joined(separator: "、")
        )
        XCTAssertEqual(
            current.applicablePopulationsLabel,
            source.applicablePopulations.joined(
                separator: "、"
            )
        )

        XCTAssertEqual(
            PocketAppendixSourceMetadata.make(
                source: source,
                statusDate: nextDay
            ).statusLabel,
            "需要重新核验"
        )
        XCTAssertEqual(
            PocketAppendixSourceMetadata.make(
                source: sourceWithStatus(
                    source,
                    status: .knownUnavailable
                ),
                statusDate: expiry
            ).statusLabel,
            "来源不可用"
        )
    }

    func testDisplayOrderUsesAuthoredOneBasedValue() {
        XCTAssertEqual(
            PocketAppendixDisplayOrder.label(1),
            "01"
        )
        XCTAssertEqual(
            PocketAppendixDisplayOrder.label(48),
            "48"
        )
    }

    func testCardAccessibilityIncludesVisibleContentStatus()
        throws {
        let card = try XCTUnwrap(
            contentSnapshot()
                .cards(for: .pocketAppendix).first
        )
        let stale =
            OfflineContextualContentCardSnapshot(
                card: card.card,
                sources: card.sources,
                status: .stale
            )
        let unavailable =
            OfflineContextualContentCardSnapshot(
                card: card.card,
                sources: card.sources,
                status: .sourceUnavailable
            )

        XCTAssertEqual(
            PocketAppendixCardAccessibility.label(stale),
            "\(card.title)，需要重新核验，查看离线摘要"
        )
        XCTAssertEqual(
            PocketAppendixCardAccessibility.label(
                unavailable
            ),
            "\(card.title)，来源入口当前不可用，查看离线摘要"
        )
    }

    func testAttributionDisclosureIncludesExactURLsAndPerCardAdaptation()
        throws {
        let snapshot = contentSnapshot()
        let card = try XCTUnwrap(
            snapshot.cards(for: .pocketAppendix).first
        )
        let disclosure =
            PocketAppendixAttributionDisclosure.make(
                snapshot: snapshot,
                card: card
            )

        XCTAssertEqual(
            disclosure.sourceRepository,
            snapshot.attribution.sourceRepository
        )
        XCTAssertEqual(
            disclosure.licenseURL,
            snapshot.attribution.licenseURL
        )
        XCTAssertEqual(
            disclosure.cardAdaptationStatus,
            card.card.provenance.adaptationStatus
        )
    }

    func testFavoriteFeedbackDistinguishesConflictReloadFailure()
        {
        XCTAssertEqual(
            PocketAppendixFavoriteFeedback
                .conflict(
                    contentID: "card.test",
                    reloadSucceeded: true
                )
                .message,
            "收藏状态已在另一处更新，请重新操作。"
        )
        XCTAssertEqual(
            PocketAppendixFavoriteFeedback
                .conflict(
                    contentID: "card.test",
                    reloadSucceeded: false
                )
                .message,
            "收藏状态已在另一处更新，但本机收藏暂时无法重新核对。"
        )
        XCTAssertEqual(
            PocketAppendixFavoriteFeedback
                .writeFailure(contentID: "card.test")
                .announcement,
            "收藏没有改变"
        )
    }

    func testFavoriteAccessibilityNeverTreatsUnavailableAsNotFavorite() {
        XCTAssertEqual(
            PocketAppendixFavoriteAccessibility.label(
                isFavorite: false,
                isAvailable: false
            ),
            "收藏状态暂时无法核对"
        )
        XCTAssertEqual(
            PocketAppendixFavoriteAccessibility.value(
                isFavorite: false,
                isAvailable: false
            ),
            "未知"
        )
        XCTAssertEqual(
            PocketAppendixFavoriteAccessibility.value(
                isFavorite: false,
                isAvailable: true
            ),
            "未收藏"
        )
        XCTAssertEqual(
            PocketAppendixFavoriteAccessibility.value(
                isFavorite: true,
                isAvailable: true
            ),
            "已收藏"
        )
    }

    func testExternalTargetsPreserveFixedURLsAndDisableUnavailableSource()
        throws {
        let snapshot = contentSnapshot()
        let source = try XCTUnwrap(snapshot.sources.first)
        let expiry = try XCTUnwrap(
            UTCDateParser.date(source.expiresAt)
        )
        let nextDay = try XCTUnwrap(
            UTCDateParser.calendar.date(
                byAdding: .day,
                value: 1,
                to: expiry
            )
        )

        let current = try XCTUnwrap(
            PocketAppendixExternalTargetFactory.source(
                source,
                statusDate: expiry
            )
        )
        XCTAssertEqual(current.urlString, source.url)
        XCTAssertEqual(current.freshness, .current)
        XCTAssertNil(current.url?.query)
        XCTAssertNil(current.url?.fragment)

        let stale = try XCTUnwrap(
            PocketAppendixExternalTargetFactory.source(
                source,
                statusDate: nextDay
            )
        )
        XCTAssertEqual(
            stale.freshness,
            .needsReverification
        )
        XCTAssertNil(
            PocketAppendixExternalTargetFactory.source(
                sourceWithStatus(
                    source,
                    status: .knownUnavailable
                ),
                statusDate: expiry
            )
        )

        let card = try XCTUnwrap(
            snapshot.cards(for: .pocketAppendix).first
        )
        let original =
            PocketAppendixExternalTargetFactory.original(card)
        XCTAssertEqual(
            original.urlString,
            card.card.originalURL
        )
        XCTAssertNil(original.url?.query)
        XCTAssertNil(original.url?.fragment)
    }

    func testDirectoryProjectionUsesPocketAnchorsAndSeparatesUnavailableFavorite()
        throws {
        let snapshot = contentSnapshot()
        let first = try XCTUnwrap(
            snapshot.cards(for: .pocketAppendix).first
        )
        let missing = favorite(
            id: UUID(),
            contentID: "card.removed-from-pack",
            isFavorite: true
        )
        let projection = PocketAppendixDirectoryProjection.make(
            content: snapshot,
            favoriteState: .available([
                favorite(
                    id: UUID(),
                    contentID: first.id,
                    isFavorite: true
                ),
                missing
            ]),
            query: "",
            category: nil,
            favoritesOnly: false
        )

        XCTAssertEqual(
            projection.cards.map(\.id),
            snapshot.cards(for: .pocketAppendix).map(\.id)
        )
        XCTAssertEqual(
            projection.activeFavoriteIDs,
            Set([first.id, missing.contentID])
        )
        XCTAssertEqual(
            projection.unavailableFavorites,
            [missing]
        )
        XCTAssertNil(projection.emptyState)
        XCTAssertNil(projection.queryIssue)
    }

    func testDirectoryProjectionHidesUnavailableFavoritesUnderSearchOrCategory()
        throws {
        let snapshot = contentSnapshot()
        let missing = favorite(
            id: UUID(),
            contentID: "card.removed-from-pack",
            isFavorite: true
        )

        let searched = PocketAppendixDirectoryProjection.make(
            content: snapshot,
            favoriteState: .available([missing]),
            query: "化验",
            category: nil,
            favoritesOnly: true
        )
        XCTAssertTrue(searched.unavailableFavorites.isEmpty)

        let categorized = PocketAppendixDirectoryProjection.make(
            content: snapshot,
            favoriteState: .available([missing]),
            query: "",
            category: .hrtAndCare,
            favoritesOnly: true
        )
        XCTAssertTrue(categorized.unavailableFavorites.isEmpty)
    }

    func testDirectoryResultSummarySeparatesCardsAndUnavailableFavorites()
        throws {
        let snapshot = contentSnapshot()
        let missing = favorite(
            id: UUID(),
            contentID: "card.removed-from-pack",
            isFavorite: true
        )
        let projection = PocketAppendixDirectoryProjection.make(
            content: snapshot,
            favoriteState: .available([missing]),
            query: "",
            category: nil,
            favoritesOnly: false
        )

        XCTAssertEqual(
            projection.resultCountLabel,
            "\(projection.cards.count) 张摘要 + 1 条待核对收藏"
        )
    }

    func testDirectoryProjectionDistinguishesQueryIssueNoResultNoFavoriteAndFavoriteFailure()
        throws {
        let snapshot = contentSnapshot()
        let tooLong = String(repeating: "字", count: 81)

        let invalidQuery = PocketAppendixDirectoryProjection.make(
            content: snapshot,
            favoriteState: .available([]),
            query: tooLong,
            category: nil,
            favoritesOnly: false
        )
        XCTAssertEqual(invalidQuery.queryIssue, .tooLong)
        XCTAssertNil(invalidQuery.emptyState)

        let noResult = PocketAppendixDirectoryProjection.make(
            content: snapshot,
            favoriteState: .available([]),
            query: "definitely-no-such-card",
            category: nil,
            favoritesOnly: false
        )
        XCTAssertEqual(noResult.emptyState, .noResults)

        let noFavorite = PocketAppendixDirectoryProjection.make(
            content: snapshot,
            favoriteState: .available([]),
            query: "",
            category: nil,
            favoritesOnly: true
        )
        XCTAssertEqual(noFavorite.emptyState, .noFavorites)

        let favoriteFailure =
            PocketAppendixDirectoryProjection.make(
                content: snapshot,
                favoriteState: .unavailable,
                query: "",
                category: nil,
                favoritesOnly: true
            )
        XCTAssertEqual(
            favoriteFailure.emptyState,
            .favoritesUnavailable
        )
    }

    func testFirstFavoriteUsesCurrentCardAndNilExpectedTokens()
        throws {
        let card = try XCTUnwrap(
            contentSnapshot()
                .cards(for: .pocketAppendix).first
        )
        let operationID = UUID()
        let recordID = UUID()
        let committedAt = Date(
            timeIntervalSince1970: 1_800_800_000
        )

        let command = try PocketAppendixFavoriteCommandBuilder
            .make(
                card: card,
                fact: nil,
                desiredFavorite: true,
                operationID: operationID,
                newRecordID: recordID,
                committedAt: committedAt
            )

        XCTAssertEqual(command.operationID, operationID)
        XCTAssertEqual(command.recordID, recordID)
        XCTAssertEqual(command.contentID, card.id)
        XCTAssertEqual(
            command.contentVersion,
            card.card.contentVersion
        )
        XCTAssertEqual(command.cardDigest, card.card.cardDigest)
        XCTAssertNil(command.expectedLocalRevision)
        XCTAssertNil(command.expectedDigestHex)
        XCTAssertTrue(command.desiredFavorite)
    }

    func testCancelUsesStoredVersionDigestEvenWhenCardChangedOrMissing()
        throws {
        let card = try XCTUnwrap(
            contentSnapshot()
                .cards(for: .pocketAppendix).first
        )
        let stored = favorite(
            id: UUID(),
            contentID: card.id,
            isFavorite: true
        )
        let committedAt = Date(
            timeIntervalSince1970: 1_800_800_100
        )

        for suppliedCard in [
            changedCard(card),
            nil
        ] {
            let command = try
                PocketAppendixFavoriteCommandBuilder.make(
                    card: suppliedCard,
                    fact: stored,
                    desiredFavorite: false,
                    operationID: UUID(),
                    newRecordID: UUID(),
                    committedAt: committedAt
                )
            XCTAssertEqual(command.recordID, stored.id)
            XCTAssertEqual(
                command.contentVersion,
                stored.contentVersion
            )
            XCTAssertEqual(
                command.cardDigest,
                stored.cardDigest
            )
            XCTAssertEqual(
                command.expectedLocalRevision,
                stored.localRevision
            )
            XCTAssertEqual(
                command.expectedDigestHex,
                stored.digestHex
            )
        }
    }

    func testRefavoriteKeepsRecordIDButUsesCurrentCardVersionDigest()
        throws {
        let card = try XCTUnwrap(
            contentSnapshot()
                .cards(for: .pocketAppendix).first
        )
        let removed = favorite(
            id: UUID(),
            contentID: card.id,
            isFavorite: false
        )
        let changed = changedCard(card)

        let command = try PocketAppendixFavoriteCommandBuilder
            .make(
                card: changed,
                fact: removed,
                desiredFavorite: true,
                operationID: UUID(),
                newRecordID: UUID(),
                committedAt: Date(
                    timeIntervalSince1970: 1_800_800_200
                )
            )

        XCTAssertEqual(command.recordID, removed.id)
        XCTAssertEqual(
            command.contentVersion,
            changed.card.contentVersion
        )
        XCTAssertEqual(
            command.cardDigest,
            changed.card.cardDigest
        )
        XCTAssertEqual(
            command.expectedLocalRevision,
            removed.localRevision
        )
        XCTAssertEqual(
            command.expectedDigestHex,
            removed.digestHex
        )
    }

    func testMissingCardCannotBeFavorited() {
        XCTAssertThrowsError(
            try PocketAppendixFavoriteCommandBuilder.make(
                card: nil,
                fact: nil,
                desiredFavorite: true,
                operationID: UUID(),
                newRecordID: UUID(),
                committedAt: Date(
                    timeIntervalSince1970: 1_800_800_300
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? PocketAppendixFavoriteCommandError,
                .contentUnavailable
            )
        }
    }

    private func contentSnapshot(
        statusDate: Date =
            UTCDateParser.date("2026-07-31")!
    ) -> OfflineContextualContentSnapshot {
        let repository = OfflineContextualContentRepository(
            data: try! Data(
                contentsOf:
                    URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "Unmanual/Resources/PublicContent/"
                            + "offline-contextual-content-candidate-v1.json"
                    )
            ),
            exposure: .candidate,
            statusDate: statusDate
        )
        return try! XCTUnwrap(repository.state.snapshot)
    }

    private func favorite(
        id: UUID,
        contentID: String,
        isFavorite: Bool
    ) -> ContentFavoriteSnapshot {
        ContentFavoriteSnapshot(
            id: id,
            contentID: contentID,
            contentVersion: "stored-content.1",
            cardDigest: activeDigest,
            createdAt: Date(
                timeIntervalSince1970: 1_800_700_000
            ),
            updatedAt: Date(
                timeIntervalSince1970: 1_800_700_100
            ),
            removedAt:
                isFavorite
                ? nil
                : Date(
                    timeIntervalSince1970:
                        1_800_700_100
                ),
            lastOperationID: UUID(),
            localRevision: 42,
            digestHex:
                "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        )
    }

    private func changedCard(
        _ snapshot: OfflineContextualContentCardSnapshot
    ) -> OfflineContextualContentCardSnapshot {
        let card = snapshot.card
        return OfflineContextualContentCardSnapshot(
            card: OfflineContextualContentCard(
                id: card.id,
                title: card.title,
                summary: card.summary,
                applicabilityBoundary:
                    card.applicabilityBoundary,
                contentType: card.contentType,
                category: card.category,
                aliases: card.aliases,
                sourceIDs: card.sourceIDs,
                displayOrder: card.displayOrder,
                contentVersion: "updated-content.2",
                cardDigest: currentDigest,
                retrievedAt: card.retrievedAt,
                expiresAt: card.expiresAt,
                originalURL: card.originalURL,
                provenance: card.provenance
            ),
            sources: snapshot.sources,
            status: snapshot.status
        )
    }

    private func sourceWithStatus(
        _ source: OfflineContextualContentSource,
        status: OfflineContextualContentSourceStatus
    ) -> OfflineContextualContentSource {
        OfflineContextualContentSource(
            id: source.id,
            rightsHolder: source.rightsHolder,
            title: source.title,
            versionOrPublishedAt:
                source.versionOrPublishedAt,
            retrievedAt: source.retrievedAt,
            expiresAt: source.expiresAt,
            sourceStatus: status,
            url: source.url,
            licenseIdentifier:
                source.licenseIdentifier,
            licenseURL: source.licenseURL,
            distributionMode:
                source.distributionMode,
            applicableRegions:
                source.applicableRegions,
            applicablePopulations:
                source.applicablePopulations,
            boundary: source.boundary
        )
    }
}
