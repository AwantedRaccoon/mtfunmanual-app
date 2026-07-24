import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class PersonalTimelineRenderTests: XCTestCase {
    func testTimelineAndEditorsRenderAtRepresentativeSizes() {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 844, height: 390)
        ]
        for size in sizes {
            let views: [(String, AnyView)] = [
                (
                    "timeline",
                    AnyView(
                        NavigationStack {
                            PersonalTimelineView(refreshToken: 0, recordAction: {})
                        }
                    )
                ),
                ("lab-editor", AnyView(LabSampleEditor())),
                ("status-editor", AnyView(StatusObservationEditor()))
            ]
            for (name, view) in views {
                let image = render(
                    view
                        .environment(AppTheme())
                        .environment(\.dynamicTypeSize, .large)
                        .frame(width: size.width, height: size.height),
                    size: size
                )
                assertContainsForeground(image)
                let attachment = XCTAttachment(image: image)
                attachment.name = "PersonalTimeline-\(name)-\(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testEditorsRemainRenderableAt320AccessibilityFive() {
        let size = CGSize(width: 320, height: 568)
        for (name, view) in [
            ("lab", AnyView(LabSampleEditor())),
            ("status", AnyView(StatusObservationEditor()))
        ] {
            let image = render(
                view
                    .environment(AppTheme())
                    .environment(\.dynamicTypeSize, .accessibility5)
                    .frame(width: size.width, height: size.height),
                size: size
            )
            assertContainsForeground(image)
            let attachment = XCTAttachment(image: image)
            attachment.name = "PersonalTimeline-\(name)-320x568-Accessibility5"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func render<Content: View>(_ content: Content, size: CGSize) -> UIImage {
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        window.isHidden = true
        return image
    }

    private func assertContainsForeground(_ image: UIImage) {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              cgImage.bitsPerPixel >= 24 else {
            return XCTFail("Expected readable RGB output")
        }
        let bytes = CFDataGetBytePtr(data)!
        let strideSize = cgImage.bitsPerPixel / 8
        var minimum = Int.max
        var maximum = Int.min
        for y in stride(from: 0, to: cgImage.height, by: 12) {
            for x in stride(from: 0, to: cgImage.width, by: 12) {
                let offset = y * cgImage.bytesPerRow + x * strideSize
                let brightness = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                minimum = min(minimum, brightness)
                maximum = max(maximum, brightness)
            }
        }
        XCTAssertGreaterThan(maximum - minimum, 80)
    }
}
