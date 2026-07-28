import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class HrtJourneyRenderTests: XCTestCase {
    func testTodayOptionalSurfaceStatesRenderAcrossRequiredSizes() {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 844, height: 390)
        ]
        for size in sizes {
            for fixture in todayFixtures {
                let image = render(
                    today(
                        fixture: fixture,
                        dynamicTypeSize: .large,
                        size: size
                    ),
                    size: size
                )
                assertContainsForeground(
                    image,
                    context:
                        "Today \(fixture.name) "
                        + "\(Int(size.width))x\(Int(size.height))"
                )
                attach(
                    image,
                    named:
                        "TodayOptional-\(fixture.name)-"
                        + "\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testTodayActiveAndPausedRenderAtAccessibilityFive() {
        let size = CGSize(width: 320, height: 568)
        for fixture in todayFixtures
        where fixture.snapshot != nil {
            let image = render(
                today(
                    fixture: fixture,
                    dynamicTypeSize: .accessibility5,
                    size: size
                ),
                size: size
            )
            assertContainsForeground(
                image,
                context:
                    "Today \(fixture.name) Accessibility5"
            )
            attach(
                image,
                named:
                    "TodayOptional-\(fixture.name)-"
                    + "320x568-Accessibility5"
            )
        }
    }

    func testEditorStatesRenderAcrossRequiredSizes() {
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
                    editor(
                        fixture: fixture,
                        dynamicTypeSize: .large,
                        size: size
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
                        "HrtJourney-\(fixture.name)-"
                        + "\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testEditorStatesRenderAtAccessibilityFive() {
        let size = CGSize(width: 320, height: 568)
        for fixture in fixtures {
            let image = render(
                editor(
                    fixture: fixture,
                    dynamicTypeSize: .accessibility5,
                    size: size
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
                    "HrtJourney-\(fixture.name)-"
                    + "320x568-Accessibility5"
            )
        }
    }

    private struct Fixture {
        let name: String
        let snapshot: HrtJourneySnapshot?
        let startsLoaded: Bool
        let readErrorMessage: String?
        let isSaving: Bool
        let automaticallyLoads: Bool
    }

    private struct TodayFixture {
        let name: String
        let snapshot: HrtJourneySnapshot?
        let latestLab: PersonalTimelineItem?
    }

    private var todayFixtures: [TodayFixture] {
        [
            TodayFixture(
                name: "active",
                snapshot: activeSnapshot,
                latestLab: nil
            ),
            TodayFixture(
                name: "paused",
                snapshot: pausedSnapshot,
                latestLab: nil
            ),
            TodayFixture(
                name: "empty-with-lab",
                snapshot: nil,
                latestLab: latestLab
            )
        ]
    }

    private func today(
        fixture: TodayFixture,
        dynamicTypeSize: DynamicTypeSize,
        size: CGSize
    ) -> some View {
        V25Page {
            V25TodayHome(
                profile: nil,
                hrtJourney: fixture.snapshot,
                countdown: nil,
                regimens: [],
                latestLab: fixture.latestLab,
                entries: [],
                quickRecordAction: {},
                startDateAction: {},
                countdownAction: {},
                regimenAction: {},
                metricsAction: {},
                journeyAction: {}
            )
        }
        .environment(AppTheme())
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .frame(width: size.width, height: size.height)
    }

    private var fixtures: [Fixture] {
        [
            Fixture(
                name: "empty",
                snapshot: nil,
                startsLoaded: true,
                readErrorMessage: nil,
                isSaving: false,
                automaticallyLoads: true
            ),
            Fixture(
                name: "active-multiple-cycle",
                snapshot: activeSnapshot,
                startsLoaded: true,
                readErrorMessage: nil,
                isSaving: false,
                automaticallyLoads: true
            ),
            Fixture(
                name: "paused",
                snapshot: pausedSnapshot,
                startsLoaded: true,
                readErrorMessage: nil,
                isSaving: false,
                automaticallyLoads: true
            ),
            Fixture(
                name: "loading",
                snapshot: nil,
                startsLoaded: false,
                readErrorMessage: nil,
                isSaving: false,
                automaticallyLoads: false
            ),
            Fixture(
                name: "error",
                snapshot: nil,
                startsLoaded: true,
                readErrorMessage: "本地资料没有通过完整性检查。",
                isSaving: false,
                automaticallyLoads: false
            ),
            Fixture(
                name: "saving",
                snapshot: activeSnapshot,
                startsLoaded: true,
                readErrorMessage: nil,
                isSaving: true,
                automaticallyLoads: false
            )
        ]
    }

    private func editor(
        fixture: Fixture,
        dynamicTypeSize: DynamicTypeSize,
        size: CGSize
    ) -> some View {
        StartDateEditor(
            purpose: .lifecycle,
            initialSnapshot: fixture.snapshot,
            startsLoaded: fixture.startsLoaded,
            initialReadErrorMessage: fixture.readErrorMessage,
            initiallySaving: fixture.isSaving,
            automaticallyLoads: fixture.automaticallyLoads
        )
        .environment(AppTheme())
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .frame(width: size.width, height: size.height)
    }

    private var activeSnapshot: HrtJourneySnapshot {
        let first = try! CivilDateFact(
            year: 2026,
            month: 1,
            day: 1
        )
        let resumed = try! CivilDateFact(
            year: 2026,
            month: 1,
            day: 15
        )
        return HrtJourneySnapshot(
            firstEverStartDate: first,
            periods: [
                HrtPeriodFact(
                    id: UUID(
                        uuidString:
                            "96000000-0000-0000-0000-000000000001"
                    )!,
                    startDate: first,
                    endDate: try! CivilDateFact(
                        year: 2026,
                        month: 1,
                        day: 11
                    ),
                    note: ""
                ),
                HrtPeriodFact(
                    id: UUID(
                        uuidString:
                            "96000000-0000-0000-0000-000000000002"
                    )!,
                    startDate: resumed,
                    endDate: nil,
                    note: ""
                )
            ],
            summary: HrtJourneySummary(
                state: .active,
                overallJourneyDay: 20,
                currentPhaseDay: 6,
                pausedDay: nil,
                pausedSince: nil,
                periodCount: 2
            ),
            latestEventID: UUID(
                uuidString:
                    "96000000-0000-0000-0000-000000000003"
            )!,
            events: [
                event(
                    id: "96000000-0000-0000-0000-000000000003",
                    kind: .resumed,
                    date: resumed
                )
            ]
        )
    }

    private var pausedSnapshot: HrtJourneySnapshot {
        let first = try! CivilDateFact(
            year: 2026,
            month: 2,
            day: 1
        )
        let paused = try! CivilDateFact(
            year: 2026,
            month: 2,
            day: 10
        )
        return HrtJourneySnapshot(
            firstEverStartDate: first,
            periods: [
                HrtPeriodFact(
                    id: UUID(
                        uuidString:
                            "97000000-0000-0000-0000-000000000001"
                    )!,
                    startDate: first,
                    endDate: paused,
                    note: ""
                )
            ],
            summary: HrtJourneySummary(
                state: .paused,
                overallJourneyDay: 12,
                currentPhaseDay: nil,
                pausedDay: 3,
                pausedSince: paused,
                periodCount: 1
            ),
            latestEventID: UUID(
                uuidString:
                    "97000000-0000-0000-0000-000000000002"
            )!,
            events: [
                event(
                    id: "97000000-0000-0000-0000-000000000002",
                    kind: .paused,
                    date: paused
                )
            ]
        )
    }

    private var latestLab: PersonalTimelineItem {
        let timestamp = try! HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_741_046_400),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        return PersonalTimelineItem(
            id: UUID(
                uuidString:
                    "98000000-0000-0000-0000-000000000001"
            )!,
            kind: .labSample,
            title: "化验记录",
            detail: "雌二醇 172.5 pmol/L",
            timestamp: timestamp,
            dateOnly: nil,
            localDate: timestamp.localDate
        )
    }

    private func event(
        id: String,
        kind: HrtJourneyLifecycleEventKind,
        date: CivilDateFact
    ) -> HrtJourneyLifecycleEventSnapshot {
        HrtJourneyLifecycleEventSnapshot(
            id: UUID(uuidString: id)!,
            kind: kind,
            periodID: nil,
            transitionDate: date,
            note: "",
            timestamp: try! HistoricalTimestamp.captured(
                instant: Date(timeIntervalSince1970: 1_768_953_600),
                timeZoneIdentifier: "UTC"
            )
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
