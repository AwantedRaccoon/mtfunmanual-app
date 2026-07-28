import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class ParentRecordMutationRenderTests: XCTestCase {
    func testMutationSheetsRenderAcrossRequiredSizes() {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 844, height: 390)
        ]

        for size in sizes {
            for fixture in fixtures(dynamicTypeSize: .large, size: size) {
                let image = render(fixture.view, size: size)
                assertContainsForeground(
                    image,
                    context:
                        "\(fixture.name) "
                        + "\(Int(size.width))x\(Int(size.height))"
                )
                attach(
                    image,
                    named:
                        "ParentMutation-\(fixture.name)-"
                        + "\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testMutationSheetsRenderAtAccessibilityFive() {
        let size = CGSize(width: 320, height: 568)
        for fixture in fixtures(
            dynamicTypeSize: .accessibility5,
            size: size
        ) {
            let image = render(fixture.view, size: size)
            assertContainsForeground(
                image,
                context: "\(fixture.name) Accessibility5"
            )
            attach(
                image,
                named:
                    "ParentMutation-\(fixture.name)-"
                    + "320x568-Accessibility5"
            )
        }
    }

    private struct Fixture {
        let name: String
        let view: AnyView
    }

    private func fixtures(
        dynamicTypeSize: DynamicTypeSize,
        size: CGSize
    ) -> [Fixture] {
        [
            Fixture(
                name: "lab-correction",
                view: wrapped(
                    LabSampleCorrectionEditor(
                        snapshot: labSnapshot,
                        head: head,
                        attachmentCount: 1,
                        onSaved: {}
                    ),
                    dynamicTypeSize: dynamicTypeSize,
                    size: size
                )
            ),
            Fixture(
                name: "status-correction",
                view: wrapped(
                    StatusObservationCorrectionEditor(
                        snapshot: statusSnapshot,
                        head: head,
                        onSaved: {}
                    ),
                    dynamicTypeSize: dynamicTypeSize,
                    size: size
                )
            ),
            Fixture(
                name: "delete-impact",
                view: wrapped(
                    ParentRecordDeletionSheet(
                        impact: deletionImpact,
                        onDeleted: {}
                    ),
                    dynamicTypeSize: dynamicTypeSize,
                    size: size
                )
            )
        ]
    }

    private func wrapped<Content: View>(
        _ content: Content,
        dynamicTypeSize: DynamicTypeSize,
        size: CGSize
    ) -> AnyView {
        AnyView(
            content
                .environment(AppTheme())
                .environment(
                    \.dynamicTypeSize,
                    dynamicTypeSize
                )
                .frame(width: size.width, height: size.height)
        )
    }

    private var timestamp: HistoricalTimestamp {
        try! HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_741_046_400),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
    }

    private var head: ParentRecordHeadToken {
        ParentRecordHeadToken(
            latestEventID: UUID(
                uuidString:
                    "92000000-0000-0000-0000-000000000001"
            )!,
            eventCount: 2,
            localRevision: 12,
            factsDigest: String(repeating: "a", count: 64)
        )
    }

    private var labSnapshot: LabSampleSnapshot {
        LabSampleSnapshot(
            id: UUID(
                uuidString:
                    "92000000-0000-0000-0000-000000000101"
            )!,
            timestamp: timestamp,
            regimenVersionID: nil,
            associationState: .missing,
            specimenOriginal: "血清",
            contextNote: "上午采样，保留原始备注。",
            results: [
                LabResultSnapshot(
                    id: UUID(
                        uuidString:
                            "92000000-0000-0000-0000-000000000102"
                    )!,
                    itemDefinitionID: UUID(
                        uuidString:
                            "92000000-0000-0000-0000-000000000103"
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
            ]
        )
    }

    private var statusSnapshot: StatusObservationSnapshot {
        StatusObservationSnapshot(
            id: UUID(
                uuidString:
                    "92000000-0000-0000-0000-000000000201"
            )!,
            metricDefinitionID: UUID(
                uuidString:
                    "92000000-0000-0000-0000-000000000202"
            )!,
            metricNameSnapshot: "精力",
            ordinalLevel: 3,
            note: "比前一天稳定。",
            timestamp: timestamp,
            regimenVersionID: nil,
            associationState: .missing
        )
    }

    private var deletionImpact: ParentRecordDeletionImpact {
        ParentRecordDeletionImpact(
            parentType: .labSample,
            parentID: labSnapshot.id,
            expectedHead: head,
            effectiveResultCount: 1,
            correctionCount: 2,
            attachments: [
                AttachmentSnapshot(
                    id: UUID(
                        uuidString:
                            "92000000-0000-0000-0000-000000000301"
                    )!,
                    ownerType: .labSample,
                    ownerID: labSnapshot.id,
                    relativePath: "Attachments/sample.pdf",
                    originalFilename: "化验单.pdf",
                    typeIdentifier: "com.adobe.pdf",
                    byteCount: 2_048,
                    sha256Hex: String(repeating: "b", count: 64),
                    createdAt: timestamp.instant
                ),
                AttachmentSnapshot(
                    id: UUID(
                        uuidString:
                            "92000000-0000-0000-0000-000000000302"
                    )!,
                    ownerType: .labSample,
                    ownerID: labSnapshot.id,
                    relativePath: "Attachments/sample-image.png",
                    originalFilename:
                        "第二份很长的原始检查附件名称.png",
                    typeIdentifier: "public.png",
                    byteCount: 4_096,
                    sha256Hex: String(repeating: "d", count: 64),
                    createdAt: timestamp.instant
                )
            ],
            attachmentByteCount: 6_144,
            impactDigest: String(repeating: "c", count: 64)
        )
    }

    private func render(
        _ content: AnyView,
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
