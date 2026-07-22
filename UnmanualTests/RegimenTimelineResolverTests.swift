import XCTest
@testable import Unmanual

final class RegimenTimelineResolverTests: XCTestCase {
    func testFutureSealedVersionDoesNotBecomeCurrentBeforeItsCivilStartDate() throws {
        let currentID = UUID()
        let futureID = UUID()
        let today = try CivilDateFact(year: 2026, month: 7, day: 21)
        let versions = [
            RegimenTimelineVersion(
                id: currentID,
                start: try CivilDateFact(year: 2026, month: 1, day: 1),
                end: try CivilDateFact(year: 2026, month: 8, day: 1),
                editState: .sealed,
                requiresReview: false
            ),
            RegimenTimelineVersion(
                id: futureID,
                start: try CivilDateFact(year: 2026, month: 8, day: 1),
                end: nil,
                editState: .sealed,
                requiresReview: false
            )
        ]

        let projection = RegimenTimelineResolver.project(versions, asOf: today)

        XCTAssertEqual(projection.current?.id, currentID)
        XCTAssertEqual(projection.upcoming.map(\.id), [futureID])
        XCTAssertTrue(projection.history.isEmpty)
        XCTAssertFalse(projection.isAmbiguous)
    }

    func testNextSealedStartDerivesPreviousHalfOpenEndWithoutMutatingHistory() throws {
        let oldID = UUID()
        let newID = UUID()
        let versions = [
            RegimenTimelineVersion(
                id: oldID,
                start: try CivilDateFact(year: 2026, month: 1, day: 1),
                end: nil,
                editState: .sealed,
                requiresReview: false
            ),
            RegimenTimelineVersion(
                id: newID,
                start: try CivilDateFact(year: 2026, month: 8, day: 1),
                end: nil,
                editState: .sealed,
                requiresReview: false
            )
        ]

        let projection = RegimenTimelineResolver.project(
            versions,
            asOf: try CivilDateFact(year: 2026, month: 8, day: 1)
        )

        XCTAssertEqual(projection.current?.id, newID)
        XCTAssertEqual(projection.history.map(\.id), [oldID])
        XCTAssertFalse(projection.isAmbiguous)
    }
}
