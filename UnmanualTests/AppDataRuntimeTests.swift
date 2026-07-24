import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class AppDataRuntimeTests: XCTestCase {
    func testTabBarSwitchesToTwoColumnGridForAccessibilityText() {
        XCTAssertEqual(AppTabBarLayout.mode(for: .large), .singleRow)
        XCTAssertEqual(AppTabBarLayout.mode(for: .accessibility1), .twoColumnGrid)
        XCTAssertEqual(AppTabBarLayout.mode(for: .accessibility5), .twoColumnGrid)
    }

    func testOpenFailureEntersRecoveryAndRetryCanBecomeReady() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let store = BootstrappedAppDataStore(
            container: container,
            generationID: UUID(),
            storeURL: URL(fileURLWithPath: "/test-only/in-memory.store"),
            origin: .newInstall,
            protectionReport: StoreFileProtectionReport(
                entries: [],
                requiresPhysicalDeviceValidation: true
            )
        )
        var attempts = 0
        let runtime = AppDataRuntime {
            attempts += 1
            if attempts == 1 {
                throw AppDataFailure.migrationFailed
            }
            return store
        }

        runtime.openIfNeeded()
        await waitUntilSettled(runtime)
        guard case let .recovery(recovery) = runtime.state else {
            return XCTFail("Expected recovery after the first failure")
        }
        XCTAssertEqual(recovery.reason, .migrationFailed)
        XCTAssertFalse(recovery.userMessage.contains("/test-only"))

        runtime.retry()
        await waitUntilSettled(runtime)
        guard case let .ready(session) = runtime.state else {
            return XCTFail("Expected ready after retry")
        }
        XCTAssertTrue(session.store.container === container)
        XCTAssertEqual(attempts, 2)
    }

    func testCommittedWriteEntersRecoveryWhenPostCommitProtectionReadbackFails() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let storeURL = URL(fileURLWithPath: "/test-only/in-memory.store")
        let store = BootstrappedAppDataStore(
            container: container,
            generationID: UUID(),
            storeURL: storeURL,
            origin: .newInstall,
            protectionReport: StoreFileProtectionReport(
                entries: [],
                requiresPhysicalDeviceValidation: true
            ),
            protectionPlan: StoreFileProtectionPlan(
                storeURL: storeURL,
                resources: [],
                backupPolicy: .systemManaged
            )
        )
        let runtime = AppDataRuntime(
            openStore: { store },
            verifyStoreProtection: { _ in false }
        )

        runtime.openIfNeeded()
        await waitUntilSettled(runtime)
        guard case let .ready(session) = runtime.state else {
            return XCTFail("Expected ready before writing")
        }

        let recordID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        try await session.writer.setStartDate(
            SetStartDateCommand(
                recordID: recordID,
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                committedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )

        guard case let .recovery(recovery) = runtime.state else {
            return XCTFail("Expected recovery after failed post-commit protection readback")
        }
        XCTAssertEqual(recovery.reason, .fileProtectionUnverified)

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HRTProfile>()).map(\.id), [recordID])
        let revisions = try context.fetch(FetchDescriptor<RecordRevision>())
        XCTAssertEqual(revisions.count, 3)
        XCTAssertEqual(
            Set(revisions.map(\.recordType)),
            ["HRTProfile", "HrtJourneyProfileRecord", "HrtPeriodRecord"]
        )
        XCTAssertEqual(Set(revisions.map(\.localRevision)).count, 1)
    }

    func testAttachmentIntegrityFailureMovesMatchingReadyGenerationToRecovery() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let generationID = UUID()
        let store = BootstrappedAppDataStore(
            container: container,
            generationID: generationID,
            storeURL: URL(fileURLWithPath: "/test-only/in-memory.store"),
            origin: .newInstall,
            protectionReport: StoreFileProtectionReport(
                entries: [],
                requiresPhysicalDeviceValidation: true
            )
        )
        let runtime = AppDataRuntime { store }
        runtime.openIfNeeded()
        await waitUntilSettled(runtime)

        runtime.handleAttachmentIntegrityFailure(generationID: UUID())
        guard case .ready = runtime.state else {
            return XCTFail("A stale generation callback must not replace ready state")
        }

        guard case let .ready(session) = runtime.state else {
            return XCTFail("Expected ready session before matching Recovery")
        }
        let retainedAttachmentService = session.attachmentMutationService
        runtime.handleAttachmentIntegrityFailure(generationID: generationID)
        guard case let .recovery(recovery) = runtime.state else {
            return XCTFail("Expected attachment integrity failure to enter Recovery")
        }
        XCTAssertEqual(recovery.reason, .corruptionSuspected)
        do {
            try await retainedAttachmentService.addJourneyEntry(
                AddJourneyEntryCommand(
                    text: "Recovery 后不应写入",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: []
            )
            XCTFail("A retained generation service must be invalid after Recovery")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .recoveryRequired
            )
        }
    }

    func testInvalidPointerMessagePromisesNoAutomaticDeletion() {
        let recovery = AppDataRecoveryState(reason: .invalidGenerationPointer)

        XCTAssertTrue(recovery.userMessage.contains("不会自动删除"))
        XCTAssertFalse(recovery.userMessage.contains("sqlite"))
    }

    func testNestedProtectedDataErrorKeepsProtectedDataClassification() {
        let permissionError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError
        )
        let wrapper = NSError(
            domain: "SwiftData.Error",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: permissionError]
        )

        XCTAssertEqual(
            AppDataFailure.classifyStorage(wrapper, fallback: .corruptionSuspected),
            .protectedDataUnavailable
        )
    }

    func testDetailedProtectedDataErrorKeepsProtectedDataClassification() {
        let permissionError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError
        )
        let wrapper = NSError(
            domain: "SwiftData.Error",
            code: 2,
            userInfo: ["NSDetailedErrors": [permissionError]]
        )

        XCTAssertEqual(
            AppDataFailure.classifyStorage(wrapper, fallback: .migrationFailed),
            .protectedDataUnavailable
        )
    }

    func testDebugRecoveryLaunchArgumentSelectsRequestedFailure() {
        XCTAssertEqual(
            DebugRecoveryLaunchConfiguration.failure(
                arguments: ["Unmanual", "-unmanual-recovery", "corruptionSuspected"]
            ),
            .corruptionSuspected
        )
        XCTAssertEqual(
            DebugRecoveryLaunchConfiguration.failure(
                arguments: ["Unmanual", "-unmanual-recovery", "protectedDataUnavailable"]
            ),
            .protectedDataUnavailable
        )
        XCTAssertNil(
            DebugRecoveryLaunchConfiguration.failure(arguments: ["Unmanual"])
        )
        XCTAssertEqual(
            DebugRecoveryLaunchConfiguration.failure(
                arguments: ["Unmanual"],
                environment: ["UNMANUAL_RECOVERY_REASON": "fileProtectionUnverified"]
            ),
            .fileProtectionUnverified
        )
    }

    func testOpeningDoesNotBlockMainActorWhileStorageWorkerIsSuspended() async {
        let started = expectation(description: "storage worker started")
        let release = AsyncStream<Void>.makeStream()
        let runtime = AppDataRuntime {
            started.fulfill()
            for await _ in release.stream { break }
            throw AppDataFailure.storageUnavailable
        }

        runtime.openIfNeeded()
        await fulfillment(of: [started], timeout: 1)

        var mainActorAdvanced = false
        await Task.yield()
        mainActorAdvanced = true
        guard case .opening = runtime.state else {
            return XCTFail("Expected opening while the worker is suspended")
        }
        XCTAssertTrue(mainActorAdvanced)
        release.continuation.yield()
        release.continuation.finish()
        await waitUntilSettled(runtime)
    }

    func testRecoveryViewRendersAtRepresentativeLayoutSizes() throws {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024)
        ]
        for size in sizes {
            let image = render(
                RecoveryModeView(
                    recovery: AppDataRecoveryState(reason: .corruptionSuspected),
                    retry: {}
                )
                .environment(AppTheme())
                .environment(\.dynamicTypeSize, .large)
                .frame(width: size.width, height: size.height),
                size: size
            )
            XCTAssertEqual(image.size, size)
            assertContainsForeground(image)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Recovery-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = XCTAttachment.Lifetime.keepAlways
            add(attachment)
        }

        let largeTypeImage = render(
            RecoveryModeView(
                recovery: AppDataRecoveryState(reason: .fileProtectionUnverified),
                retry: {}
            )
            .environment(AppTheme())
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: 320, height: 568),
            size: CGSize(width: 320, height: 568)
        )
        assertContainsForeground(largeTypeImage)
        let attachment = XCTAttachment(image: largeTypeImage)
        attachment.name = "Recovery-320x568-Accessibility5"
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
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
            XCTAssertTrue(
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true),
                "Expected the hosted Recovery view to draw successfully."
            )
        }
        window.isHidden = true
        return image
    }

    private func assertContainsForeground(
        _ image: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data,
              cgImage.bitsPerPixel >= 24 else {
            return XCTFail("Expected a readable RGB Recovery render.", file: file, line: line)
        }

        let bytes = CFDataGetBytePtr(providerData)!
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        var minimum = Int.max
        var maximum = Int.min
        for y in stride(from: 0, to: cgImage.height, by: 12) {
            for x in stride(from: 0, to: cgImage.width, by: 12) {
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                let brightness = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                minimum = min(minimum, brightness)
                maximum = max(maximum, brightness)
            }
        }

        XCTAssertGreaterThan(
            maximum - minimum,
            80,
            "Expected foreground contrast instead of a blank or solid-color render.",
            file: file,
            line: line
        )
    }

    private func waitUntilSettled(_ runtime: AppDataRuntime) async {
        for _ in 0..<100 {
            if case .opening = runtime.state {
                await Task.yield()
            } else {
                return
            }
        }
    }
}

