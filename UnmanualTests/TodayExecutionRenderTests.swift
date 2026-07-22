import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class TodayExecutionRenderTests: XCTestCase {
    func testLatestTodayRefreshGateRejectsAnEarlierCompletion() {
        var gate = TodayLatestRequestGate()

        let earlier = gate.begin()
        let latest = gate.begin()

        XCTAssertFalse(gate.isCurrent(earlier))
        XCTAssertTrue(gate.isCurrent(latest))
    }

    func testSemanticTextTokensMeetWCAGAAOnPaperAndRice() {
        for foreground in [
            AppColorTokens.secondaryText,
            AppColorTokens.vermilionText,
            AppColorTokens.blueText,
            AppColorTokens.mossText,
            AppColorTokens.mustardText
        ] {
            for background in [AppColorTokens.paper, AppColorTokens.rice] {
                XCTAssertGreaterThanOrEqual(
                    wcagContrastRatio(
                        foreground: foreground,
                        background: background
                    ),
                    4.5
                )
            }
        }
    }

    func testRuntimeReminderFailureOverridesPersistedCoveragePresentation() {
        let title = TodayReminderCoveragePresentation.title(
            coverage: NotificationCoverageSnapshot(
                status: .scheduledForWindow,
                scheduledThrough: Date(timeIntervalSince1970: 1_753_181_400),
                desiredCount: 1,
                confirmedPendingCount: 1,
                lastErrorCode: nil,
                observedAt: Date(timeIntervalSince1970: 1_753_181_000)
            ),
            runtimeErrorCode: "reconciliation-unavailable"
        )

        XCTAssertEqual(title, "部分提醒尚未安排，请打开 App 重试")
    }

    func testActionGateRejectsRapidSecondMutationUntilFirstFinishes() {
        var gate = TodayExecutionActionGate()

        XCTAssertTrue(gate.begin(occurrenceKey: "occurrence"))
        XCTAssertFalse(gate.begin(occurrenceKey: "occurrence"))
        XCTAssertEqual(gate.inFlightOccurrenceKeys, ["occurrence"])

        gate.finish(occurrenceKey: "occurrence")
        XCTAssertTrue(gate.begin(occurrenceKey: "occurrence"))
    }

    func testLedgerRendersAtRepresentativePhoneLandscapeAndPadSizes() throws {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024)
        ]

        for size in sizes {
            let image = try renderLedger(
                size: size,
                dynamicTypeSize: .large
            )
            assertContainsForeground(image)
            attach(image, named: "TodayExecution-\(Int(size.width))x\(Int(size.height))")
        }
    }

    func testLedgerRendersAtAccessibilityFive() throws {
        let size = CGSize(width: 320, height: 568)
        let image = try renderLedger(
            size: size,
            dynamicTypeSize: .accessibility5
        )

        assertContainsForeground(image)
        attach(image, named: "TodayExecution-320x568-Accessibility5")
    }

    func testExecutionSheetsRemainScrollableAt320x568AccessibilityFive() throws {
        let item = try XCTUnwrap(fixtureSnapshot().items.first)
        let views: [(String, AnyView)] = [
            (
                "reminder",
                AnyView(
                    LocalReminderConsentSheet(
                        item: item,
                        cancel: {},
                        confirm: {}
                    )
                )
            ),
            (
                "correction",
                AnyView(
                    TodayExecutionCorrectionSheet(
                        item: item,
                        cancel: {},
                        save: { _, _ in }
                    )
                )
            )
        ]

        for (name, view) in views {
            let rendered = renderSheet(
                view,
                size: CGSize(width: 320, height: 568),
                dynamicTypeSize: .accessibility5
            )
            XCTAssertTrue(rendered.hasScrollableContent)
            assertContainsForeground(rendered.image)
            attach(
                rendered.image,
                named: "TodayExecution-\(name)-320x568-Accessibility5"
            )
        }
    }

    func testLedgerRendersBusyRowWithSavingFeedback() throws {
        let snapshot = try fixtureSnapshot()
        let occurrenceKey = try XCTUnwrap(snapshot.items.first?.id)
        let image = try renderLedger(
            size: CGSize(width: 390, height: 844),
            dynamicTypeSize: .large,
            snapshot: snapshot,
            inFlightOccurrenceKeys: [occurrenceKey]
        )

        assertContainsForeground(image)
        attach(image, named: "TodayExecution-state-saving")
    }

    func testLedgerRendersLoadingErrorEmptyReviewAndRecordedStates() throws {
        let size = CGSize(width: 390, height: 844)
        let variants: [(String, TodayExecutionSnapshot, Bool, String?, Bool)] = [
            ("loading", try fixtureSnapshot(), true, nil, false),
            ("error", try fixtureSnapshot(), false, "本地资料暂时无法读取。", false),
            ("empty", .empty, false, nil, false),
            (
                "empty-permission-denied",
                try fixtureSnapshot(coverageStatus: .blockedByPermission, includeItem: false),
                false,
                nil,
                false
            ),
            ("taken", try fixtureSnapshot(state: .taken), false, nil, false),
            ("skipped", try fixtureSnapshot(state: .skipped), false, nil, false),
            ("snoozed", try fixtureSnapshot(snoozedUntil: Date().addingTimeInterval(600)), false, nil, false),
            ("permission-denied", try fixtureSnapshot(coverageStatus: .blockedByPermission), false, nil, false),
            ("reduce-motion", try fixtureSnapshot(), false, nil, true),
            (
                "mixed-review",
                try fixtureSnapshot(
                    reviewIssues: [.invalidRule(UUID())],
                    coverageStatus: .limitedByBudget
                ),
                false,
                nil,
                false
            )
        ]

        for (name, snapshot, isLoading, error, reduceMotion) in variants {
            let image = try renderLedger(
                size: size,
                dynamicTypeSize: .large,
                snapshot: snapshot,
                isLoading: isLoading,
                errorMessage: error,
                reduceMotion: reduceMotion
            )
            assertContainsForeground(image)
            attach(image, named: "TodayExecution-state-\(name)")
        }
    }

    private func renderLedger(
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize,
        snapshot: TodayExecutionSnapshot? = nil,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        reduceMotion: Bool = false,
        inFlightOccurrenceKeys: Set<String> = []
    ) throws -> UIImage {
        let snapshot = try snapshot ?? fixtureSnapshot()
        let theme = AppTheme()
        let content = ScrollView {
            TodayExecutionLedger(
                snapshot: snapshot,
                isLoading: isLoading,
                errorMessage: errorMessage,
                inFlightOccurrenceKeys: inFlightOccurrenceKeys,
                runtimeReminderErrorCode: nil,
                retryAction: {},
                createPlanAction: {},
                administrationAction: { _, _ in },
                snoozeAction: { _ in },
                reminderAction: { _ in },
                correctionAction: { _ in }
            )
            .padding(.horizontal, 16)
        }
        .background(theme.rice)
        .environment(theme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.v25ReduceMotionOverride, reduceMotion ? true : nil)
        .frame(width: size.width, height: size.height)

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

    private func renderSheet(
        _ view: AnyView,
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize
    ) -> (image: UIImage, hasScrollableContent: Bool) {
        let theme = AppTheme()
        let content = view
            .environment(theme)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let scrollViews = allSubviews(of: host.view).compactMap { $0 as? UIScrollView }
        let hasScrollableContent = scrollViews.contains {
            $0.contentSize.height > $0.bounds.height + 1
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        window.rootViewController = nil
        window.isHidden = true
        return (image, hasScrollableContent)
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    private func fixtureSnapshot(
        state: TodayExecutionState = .unrecorded,
        reviewIssues: [ScheduleOccurrenceIssue] = [],
        coverageStatus: NotificationCoverageStatus = .scheduledForWindow,
        snoozedUntil: Date? = nil,
        includeItem: Bool = true
    ) throws -> TodayExecutionSnapshot {
        let instant = Date(timeIntervalSince1970: 1_753_181_400)
        let occurrence = PlannedOccurrence(
            key: "occ:v1:50000000-0000-0000-0000-000000000001:1:20260722T0830",
            scheduleRuleID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            scheduleRevision: 1,
            regimenVersionID: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
            regimenItemID: UUID(uuidString: "50000000-0000-0000-0000-000000000003")!,
            displayName: "方案项目原文",
            localDate: try CivilDateFact(year: 2025, month: 7, day: 22),
            localTime: try HistoricalLocalTime(hour: 8, minute: 30, second: 0),
            timeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            instant: instant
        )
        let item = TodayExecutionItemSnapshot(
            occurrence: occurrence,
            state: state,
            effectiveEventID: nil,
            actualTimestamp: nil,
            effectiveOverrideID: nil,
            snoozedUntil: snoozedUntil,
            reminderEnabled: true,
            defaultSnoozeMinutes: 10
        )
        return TodayExecutionSnapshot(
            items: includeItem ? [item] : [],
            coverage: NotificationCoverageSnapshot(
                status: coverageStatus,
                scheduledThrough: coverageStatus == .blockedByPermission
                    ? nil
                    : instant.addingTimeInterval(86_400),
                desiredCount: coverageStatus == .blockedByPermission ? 0 : 14,
                confirmedPendingCount: coverageStatus == .blockedByPermission ? 0 : 14,
                lastErrorCode: nil,
                observedAt: instant
            ),
            reviewIssues: reviewIssues
        )
    }

    private func assertContainsForeground(
        _ image: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data,
              cgImage.bitsPerPixel >= 24 else {
            return XCTFail("Expected a readable RGB render.", file: file, line: line)
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
        XCTAssertGreaterThan(maximum - minimum, 80, file: file, line: line)
    }

    private func attach(_ image: UIImage, named name: String) {
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wcagContrastRatio(foreground: UInt, background: UInt) -> Double {
        func luminance(_ value: UInt) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let component = Double((value >> UInt(shift)) & 0xFF) / 255
                return component <= 0.04045
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
