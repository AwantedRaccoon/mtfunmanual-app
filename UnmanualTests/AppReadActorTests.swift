import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class AppReadActorTests: XCTestCase {
    func testCoreRegimenOverviewSeparatesCurrentUpcomingHistoryAndPersistedComposition() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let old = RegimenPlanVersionRecord(
            code: "R-01",
            title: "历史",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
            effectiveEndDate: try CivilDateFact(year: 2026, month: 4, day: 1),
            editState: .sealed
        )
        let current = RegimenPlanVersionRecord(
            code: "R-02",
            title: "当前",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 4, day: 1),
            previousVersionID: old.id,
            editState: .sealed
        )
        let future = RegimenPlanVersionRecord(
            code: "R-03",
            title: "未来",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 9, day: 1),
            previousVersionID: current.id,
            editState: .sealed
        )
        let item = RegimenItemRecord(
            regimenVersionID: current.id,
            sortOrder: 0,
            catalogProductID: "catalog-product",
            catalogVersion: "2026.07",
            displayName: "药盒原文",
            route: "口服",
            doseOriginal: "一片",
            productSnapshot: "原始目录快照"
        )
        let schedule = ScheduleRuleRecord(
            regimenItemID: item.id,
            kind: .weekly,
            anchorDate: try CivilDateFact(year: 2026, month: 4, day: 1),
            localTimes: "08:30",
            weekdays: "2,5",
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "America/Chicago",
            reminderEnabled: false,
            defaultSnoozeMinutes: 15
        )
        context.insert(old)
        context.insert(current)
        context.insert(future)
        context.insert(item)
        context.insert(schedule)
        try context.save()

        let overview = try await AppReadActor(modelContainer: container).coreRegimenOverview(
            asOf: try CivilDateFact(year: 2026, month: 7, day: 21)
        )

        XCTAssertEqual(overview.current?.id, current.id)
        XCTAssertEqual(overview.current?.items.first?.displayName, "药盒原文")
        XCTAssertEqual(overview.current?.items.first?.catalogProductID, "catalog-product")
        XCTAssertEqual(overview.current?.items.first?.catalogVersion, "2026.07")
        XCTAssertEqual(overview.current?.items.first?.productSnapshot, "原始目录快照")
        XCTAssertEqual(overview.current?.items.first?.schedule?.kind, .weekly)
        XCTAssertEqual(overview.current?.items.first?.schedule?.localTimes, "08:30")
        XCTAssertEqual(overview.current?.items.first?.schedule?.weekdays, "2,5")
        XCTAssertEqual(overview.current?.items.first?.schedule?.fixedTimeZoneIdentifier, "America/Chicago")
        XCTAssertEqual(overview.upcoming.map(\.id), [future.id])
        XCTAssertEqual(overview.history.map(\.id), [old.id])
        XCTAssertFalse(overview.isTimelineAmbiguous)
    }

    func testTodaySnapshotReturnsImmutableBoundedScreenData() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(HRTProfile(startDate: base))
        context.insert(CountdownRecord(title: "较早", targetDate: base, createdAt: base))
        context.insert(
            CountdownRecord(
                title: "当前",
                targetDate: base.addingTimeInterval(86_400),
                createdAt: base.addingTimeInterval(1)
            )
        )
        for index in 0..<40 {
            let date = base.addingTimeInterval(TimeInterval(index))
            context.insert(RegimenVersion(code: "R-\(index)", title: "方案", startedAt: date))
            context.insert(JourneyEntry(text: "entry-\(index)", kind: .moment, occurredAt: date))
            context.insert(
                LabRecord(
                    itemName: "项目",
                    itemCode: "L\(index)",
                    rawValue: "\(index)",
                    numericValue: Double(index),
                    unit: "u",
                    sampledAt: date
                )
            )
        }
        try context.save()

        let snapshot = try await AppReadActor(modelContainer: container).todaySnapshot()
        assertSendable(snapshot)

        XCTAssertEqual(snapshot.profile?.startDate, base)
        XCTAssertEqual(snapshot.countdown?.title, "当前")
        XCTAssertEqual(snapshot.regimens.count, 32)
        XCTAssertEqual(snapshot.entries.count, 8)
        XCTAssertEqual(snapshot.labRecords.count, 32)
        XCTAssertEqual(snapshot.regimens.first?.code, "R-39")
        XCTAssertEqual(snapshot.entries.first?.text, "entry-39")
        XCTAssertEqual(snapshot.labRecords.first?.itemCode, "L39")
    }

    func testRegimenOverviewReturnsBoundedSortedSnapshots() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<140 {
            let date = base.addingTimeInterval(TimeInterval(index))
            context.insert(RegimenVersion(code: "R-\(index)", title: "方案", startedAt: date))
        }
        for index in 0..<40 {
            let date = base.addingTimeInterval(TimeInterval(index))
            context.insert(
                LabRecord(
                    itemName: "项目",
                    itemCode: "L\(index)",
                    rawValue: "\(index)",
                    numericValue: Double(index),
                    unit: "u",
                    sampledAt: date
                )
            )
        }
        try context.save()

        let snapshot = try await AppReadActor(modelContainer: container).regimenOverview()
        assertSendable(snapshot)

        XCTAssertEqual(snapshot.regimens.count, 128)
        XCTAssertEqual(snapshot.labRecords.count, 32)
        XCTAssertEqual(snapshot.regimens.first?.code, "R-139")
        XCTAssertEqual(snapshot.labRecords.first?.itemCode, "L39")
    }

    func testJourneyCursorReturnsStableBoundedPagesWithoutDuplicates() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<205 {
            context.insert(
                JourneyEntry(
                    text: "entry-\(index)",
                    kind: .moment,
                    occurredAt: base.addingTimeInterval(TimeInterval(index / 3)),
                    createdAt: base.addingTimeInterval(TimeInterval(index))
                )
            )
        }
        try context.save()
        let reader = AppReadActor(modelContainer: container)

        let first = try await reader.journeyPage(after: nil, limit: 100)
        let second = try await reader.journeyPage(after: first.nextCursor, limit: 100)
        let third = try await reader.journeyPage(after: second.nextCursor, limit: 100)
        let ids = first.entries.map(\.id) + second.entries.map(\.id) + third.entries.map(\.id)

        XCTAssertEqual(first.entries.count, 100)
        XCTAssertEqual(second.entries.count, 100)
        XCTAssertEqual(third.entries.count, 5)
        XCTAssertEqual(Set(ids).count, 205)
        XCTAssertNil(third.nextCursor)
        XCTAssertTrue(zip(first.entries, first.entries.dropFirst()).allSatisfy { lhs, rhs in
            lhs.occurredAt > rhs.occurredAt
                || (lhs.occurredAt == rhs.occurredAt && lhs.id > rhs.id)
        })
    }

    func testHistoricalSnapshotsKeepCanonicalLocalDateAcrossFallbackTimeZones() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2025-12-31T16:30:00Z")
        )
        let canonical = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "Asia/Shanghai",
            precision: .minute,
            provenance: .userEntered
        )
        let journey = JourneyEntry(text: "跨时区记录", kind: .moment, occurredAt: instant)
        let lab = LabRecord(
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "100",
            numericValue: 100,
            unit: "pmol/L",
            sampledAt: instant
        )
        context.insert(journey)
        context.insert(lab)
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "JourneyEntry",
                sourceRecordID: journey.id,
                timestamp: canonical,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: nil,
                associationState: .missing
            )
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "LabRecord",
                sourceRecordID: lab.id,
                timestamp: canonical,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: nil,
                associationState: .missing
            )
        )
        try context.save()
        let reader = AppReadActor(modelContainer: container)

        let page = try await reader.journeyPage(after: nil)
        let today = try await reader.todaySnapshot()
        let entry = try XCTUnwrap(page.entries.first)
        let labSnapshot = try XCTUnwrap(today.labRecords.first)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let expectedDate = try CivilDateFact(year: 2026, month: 1, day: 1)

        XCTAssertEqual(entry.historicalTimestamp?.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(labSnapshot.historicalTimestamp?.precision, .minute)
        XCTAssertEqual(entry.recordedLocalDate(fallbackTimeZone: shanghai), expectedDate)
        XCTAssertEqual(entry.recordedLocalDate(fallbackTimeZone: chicago), expectedDate)
        XCTAssertEqual(labSnapshot.recordedLocalDate(fallbackTimeZone: shanghai), expectedDate)
        XCTAssertEqual(labSnapshot.recordedLocalDate(fallbackTimeZone: chicago), expectedDate)

        let recordsForCanonicalDay = try await reader.labRecords(
            on: expectedDate,
            fallbackTimeZone: chicago
        )
        XCTAssertEqual(recordsForCanonicalDay.map(\.id), [lab.id])
    }

    func testReadFailsClosedWhenCanonicalHistoricalTimestampIsCorrupt() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let canonical = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let lab = LabRecord(
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "100",
            numericValue: 100,
            unit: "pmol/L",
            sampledAt: instant
        )
        let historical = HistoricalTimeRecord(
            sourceRecordType: "LabRecord",
            sourceRecordID: lab.id,
            timestamp: canonical,
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        historical.localMonth = 13
        context.insert(lab)
        context.insert(historical)
        try context.save()

        do {
            _ = try await AppReadActor(modelContainer: container).labRecords(
                on: canonical.localDate,
                fallbackTimeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
            )
            XCTFail("Expected a corrupt canonical timestamp to fail closed.")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testCivilDayReadRejectsSidecarWhoseRecordKeyDoesNotMatchItsSource() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let lab = LabRecord(
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "100",
            numericValue: 100,
            unit: "pmol/L",
            sampledAt: timestamp.instant
        )
        let historical = HistoricalTimeRecord(
            sourceRecordType: "LabRecord",
            sourceRecordID: lab.id,
            timestamp: timestamp,
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        historical.recordKey = "LabRecord:corrupt-(UUID().uuidString.lowercased())"
        context.insert(lab)
        context.insert(historical)
        try context.save()

        do {
            _ = try await AppReadActor(modelContainer: container).labRecords(
                on: timestamp.localDate,
                fallbackTimeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
            )
            XCTFail("Expected a mismatched sidecar key to fail closed.")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testCivilDayReadRejectsMultipleSidecarsForTheSameSource() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let lab = LabRecord(
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "100",
            numericValue: 100,
            unit: "pmol/L",
            sampledAt: timestamp.instant
        )
        let first = HistoricalTimeRecord(
            sourceRecordType: "LabRecord",
            sourceRecordID: lab.id,
            timestamp: timestamp,
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        let second = HistoricalTimeRecord(
            sourceRecordType: "LabRecord",
            sourceRecordID: lab.id,
            timestamp: timestamp,
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        first.recordKey = "LabRecord:duplicate-a-(UUID().uuidString.lowercased())"
        second.recordKey = "LabRecord:duplicate-b-(UUID().uuidString.lowercased())"
        context.insert(lab)
        context.insert(first)
        context.insert(second)
        try context.save()

        do {
            _ = try await AppReadActor(modelContainer: container).labRecords(
                on: timestamp.localDate,
                fallbackTimeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
            )
            XCTFail("Expected duplicate source sidecars to fail closed.")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testCivilDayReadRejectsDuplicateSourceAcrossDifferentFrozenLocalDays() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let instant = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 1,
                    day: 1,
                    hour: 0,
                    minute: 30
                )
            )
        )
        let utcTimestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: utc.identifier,
            precision: .minute,
            provenance: .userEntered
        )
        let chicagoTimestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: chicago.identifier,
            precision: .minute,
            provenance: .userEntered
        )
        XCTAssertNotEqual(utcTimestamp.localDate, chicagoTimestamp.localDate)

        let lab = LabRecord(
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "100",
            numericValue: 100,
            unit: "pmol/L",
            sampledAt: instant
        )
        let requestedDaySidecar = HistoricalTimeRecord(
            sourceRecordType: "LabRecord",
            sourceRecordID: lab.id,
            timestamp: utcTimestamp,
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        let otherDaySidecar = HistoricalTimeRecord(
            sourceRecordType: "LabRecord",
            sourceRecordID: lab.id,
            timestamp: chicagoTimestamp,
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        otherDaySidecar.recordKey = "LabRecord:duplicate-\(UUID().uuidString.lowercased())"
        context.insert(lab)
        context.insert(requestedDaySidecar)
        context.insert(otherDaySidecar)
        try context.save()

        do {
            _ = try await AppReadActor(modelContainer: container).labRecords(
                on: utcTimestamp.localDate,
                fallbackTimeZone: chicago
            )
            XCTFail("Expected cross-day duplicate sidecars to fail closed.")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testArchiveSnapshotUsesExactCountsAndExtrema() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let first = Date(timeIntervalSince1970: 1_600_000_000)
        let latest = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(HRTProfile(startDate: first))
        context.insert(CountdownRecord(title: "日期", targetDate: latest))
        context.insert(JourneyEntry(text: "记录", kind: .moment, occurredAt: latest))
        context.insert(RegimenVersion(code: "R-01", title: "方案", startedAt: first))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let firstComponents = calendar.dateComponents([.year, .month, .day], from: first)
        context.insert(
            RegimenPlanVersionRecord(
                code: "R-01",
                title: "方案",
                effectiveStartDate: try CivilDateFact(
                    year: try XCTUnwrap(firstComponents.year),
                    month: try XCTUnwrap(firstComponents.month),
                    day: try XCTUnwrap(firstComponents.day)
                ),
                editState: .sealed
            )
        )
        context.insert(
            LabRecord(
                itemName: "雌二醇",
                itemCode: "E2",
                rawValue: "1",
                numericValue: 1,
                unit: "pmol/L",
                sampledAt: latest
            )
        )
        try context.save()
        let reader = AppReadActor(modelContainer: container)

        let snapshot = try await reader.archiveSnapshot()

        XCTAssertEqual(snapshot.profileCount, 1)
        XCTAssertEqual(snapshot.countdownCount, 1)
        XCTAssertEqual(snapshot.journeyCount, 1)
        XCTAssertEqual(snapshot.regimenCount, 1)
        XCTAssertEqual(snapshot.labRecordCount, 1)
        XCTAssertEqual(snapshot.developmentExportItemCount, 5)
        XCTAssertEqual(snapshot.firstActivityDate, first)
        XCTAssertEqual(snapshot.latestActivityDate, latest)
    }

    func testArchiveSnapshotCountsCanonicalSealedRegimensWithoutCountingDraftsOrArchivedVersions() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let sealedDate = try CivilDateFact(year: 2024, month: 2, day: 3)
        context.insert(
            RegimenPlanVersionRecord(
                code: "R-01",
                title: "正式方案",
                effectiveStartDate: sealedDate,
                editState: .sealed
            )
        )
        context.insert(
            RegimenPlanVersionRecord(
                code: "DRAFT",
                title: "未封存草稿",
                effectiveStartDate: try CivilDateFact(year: 2023, month: 1, day: 1),
                editState: .draft
            )
        )
        context.insert(
            RegimenPlanVersionRecord(
                code: "R-00",
                title: "已归档方案",
                effectiveStartDate: try CivilDateFact(year: 2022, month: 1, day: 1),
                editState: .sealed,
                isArchived: true
            )
        )
        try context.save()

        let snapshot = try await AppReadActor(modelContainer: container).archiveSnapshot()
        XCTAssertEqual(snapshot.regimenCount, 1)
        XCTAssertTrue(snapshot.hasContent)
        XCTAssertEqual(snapshot.developmentExportItemCount, 0)
        let first = try XCTUnwrap(snapshot.firstActivityDate)
        let latest = try XCTUnwrap(snapshot.latestActivityDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: first).year, sealedDate.year)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: first).month, sealedDate.month)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: first).day, sealedDate.day)
        XCTAssertEqual(first, latest)
    }

    func testJourneyPageResolvesReferencedRegimenBeyondFirst128() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let context = ModelContext(container)
        var referencedID: UUID?
        for index in 0..<150 {
            let regimen = RegimenVersion(
                code: "R-\(index)",
                title: "方案 \(index)",
                startedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            context.insert(regimen)
            if index == 149 { referencedID = regimen.id }
        }
        let id = try XCTUnwrap(referencedID)
        context.insert(
            JourneyEntry(
                text: "旧方案关联",
                kind: .moment,
                occurredAt: Date(),
                regimenVersionID: id
            )
        )
        try context.save()

        let page = try await AppReadActor(modelContainer: container).journeyPage(after: nil)

        XCTAssertEqual(page.regimenCodes[id], "R-149")
    }

    func testLabRecordsForDayUsesDatePredicateInsteadOfGlobalRecentWindow() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let context = ModelContext(container)
        let oldDay = Date(timeIntervalSince1970: 1_600_000_000)
        context.insert(
            LabRecord(
                itemName: "雌二醇",
                itemCode: "E2",
                rawValue: "88",
                numericValue: 88,
                unit: "pmol/L",
                sampledAt: oldDay
            )
        )
        for index in 0..<1_600 {
            context.insert(
                LabRecord(
                    itemName: "新记录",
                    itemCode: "N\(index)",
                    rawValue: "1",
                    numericValue: 1,
                    unit: "u",
                    sampledAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
                )
            )
        }
        try context.save()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let oldCivilDay = try XCTUnwrap(
            try? HistoricalTimestamp.captured(
                instant: oldDay,
                timeZoneIdentifier: "UTC"
            ).localDate
        )
        let records = try await AppReadActor(modelContainer: container).labRecords(
            on: oldCivilDay,
            fallbackTimeZone: calendar.timeZone
        )

        XCTAssertEqual(records.first?.itemCode, "E2")
        XCTAssertEqual(records.first?.rawValue, "88")
    }
}

private func assertSendable<T: Sendable>(_: T) {}
