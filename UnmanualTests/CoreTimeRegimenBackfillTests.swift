import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class CoreTimeRegimenBackfillTests: XCTestCase {
    func testBackfillCreatesSealedCivilDateRegimenWithoutInventingItems() throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        let context = ModelContext(container)
        let regimenID = UUID(uuidString: "22000000-0000-0000-0000-000000000001")!
        context.insert(
            RegimenVersion(
                id: regimenID,
                code: "R-01",
                title: "旧方案",
                startedAt: Date(timeIntervalSince1970: 1_767_225_600),
                note: "原备注",
                createdAt: Date(timeIntervalSince1970: 1_767_225_601)
            )
        )
        try context.save()
        _ = try LegacyV1Backfill.run(in: container)

        let outcome = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )

        let versions = try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>())
        XCTAssertTrue(outcome.didComplete)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.id, regimenID)
        XCTAssertEqual(versions.first?.effectiveStartDate?.iso8601, "2026-01-01")
        XCTAssertEqual(versions.first?.editState, .sealed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenItemRecord>()), 0)
    }

    func testOpenEndedLegacyVersionDerivesBoundaryFromNextVersionWithoutReviewFlag() throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        let context = ModelContext(container)
        let firstID = UUID(uuidString: "22000000-0000-0000-0000-000000000011")!
        let secondID = UUID(uuidString: "22000000-0000-0000-0000-000000000012")!
        context.insert(
            RegimenVersion(
                id: firstID,
                code: "R-01",
                title: "旧方案",
                startedAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        context.insert(
            RegimenVersion(
                id: secondID,
                code: "R-02",
                title: "后续方案",
                startedAt: Date(timeIntervalSince1970: 1_769_904_000)
            )
        )
        try context.save()
        _ = try LegacyV1Backfill.run(in: container)

        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )

        let versions = try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>())
            .sorted { $0.effectiveStartDate! < $1.effectiveStartDate! }
        XCTAssertEqual(versions.map(\.id), [firstID, secondID])
        XCTAssertEqual(versions[0].previousVersionID, nil)
        XCTAssertEqual(versions[1].previousVersionID, firstID)
        XCTAssertFalse(versions[0].requiresMigrationReview)
        XCTAssertFalse(versions[1].requiresMigrationReview)
        let issues = try context.fetch(FetchDescriptor<MigrationIssue>())
        XCTAssertFalse(issues.contains { $0.kind == .overlappingCanonicalRegimen })
    }

    func testOpenEndedLegacyVersionsResolveHistoryUsingDerivedBoundary() throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        let context = ModelContext(container)
        let firstID = UUID(uuidString: "22000000-0000-0000-0000-000000000021")!
        let secondID = UUID(uuidString: "22000000-0000-0000-0000-000000000022")!
        let entryID = UUID(uuidString: "22000000-0000-0000-0000-000000000023")!
        context.insert(
            RegimenVersion(
                id: firstID,
                code: "R-01",
                title: "旧方案",
                startedAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        context.insert(
            RegimenVersion(
                id: secondID,
                code: "R-02",
                title: "后续方案",
                startedAt: Date(timeIntervalSince1970: 1_769_904_000)
            )
        )
        context.insert(
            JourneyEntry(
                id: entryID,
                text: "第二版生效后的记录",
                kind: .change,
                occurredAt: Date(timeIntervalSince1970: 1_770_076_800),
                regimenVersionID: nil
            )
        )
        try context.save()
        _ = try LegacyV1Backfill.run(in: container)

        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")

        let historical = try XCTUnwrap(
            context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first {
                $0.sourceRecordID == entryID
            }
        )
        XCTAssertEqual(historical.resolvedRegimenVersionID, secondID)
        XCTAssertEqual(historical.associationStateRawValue, HistoricalAssociationState.resolved.rawValue)
        XCTAssertFalse(try context.fetch(FetchDescriptor<MigrationIssue>()).contains {
            $0.recordID == entryID && $0.kind == .ambiguousCanonicalRegimenAssociation
        })
    }
}