@MainActor
final class ZZSystemBackupDisclosureRenderTests: XCTestCase {
    func testTodayDisclosureRendersAboveRealTabBarAt320x568Accessibility5() throws {
        let size = CGSize(width: 320, height: 568)
        let theme = AppTheme()
        let view = AppShellView()
            .environment(theme)
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: size.width, height: size.height)

        attach(
            try renderScrolledToBottom(view, size: size),
            named: "SystemBackup-Today-AppShell-320x568-Accessibility5-Bottom"
        )
    }

    func testViewsRenderAtRepresentativeLayoutSizes() throws {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024)
        ]

        for size in sizes {
            for (name, view) in views(size: size, dynamicTypeSize: .large) {
                attach(render(view, size: size), named: "SystemBackup-\(name)-\(Int(size.width))x\(Int(size.height))")
            }
        }

        let accessibilitySize = CGSize(width: 320, height: 568)
        for (name, view) in views(size: accessibilitySize, dynamicTypeSize: .accessibility5) {
            attach(render(view, size: accessibilitySize), named: "SystemBackup-\(name)-320x568-Accessibility5")
        }
    }

    private func views(
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize
    ) -> [(String, AnyView)] {
        let theme = AppTheme()
        return [
            (
                "Today",
                AnyView(
                    V25TodayHome(
                        profile: nil,
                        countdown: nil,
                        regimens: [],
                        latestLab: nil,
                        entries: [],
                        quickRecordAction: {},
                        startDateAction: {},
                        countdownAction: {},
                        regimenAction: {},
                        metricsAction: {},
                        journeyAction: {}
                    )
                    .environment(theme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .frame(width: size.width, height: size.height, alignment: .top)
                )
            ),
            (
                "Archive",
                AnyView(
                    ArchiveView()
                        .environment(theme)
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                        .frame(width: size.width, height: size.height)
                )
            ),
            (
                "QuickRecord",
                AnyView(
                    QuickRecordEditor(autofocus: false)
                        .environment(theme)
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                        .frame(width: size.width, height: size.height)
                )
            ),
            (
                "Countdown",
                AnyView(
                    CountdownEditor()
                        .environment(theme)
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                        .frame(width: size.width, height: size.height)
                )
            ),
            (
                "Regimen",
                AnyView(
                    NavigationStack { RegimenView() }
                        .environment(theme)
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                        .frame(width: size.width, height: size.height)
                )
            ),
            (
                "RegimenEditor",
                AnyView(
                    RegimenVersionEditor(
                        initialMedications: [
                            RegimenMedicationDraft(
                                name: "药盒原文",
                                detail: "片剂 · 口服 · 一片",
                                dosageForm: "片剂",
                                route: "口服",
                                doseOriginal: "一片",
                                unitOriginal: "片",
                                origin: .custom
                            )
                        ]
                    )
                    .environment(theme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .frame(width: size.width, height: size.height)
                )
            )
        ]
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
        window.rootViewController = nil
        window.isHidden = true
        return image
    }

    private func renderScrolledToBottom<Content: View>(
        _ content: Content,
        size: CGSize
    ) throws -> UIImage {
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            descendants(of: host.view)
                .compactMap { $0 as? UIScrollView }
                .filter { $0.contentSize.height > $0.bounds.height }
                .max { $0.contentSize.height < $1.contentSize.height }
        )
        let bottomOffset = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height
                + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: bottomOffset),
            animated: false
        )
        scrollView.layoutIfNeeded()
        host.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.y, bottomOffset, accuracy: 1)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        window.rootViewController = nil
        window.isHidden = true
        return image
    }

    private func descendants(of root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func attach(_ image: UIImage, named name: String) {
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
