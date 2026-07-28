import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class AppPrivacyRenderTests: XCTestCase {
    private let requiredSizes = [
        CGSize(width: 320, height: 568),
        CGSize(width: 390, height: 844),
        CGSize(width: 430, height: 932),
        CGSize(width: 768, height: 1_024),
        CGSize(width: 844, height: 390)
    ]

    func testLockedGateRendersAcrossRequiredSizes() async throws {
        let coordinator = try await enabledCoordinator()
        for size in requiredSizes {
            let image = render(
                AppLockGateView(coordinator: coordinator)
                    .environment(AppTheme())
                    .frame(width: size.width, height: size.height),
                size: size
            )
            assertContainsForeground(
                image,
                context: "AppLock \(Int(size.width))x\(Int(size.height))"
            )
            attach(
                image,
                named:
                    "AppLock-\(Int(size.width))x\(Int(size.height))"
            )
        }
    }

    func testLockedGateRendersAtAccessibilityFive() async throws {
        let coordinator = try await enabledCoordinator()
        let size = CGSize(width: 320, height: 568)
        let image = render(
            AppLockGateView(coordinator: coordinator)
                .environment(AppTheme())
                .environment(
                    \.dynamicTypeSize,
                    DynamicTypeSize.accessibility5
                )
                .frame(width: size.width, height: size.height),
            size: size
        )
        assertContainsForeground(
            image,
            context: "AppLock Accessibility5"
        )
        attach(image, named: "AppLock-320x568-Accessibility5")
    }

    func testRecentTasksShieldRendersAcrossRequiredSizes() {
        for size in requiredSizes {
            let image = render(
                RecentTasksPrivacyShield()
                    .environment(AppTheme())
                    .frame(width: size.width, height: size.height),
                size: size
            )
            assertContainsForeground(
                image,
                context:
                    "PrivacyShield "
                        + "\(Int(size.width))x\(Int(size.height))"
            )
        }
    }

    private func enabledCoordinator()
        async throws -> AppPrivacyCoordinator {
        let container = try AppModelContainerFactory
            .makeInMemoryPrivacyControlContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        _ = try CountdownLifecycleBackfill.run(in: container)
        _ = try OnboardingBackfill.run(
            in: container,
            source: .newInstallV8
        )
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0"
        )
        _ = try ParentRecordLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0"
        )
        _ = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11
        )
        let reader = AppReadActor(modelContainer: container)
        let initial = try await reader.privacyControlSnapshot()
        _ = try await AppWriteActor(
            modelContainer: container
        ).setAppLock(
            SetAppLockCommand(
                operationID: UUID(),
                expectedLocalRevision: initial.localRevision,
                expectedDigestHex: initial.digestHex,
                isEnabled: true
            )
        )
        let coordinator = AppPrivacyCoordinator(
            client: RenderAuthenticationClient()
        )
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: reader,
            generationID: UUID()
        )
        return coordinator
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

@MainActor
private final class RenderAuthenticationClient:
    DeviceOwnerAuthenticationClient {
    func availability() -> DeviceOwnerAuthenticationAvailability {
        .available
    }

    func authenticate(
        requestID _: UUID,
        reason _: String
    ) async -> DeviceOwnerAuthenticationOutcome {
        .success
    }

    func cancel() {}
}
