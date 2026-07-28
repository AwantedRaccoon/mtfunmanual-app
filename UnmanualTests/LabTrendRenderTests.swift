import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class LabTrendRenderTests: XCTestCase {
    func testTrendStatesRenderAcrossRequiredSizes() {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 844, height: 390)
        ]
        for size in sizes {
            for fixture in fixtures {
                let image = render(
                    trend(
                        fixture: fixture,
                        size: size,
                        dynamicTypeSize: .large
                    ),
                    size: size
                )
                assertContainsForeground(
                    image,
                    context:
                        "\(fixture.name) "
                        + "\(Int(size.width))x\(Int(size.height))"
                )
                attach(
                    image,
                    named:
                        "LabTrend-\(fixture.name)-"
                        + "\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testTrendStatesRenderAtAccessibilityFive() {
        let size = CGSize(width: 320, height: 568)
        for fixture in fixtures {
            let image = render(
                trend(
                    fixture: fixture,
                    size: size,
                    dynamicTypeSize: .accessibility5
                ),
                size: size
            )
            assertContainsForeground(
                image,
                context: "\(fixture.name) Accessibility5"
            )
            attach(
                image,
                named:
                    "LabTrend-\(fixture.name)-"
                    + "320x568-Accessibility5"
            )
        }
    }

    private struct Fixture {
        let name: String
        let page: LabTrendPage?
        let startsLoading: Bool
        let error: String?
        let paginationError: String?
    }

    private var fixtures: [Fixture] {
        [
            Fixture(
                name: "loading",
                page: nil,
                startsLoading: true,
                error: nil,
                paginationError: nil
            ),
            Fixture(
                name: "error",
                page: nil,
                startsLoading: false,
                error: "本地资料没有通过完整性检查。",
                paginationError: nil
            ),
            Fixture(
                name: "empty",
                page: page(points: []),
                startsLoading: false,
                error: nil,
                paginationError: nil
            ),
            Fixture(
                name: "single",
                page: page(points: [point(index: 0)]),
                startsLoading: false,
                error: nil,
                paginationError: nil
            ),
            Fixture(
                name: "multiple",
                page: page(
                    points: [
                        point(index: 2),
                        point(index: 1),
                        point(index: 0)
                    ]
                ),
                startsLoading: false,
                error: nil,
                paginationError: nil
            ),
            Fixture(
                name: "mixed",
                page: page(
                    points: [
                        point(index: 1),
                        point(index: 0, comparator: .lessThan)
                    ],
                    excludedCount: 2
                ),
                startsLoading: false,
                error: nil,
                paginationError: nil
            ),
            Fixture(
                name: "pagination-error-keeps-ledger",
                page: page(
                    points: [point(index: 1), point(index: 0)],
                    hasNextPage: true
                ),
                startsLoading: false,
                error: nil,
                paginationError:
                    "更早的记录暂时无法读取；已经显示的内容没有被修改。"
            )
        ]
    }

    private func trend(
        fixture: Fixture,
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize
    ) -> some View {
        NavigationStack {
            LabTrendView(
                seed: seed,
                initialPage: fixture.page,
                startsLoading: fixture.startsLoading,
                initialErrorMessage: fixture.error,
                initialPaginationErrorMessage:
                    fixture.paginationError,
                automaticallyLoads: false
            )
        }
        .environment(AppTheme())
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .frame(width: size.width, height: size.height)
    }

    private var seed: LabResultSnapshot {
        LabResultSnapshot(
            id: UUID(
                uuidString:
                    "88000000-0000-0000-0000-000000000001"
            )!,
            itemDefinitionID: UUID(
                uuidString:
                    "88000000-0000-0000-0000-000000000002"
            )!,
            itemDefinitionKind: .custom,
            bundledStableID: nil,
            itemNameSnapshot: "雌二醇",
            itemCodeSnapshot: "E2",
            rawValueOriginal: "172.5",
            comparator: nil,
            canonicalDecimalString: "172.5",
            unitOriginal: "pmol/L",
            referenceRangeOriginal: "实验室原文",
            assayOrVariantOriginal: "方法 A"
        )
    }

    private func page(
        points: [LabTrendPoint],
        excludedCount: Int = 0,
        hasNextPage: Bool = false
    ) -> LabTrendPage {
        LabTrendPage(
            points: points,
            nextCursor: hasNextPage
                ? LabTrendCursor(
                    instant: Date(timeIntervalSince1970: 1),
                    sampleID: UUID(),
                    sortOrder: 0,
                    resultID: UUID()
                )
                : nil,
            compatibleUnits:
                LabUnitConversionRulesV1.compatibleTargets(
                    for: "pmol/L"
                ),
            excludedIncompatibleUnitCount: excludedCount
        )
    }

    private func point(
        index: Int,
        comparator: LabValueComparator? = nil
    ) -> LabTrendPoint {
        let instant = Date(
            timeIntervalSince1970:
                1_735_689_600 + Double(index * 86_400)
        )
        return LabTrendPoint(
            id: UUID(
                uuidString:
                    String(
                        format:
                            "88000000-0000-0000-0000-%012d",
                        100 + index
                    )
            )!,
            sampleID: UUID(
                uuidString:
                    String(
                        format:
                            "88000000-0000-0000-0000-%012d",
                        200 + index
                    )
            )!,
            timestamp: try! HistoricalTimestamp.captured(
                instant: instant,
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .userEntered
            ),
            regimenVersionID: nil,
            associationState: .missing,
            itemNameSnapshot: "雌二醇",
            itemCodeSnapshot: "E2",
            rawValueOriginal:
                comparator == nil
                    ? "\(170 + index).5"
                    : "< \(170 + index).5",
            comparator: comparator,
            canonicalDecimalString: "\(170 + index).5",
            unitOriginal: "pmol/L",
            referenceRangeOriginal: "实验室原文",
            assayOrVariantOriginal: "方法 A",
            displayCanonicalDecimalString: "\(170 + index).5",
            displayUnit: "pmol/L",
            conversionRuleID: nil,
            conversionRuleVersion: nil
        )
    }

    private func render<Content: View>(
        _ content: Content,
        size: CGSize
    ) -> UIImage {
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            XCTAssertTrue(
                host.view.drawHierarchy(
                    in: host.view.bounds,
                    afterScreenUpdates: true
                )
            )
        }
        window.isHidden = true
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
                "Expected readable RGB output for \(context)",
                file: file,
                line: line
            )
        }
        let bytes = CFDataGetBytePtr(data)!
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        var minimum = Int.max
        var maximum = Int.min
        for y in stride(from: 0, to: cgImage.height, by: 12) {
            for x in stride(from: 0, to: cgImage.width, by: 12) {
                let offset =
                    y * cgImage.bytesPerRow + x * bytesPerPixel
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
            "Expected foreground contrast for \(context)",
            file: file,
            line: line
        )
    }

    private func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
