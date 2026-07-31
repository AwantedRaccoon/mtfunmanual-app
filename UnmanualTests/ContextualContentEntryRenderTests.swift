import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class ContextualContentEntryRenderTests:
    XCTestCase {
    func testEveryScenarioEntryRendersAcrossRequiredSizeMatrix()
        throws {
        let snapshot = try contentSnapshot()
        let scenarios: [
            OfflineContextualContentScenario
        ] = [
            .regimenField,
            .labRecording,
            .regimenAnalysisSource,
            .visitPreparation,
            .timelineRecord
        ]
        let displays: [(CGSize, DynamicTypeSize)] = [
            (
                CGSize(width: 320, height: 568),
                .large
            ),
            (
                CGSize(width: 390, height: 844),
                .large
            ),
            (
                CGSize(width: 430, height: 932),
                .large
            ),
            (
                CGSize(width: 768, height: 1_024),
                .large
            ),
            (
                CGSize(width: 844, height: 390),
                .large
            ),
            (
                CGSize(width: 320, height: 568),
                .accessibility5
            )
        ]

        for scenario in scenarios {
            for (size, dynamicType) in displays {
                assertEntryHasBoundedNaturalLayout(
                    scenario: scenario,
                    snapshot: snapshot,
                    width: size.width,
                    dynamicType: dynamicType
                )
                let image = render(
                    ScrollView {
                        ContextualContentScenarioEntry(
                            previewScenario: scenario,
                            phase: .available(snapshot)
                        )
                        .padding(16)
                    }
                    .environment(AppTheme())
                    .environment(
                        \.dynamicTypeSize,
                        dynamicType
                    )
                    .frame(
                        width: size.width,
                        height: size.height
                    ),
                    size: size
                )
                let context =
                    "\(scenario.rawValue)-"
                    + "\(Int(size.width))x"
                    + "\(Int(size.height))-"
                    + "\(dynamicType)"
                assertContainsForeground(
                    image,
                    context: context
                )
                attach(
                    image,
                    name: "Contextual-\(context)"
                )
            }
        }
    }

    private func assertEntryHasBoundedNaturalLayout(
        scenario: OfflineContextualContentScenario,
        snapshot: OfflineContextualContentSnapshot,
        width: CGFloat,
        dynamicType: DynamicTypeSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let content =
            ContextualContentScenarioEntry(
                previewScenario: scenario,
                phase: .available(snapshot)
            )
            .padding(16)
            .environment(AppTheme())
            .environment(
                \.dynamicTypeSize,
                dynamicType
            )
        let host = UIHostingController(rootView: content)
        let fitting = host.sizeThatFits(
            in: CGSize(
                width: width,
                height: 10_000
            )
        )
        XCTAssertGreaterThanOrEqual(
            fitting.height,
            44,
            file: file,
            line: line
        )
        XCTAssertLessThan(
            fitting.height,
            10_000,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            fitting.width,
            width + 1,
            "Entry must respect the proposed screen width.",
            file: file,
            line: line
        )
    }

    func testLoadingUnavailableAndSourceUnavailableRender()
        throws {
        let snapshot = try contentSnapshot()
        let sourceUnavailable =
            try sourceUnavailableSnapshot(snapshot)
        let size = CGSize(width: 390, height: 844)
        let views: [(String, AnyView)] = [
            (
                "loading",
                AnyView(
                    ContextualContentScenarioEntry(
                        previewScenario: .labRecording,
                        phase: .loading
                    )
                )
            ),
            (
                "release-pending",
                AnyView(
                    ContextualContentScenarioEntry(
                        previewScenario:
                            .visitPreparation,
                        phase:
                            .unavailable(
                                .pendingHumanReviewAndClassification
                            )
                    )
                )
            ),
            (
                "source-unavailable",
                AnyView(
                    ContextualContentScenarioEntry(
                        previewScenario: .regimenField,
                        phase:
                            .available(
                                sourceUnavailable
                            )
                    )
                )
            )
        ]

        for (name, view) in views {
            let image = render(
                ScrollView {
                    view.padding(16)
                }
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
                name: "Contextual-State-\(name)"
            )
        }
    }

    func testContextualReaderRendersWithoutFavoriteStateAtAX5()
        throws {
        let snapshot = try contentSnapshot()
        let resolution = try XCTUnwrap(
            OfflineContextualContentScenarioResolver
                .resolve(
                    scenario: .visitPreparation,
                    snapshot: snapshot
                )
        )
        let size = CGSize(width: 320, height: 568)
        let image = render(
            ContextualContentReaderSheet(
                snapshot: snapshot,
                card: resolution.card
            )
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
            name: "Contextual-Reader-320x568-AX5"
        )
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
        return try XCTUnwrap(
            OfflineContextualContentRepository(
                data: data,
                exposure: .candidate,
                statusDate:
                    try XCTUnwrap(
                        UTCDateParser.date("2026-07-31")
                    )
            ).state.snapshot
        )
    }

    private func sourceUnavailableSnapshot(
        _ snapshot: OfflineContextualContentSnapshot
    ) throws -> OfflineContextualContentSnapshot {
        let resolution = try XCTUnwrap(
            OfflineContextualContentScenarioResolver
                .resolve(
                    scenario: .regimenField,
                    snapshot: snapshot
                )
        )
        let updatedCards = snapshot.cards.map {
            guard $0.id == resolution.card.id else {
                return $0
            }
            return OfflineContextualContentCardSnapshot(
                card: $0.card,
                sources: $0.sources,
                status: .sourceUnavailable
            )
        }
        return OfflineContextualContentSnapshot(
            manifest: snapshot.manifest,
            sources: snapshot.sources,
            cards: updatedCards,
            scenarioAnchors: snapshot.scenarioAnchors,
            attribution: snapshot.attribution,
            statusDate: snapshot.statusDate
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
