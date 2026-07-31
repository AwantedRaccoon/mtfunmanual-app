import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class PocketAppendixRenderTests: XCTestCase {
    func testDirectoryRendersAtRepresentativeSizes() throws {
        let snapshot = try contentSnapshot()
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 844, height: 390)
        ]

        for size in sizes {
            let image = render(
                PocketAppendixView(
                    previewContentState:
                        .available(snapshot),
                    previewFavoriteState:
                        .available([])
                )
                .environment(AppTheme())
                .environment(
                    \.dynamicTypeSize,
                    .large
                )
                .frame(
                    width: size.width,
                    height: size.height
                ),
                size: size
            )
            assertContainsForeground(
                image,
                context:
                    "\(Int(size.width))x\(Int(size.height))"
            )
            attach(
                image,
                name:
                    "PocketAppendix-Directory-"
                    + "\(Int(size.width))x\(Int(size.height))"
            )
        }
    }

    func testReaderRendersAtNarrowAccessibilityFive()
        throws {
        let snapshot = try contentSnapshot()
        let card = try XCTUnwrap(
            snapshot.cards(for: .pocketAppendix).first
        )
        let size = CGSize(width: 320, height: 568)
        let image = render(
            NavigationStack {
                PocketAppendixReaderView(
                    snapshot: snapshot,
                    card: card,
                    favorite: nil,
                    isWriting: false,
                    favoriteIsAvailable: true,
                    favoriteFeedback: nil,
                    openAttribution: {},
                    openExternal: { _ in },
                    toggleFavorite: {}
                )
            }
            .environment(AppTheme())
            .environment(
                \.dynamicTypeSize,
                .accessibility5
            )
            .frame(
                width: size.width,
                height: size.height
            ),
            size: size
        )
        assertContainsForeground(
            image,
            context: "reader-AX5"
        )
        attach(
            image,
            name:
                "PocketAppendix-Reader-320x568-AX5"
        )
    }

    func testAttributionAndUnavailableStateRender()
        throws {
        let snapshot = try contentSnapshot()
        let size = CGSize(width: 768, height: 1_024)
        let views: [(String, AnyView)] = [
            (
                "attribution",
                AnyView(
                    NavigationStack {
                        PocketAppendixAttributionView(
                            snapshot: snapshot,
                            card:
                                snapshot.cards(
                                    for: .pocketAppendix
                                ).first,
                            openExternal: { _ in }
                        )
                    }
                )
            ),
            (
                "unavailable",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .unavailable(
                                .pendingHumanReviewAndClassification
                            ),
                        previewFavoriteState: .unavailable
                    )
                )
            )
        ]

        for (name, view) in views {
            let image = render(
                view
                    .environment(AppTheme())
                    .environment(
                        \.dynamicTypeSize,
                        .large
                    )
                    .frame(
                        width: size.width,
                        height: size.height
                    ),
                size: size
            )
            assertContainsForeground(
                image,
                context: name
            )
            attach(
                image,
                name:
                    "PocketAppendix-\(name)-768x1024"
            )
        }
    }

    func testDirectoryStateMatrixRenders() throws {
        let snapshot = try contentSnapshot()
        let missingFavorite = ContentFavoriteSnapshot(
            id: UUID(),
            contentID: "card.removed-from-pack",
            contentVersion: "historical-content.1",
            cardDigest:
                String(repeating: "a", count: 64),
            createdAt: Date(
                timeIntervalSince1970: 1_800_800_000
            ),
            updatedAt: Date(
                timeIntervalSince1970: 1_800_800_100
            ),
            removedAt: nil,
            lastOperationID: UUID(),
            localRevision: 3,
            digestHex:
                String(repeating: "b", count: 64)
        )
        let size = CGSize(width: 390, height: 844)
        let fixtures: [(String, AnyView)] = [
            (
                "loading",
                AnyView(
                    PocketAppendixView(
                        previewContentPhase: .loading,
                        previewFavoriteState: .loading
                    )
                )
            ),
            (
                "favorite-loading",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .available(snapshot),
                        previewFavoriteState: .loading
                    )
                )
            ),
            (
                "favorite-unavailable",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .available(snapshot),
                        previewFavoriteState: .unavailable
                    )
                )
            ),
            (
                "invalid-query",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .available(snapshot),
                        previewFavoriteState:
                            .available([]),
                        previewQuery:
                            String(
                                repeating: "字",
                                count: 81
                            )
                    )
                )
            ),
            (
                "no-results",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .available(snapshot),
                        previewFavoriteState:
                            .available([]),
                        previewQuery:
                            "definitely-no-result"
                    )
                )
            ),
            (
                "no-favorites",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .available(snapshot),
                        previewFavoriteState:
                            .available([]),
                        previewFavoritesOnly: true
                    )
                )
            ),
            (
                "missing-favorite",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .available(snapshot),
                        previewFavoriteState:
                            .available([missingFavorite]),
                        previewFavoritesOnly: true
                    )
                )
            ),
            (
                "conflict-reload-failed",
                AnyView(
                    PocketAppendixView(
                        previewContentState:
                            .available(snapshot),
                        previewFavoriteState: .unavailable,
                        previewFeedback:
                            .conflict(
                                contentID:
                                    snapshot.cards[0].id,
                                reloadSucceeded: false
                            )
                    )
                )
            )
        ]

        for (name, view) in fixtures {
            let image = render(
                view
                    .environment(AppTheme())
                    .environment(
                        \.dynamicTypeSize,
                        .large
                    )
                    .frame(
                        width: size.width,
                        height: size.height
                    ),
                size: size
            )
            assertContainsForeground(
                image,
                context: name
            )
            attach(
                image,
                name:
                    "PocketAppendix-State-\(name)"
            )
        }
    }

    func testReaderFailureSourceUnavailableAndBoundaryRender()
        throws {
        let snapshot = try contentSnapshot()
        let sourceUnavailableCard =
            try sourceUnavailableCard(in: snapshot)
        let size = CGSize(width: 390, height: 844)
        let expiredSource = try XCTUnwrap(
            snapshot.sources.first
        )
        let expiry = try XCTUnwrap(
            UTCDateParser.date(expiredSource.expiresAt)
        )
        let nextDay = try XCTUnwrap(
            UTCDateParser.calendar.date(
                byAdding: .day,
                value: 1,
                to: expiry
            )
        )
        let staleTarget = try XCTUnwrap(
            PocketAppendixExternalTargetFactory.source(
                expiredSource,
                statusDate: nextDay
            )
        )
        let views: [(String, AnyView)] = [
            (
                "reader-source-unavailable",
                AnyView(
                    NavigationStack {
                        PocketAppendixReaderView(
                            snapshot: snapshot,
                            card:
                                sourceUnavailableCard,
                            favorite: nil,
                            isWriting: false,
                            favoriteIsAvailable: true,
                            favoriteFeedback:
                                .writeFailure(
                                    contentID:
                                        sourceUnavailableCard.id
                                ),
                            openAttribution: {},
                            openExternal: { _ in },
                            toggleFavorite: {}
                        )
                    }
                )
            ),
            (
                "reader-favorite-unavailable",
                AnyView(
                    NavigationStack {
                        PocketAppendixReaderView(
                            snapshot: snapshot,
                            card:
                                sourceUnavailableCard,
                            favorite: nil,
                            isWriting: false,
                            favoriteIsAvailable: false,
                            favoriteFeedback: nil,
                            openAttribution: {},
                            openExternal: { _ in },
                            toggleFavorite: {}
                        )
                    }
                )
            ),
            (
                "external-needs-reverification",
                AnyView(
                    FixedExternalLinkBoundaryView(
                        target: staleTarget
                    )
                )
            )
        ]

        for (name, view) in views {
            let image = render(
                view
                    .environment(AppTheme())
                    .environment(
                        \.dynamicTypeSize,
                        .large
                    )
                    .frame(
                        width: size.width,
                        height: size.height
                    ),
                size: size
            )
            assertContainsForeground(
                image,
                context: name
            )
            attach(
                image,
                name: "PocketAppendix-\(name)"
            )
        }
    }

    private func contentSnapshot() throws
        -> OfflineContextualContentSnapshot {
        let data = try Data(
            contentsOf:
                URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Unmanual/Resources/PublicContent/"
                        + "offline-contextual-content-candidate-v1.json"
                )
        )
        let repository =
            OfflineContextualContentRepository(
                data: data,
                exposure: .candidate,
                statusDate:
                    try XCTUnwrap(
                        UTCDateParser.date("2026-07-31")
                    )
            )
        return try XCTUnwrap(repository.state.snapshot)
    }

    private func sourceUnavailableCard(
        in snapshot: OfflineContextualContentSnapshot
    ) throws -> OfflineContextualContentCardSnapshot {
        let card = try XCTUnwrap(
            snapshot.cards(for: .pocketAppendix).first
        )
        let source = try XCTUnwrap(card.sources.first)
        let unavailableSource =
            OfflineContextualContentSource(
                id: source.id,
                rightsHolder: source.rightsHolder,
                title: source.title,
                versionOrPublishedAt:
                    source.versionOrPublishedAt,
                retrievedAt: source.retrievedAt,
                expiresAt: source.expiresAt,
                sourceStatus: .knownUnavailable,
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
        return OfflineContextualContentCardSnapshot(
            card: card.card,
            sources:
                [unavailableSource]
                + Array(card.sources.dropFirst()),
            status: .sourceUnavailable
        )
    }

    private func render<Content: View>(
        _ content: Content,
        size: CGSize
    ) -> UIImage {
        let host = UIHostingController(rootView: content)
        let window = UIWindow(
            frame: CGRect(origin: .zero, size: size)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(
            until: Date().addingTimeInterval(0.05)
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: size,
            format: format
        )
        var didDraw = false
        let image = renderer.image { _ in
            didDraw = host.view.drawHierarchy(
                in: host.view.bounds,
                afterScreenUpdates: true
            )
        }
        XCTAssertTrue(didDraw)
        return image
    }

    private func assertContainsForeground(
        _ image: UIImage,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              cgImage.bitsPerPixel >= 24 else {
            return XCTFail(
                "Expected RGB output for \(context)",
                file: file,
                line: line
            )
        }
        let bytes = CFDataGetBytePtr(data)!
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        var minimum = Int.max
        var maximum = Int.min
        for y in stride(
            from: 0,
            to: cgImage.height,
            by: 12
        ) {
            for x in stride(
                from: 0,
                to: cgImage.width,
                by: 12
            ) {
                let offset =
                    y * cgImage.bytesPerRow
                    + x * bytesPerPixel
                let brightness =
                    Int(bytes[offset])
                    + Int(bytes[offset + 1])
                    + Int(bytes[offset + 2])
                minimum = min(minimum, brightness)
                maximum = max(maximum, brightness)
            }
        }
        XCTAssertGreaterThan(
            maximum - minimum,
            80,
            context,
            file: file,
            line: line
        )
    }

    private func attach(
        _ image: UIImage,
        name: String
    ) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
