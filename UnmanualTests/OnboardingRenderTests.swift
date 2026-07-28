import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class OnboardingRenderTests: XCTestCase {
    func testEveryStageRendersAcrossRequiredPhoneLandscapeAndPadSizes() {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 844, height: 390)
        ]
        let steps: [OnboardingStep] = [
            .privacy,
            .startDate,
            .regimen,
            .reminder,
            .countdown,
            .ready
        ]

        for size in sizes {
            for step in steps {
                let image = render(
                    onboardingView(
                        step: step,
                        size: size,
                        dynamicTypeSize: .large
                    ),
                    size: size
                )
                assertContainsForeground(
                    image,
                    context:
                        "\(step.rawValue) \(Int(size.width))x\(Int(size.height))"
                )
                attach(
                    image,
                    named:
                        "Onboarding-\(step.rawValue)-"
                        + "\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testEveryStageRendersAt320AccessibilityFive() {
        let size = CGSize(width: 320, height: 568)
        for step in [
            OnboardingStep.privacy,
            .startDate,
            .regimen,
            .reminder,
            .countdown,
            .ready
        ] {
            let image = render(
                onboardingView(
                    step: step,
                    size: size,
                    dynamicTypeSize: .accessibility5
                ),
                size: size
            )
            assertContainsForeground(
                image,
                context: "\(step.rawValue) Accessibility5"
            )
            attach(
                image,
                named: "Onboarding-\(step.rawValue)-320x568-Accessibility5"
            )
        }
    }

    private func onboardingView(
        step: OnboardingStep,
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize
    ) -> some View {
        OnboardingFlowView(
            mode: .firstRun,
            initialSnapshot: snapshot(step: step),
            close: {}
        )
        .environment(AppTheme())
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .frame(width: size.width, height: size.height)
    }

    private func snapshot(step: OnboardingStep) -> OnboardingSnapshot {
        OnboardingSnapshot(
            isCompleted: false,
            progress: OnboardingProgressSnapshot(
                step: step,
                skippedStartDate: true,
                skippedReminder: true,
                skippedCountdown: true,
                completedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 1_753_180_000)
            ),
            profile: nil,
            hasEligibleRegimen: true,
            regimenNeedsReview: false,
            drafts: [],
            reminderOptions: [],
            reminderCoverage: NotificationCoverageSnapshot(
                status: .disabledByUser,
                scheduledThrough: nil,
                desiredCount: 0,
                confirmedPendingCount: 0,
                lastErrorCode: nil,
                observedAt: .distantPast
            ),
            countdown: nil
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
              let providerData = cgImage.dataProvider?.data,
              cgImage.bitsPerPixel >= 24 else {
            return XCTFail(
                "Expected readable RGB output for \(context)",
                file: file,
                line: line
            )
        }
        let bytes = CFDataGetBytePtr(providerData)!
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
