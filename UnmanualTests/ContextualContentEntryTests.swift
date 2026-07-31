import Foundation
import XCTest
@testable import Unmanual

final class ContextualContentEntryTests: XCTestCase {
    func testFiveScenariosResolveOnlyTheirFrozenAnchorAndCard()
        throws {
        let snapshot = try contentSnapshot()
        let expectations: [
            OfflineContextualContentScenario:
                (anchorID: String, cardID: String, purpose: String)
        ] = [
            .regimenField: (
                "anchor.regimen-field",
                "guide.regimen-field",
                "解释方案名称、剂型和给药途径字段。"
            ),
            .labRecording: (
                "anchor.lab-recording",
                "guide.lab-recording",
                "解释化验原件、单位和采样上下文。"
            ),
            .regimenAnalysisSource: (
                "anchor.regimen-analysis-source",
                "card.hrt-monitoring-005",
                "从方案分析进入对应离线教育摘要。"
            ),
            .visitPreparation: (
                "anchor.visit-preparation",
                "guide.visit-preparation",
                "主动打开首诊与复诊准备清单。"
            ),
            .timelineRecord: (
                "anchor.timeline-record",
                "guide.lab-recording",
                "从记录详情解释保留原件和上下文。"
            )
        ]

        for (scenario, expected) in expectations {
            let resolution = try XCTUnwrap(
                OfflineContextualContentScenarioResolver
                    .resolve(
                        scenario: scenario,
                        snapshot: snapshot
                    )
            )
            XCTAssertEqual(
                resolution.anchor.id,
                expected.anchorID
            )
            XCTAssertEqual(
                resolution.card.id,
                expected.cardID
            )
            XCTAssertEqual(
                resolution.anchor.purpose,
                expected.purpose
            )
        }
    }

    func testResolverFailsClosedForPocketDuplicateOrDanglingAnchor()
        throws {
        let snapshot = try contentSnapshot()
        XCTAssertNil(
            OfflineContextualContentScenarioResolver
                .resolve(
                    scenario: .pocketAppendix,
                    snapshot: snapshot
                )
        )

        let regimenAnchor = try XCTUnwrap(
            snapshot.scenarioAnchors.first {
                $0.scenario == .regimenField
            }
        )
        let duplicated = replacingAnchors(
            in: snapshot,
            with:
                snapshot.scenarioAnchors
                + [
                    OfflineContextualContentScenarioAnchor(
                        id: "anchor.regimen-field.duplicate",
                        scenario: .regimenField,
                        purpose: regimenAnchor.purpose,
                        displayOrder:
                            regimenAnchor.displayOrder + 1,
                        cardID: regimenAnchor.cardID
                    )
                ]
        )
        XCTAssertNil(
            OfflineContextualContentScenarioResolver
                .resolve(
                    scenario: .regimenField,
                    snapshot: duplicated
                )
        )

        let dangling = replacingAnchors(
            in: snapshot,
            with:
                snapshot.scenarioAnchors.map {
                    guard $0.scenario == .regimenField else {
                        return $0
                    }
                    return OfflineContextualContentScenarioAnchor(
                        id: $0.id,
                        scenario: $0.scenario,
                        purpose: $0.purpose,
                        displayOrder: $0.displayOrder,
                        cardID: "guide.not-present"
                    )
                }
        )
        XCTAssertNil(
            OfflineContextualContentScenarioResolver
                .resolve(
                    scenario: .regimenField,
                    snapshot: dangling
                )
        )
    }

    func testAnalysisEligibilityCannotBypassUnansweredOrStopped() {
        XCTAssertEqual(
            ContextualContentEligibility
                .scenario(
                    for: RegimenAnalysisSemanticStatus.ready
                ),
            .regimenAnalysisSource
        )
        XCTAssertEqual(
            ContextualContentEligibility
                .scenario(
                    for: RegimenAnalysisSemanticStatus.limited
                ),
            .regimenAnalysisSource
        )
        XCTAssertNil(
            ContextualContentEligibility
                .scenario(
                    for: RegimenAnalysisSemanticStatus.unanswered
                )
        )
        XCTAssertNil(
            ContextualContentEligibility
                .scenario(
                    for: RegimenAnalysisSemanticStatus.stopped
                )
        )
    }

    func testTimelineEligibilityUsesClosedKindSetOnly() {
        for kind in [
            PersonalTimelineItemKind.statusObservation,
            .journeyEntry,
            .administration,
            .countdown,
            .regimenVersion,
            .hrtJourney
        ] {
            XCTAssertNil(
                ContextualContentEligibility.scenario(
                    for: kind
                )
            )
        }
        XCTAssertEqual(
            ContextualContentEligibility.scenario(
                for: .labSample
            ),
            .timelineRecord
        )
    }

    func testPresentationIsFrozenByScenarioAndNamesFiveStableEntries() {
        let expectations: [
            OfflineContextualContentScenario:
                (identifier: String, action: String)
        ] = [
            .regimenField: (
                "contextual.regimenField",
                "查看方案字段说明"
            ),
            .labRecording: (
                "contextual.labRecording",
                "查看化验记录说明"
            ),
            .regimenAnalysisSource: (
                "contextual.regimenAnalysisSource",
                "查看对应离线摘要"
            ),
            .visitPreparation: (
                "contextual.visitPreparation",
                "打开复诊准备清单"
            ),
            .timelineRecord: (
                "contextual.timelineRecord",
                "查看这类记录的说明"
            )
        ]

        for (scenario, expected) in expectations {
            let presentation = try? XCTUnwrap(
                ContextualContentScenarioPresentation
                    .make(for: scenario)
            )
            XCTAssertEqual(
                presentation?.identifier,
                expected.identifier
            )
            XCTAssertEqual(
                presentation?.actionTitle,
                expected.action
            )
        }
        XCTAssertNil(
            ContextualContentScenarioPresentation.make(
                for: .pocketAppendix
            )
        )
    }

    func testUnavailableCopyIsExplicitAndNonBlocking() {
        XCTAssertEqual(
            ContextualContentUnavailableCopy.detail(
                for:
                    .pendingHumanReviewAndClassification
            ),
            "内容尚未通过真实人类复核，不影响当前操作。"
        )
        XCTAssertTrue(
            ContextualContentUnavailableCopy.detail(
                for: .invalidContent([])
            ).contains("不影响当前操作")
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

    private func replacingAnchors(
        in snapshot: OfflineContextualContentSnapshot,
        with anchors:
            [OfflineContextualContentScenarioAnchor]
    ) -> OfflineContextualContentSnapshot {
        OfflineContextualContentSnapshot(
            manifest: snapshot.manifest,
            sources: snapshot.sources,
            cards: snapshot.cards,
            scenarioAnchors: anchors,
            attribution: snapshot.attribution,
            statusDate: snapshot.statusDate
        )
    }
}
