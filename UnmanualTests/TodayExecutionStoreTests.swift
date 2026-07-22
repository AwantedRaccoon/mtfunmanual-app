import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class TodayExecutionStoreTests: XCTestCase {
    func testV4BackfillCreatesNoExecutionFactsAndKeepsReminderIntentDisabled() throws {
        let container = try AppModelContainerFactory.makeInMemoryTodayContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")

        let outcome = try TodayExecutionBackfill.run(in: container)
        let context = ModelContext(container)

        XCTAssertTrue(outcome.didComplete)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdministrationEventRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReminderOverrideRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReminderPreferenceRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceiptRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceiptLedgerRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotificationCoverageRecord>()), 1)
    }

    func testReminderPreferenceIsIdempotentAndRejectsOperationConflict() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let operationID = UUID()
        let command = SetReminderPreferenceCommand(
            operationID: operationID,
            scheduleRuleID: fixture.occurrence.scheduleRuleID,
            expectedRuleRevision: fixture.occurrence.scheduleRevision,
            isEnabled: true,
            defaultSnoozeMinutes: 10,
            committedAt: fixture.occurrence.instant.addingTimeInterval(-600)
        )

        let first = try await writer.setReminderPreference(command)
        let replay = try await writer.setReminderPreference(command)

        XCTAssertTrue(first.didApply)
        XCTAssertFalse(replay.didApply)
        let context = ModelContext(fixture.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReminderPreferenceRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceiptRecord>()), 1)

        do {
            _ = try await writer.setReminderPreference(
                SetReminderPreferenceCommand(
                    operationID: operationID,
                    scheduleRuleID: fixture.occurrence.scheduleRuleID,
                    expectedRuleRevision: fixture.occurrence.scheduleRevision,
                    isEnabled: false,
                    defaultSnoozeMinutes: 10,
                    committedAt: fixture.occurrence.instant.addingTimeInterval(-600)
                )
            )
            XCTFail("同 operation ID 的不同偏好命令必须失败")
        } catch let error as TodayExecutionWriteFailure {
            XCTAssertEqual(error, .operationConflict)
        }
    }

    func testReceiptLedgerAndFactRevisionRejectReceiptTamperingAndDeletion() async throws {
        for mutation in ["tamper", "delete"] {
            let fixture = try makeFixture()
            let writer = AppWriteActor(modelContainer: fixture.container)
            let actual = try HistoricalTimestamp.captured(
                instant: fixture.occurrence.instant,
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .userEntered
            )
            _ = try await writer.commitAdministration(
                CommitAdministrationCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    occurrence: fixture.occurrence,
                    expectedLeafEventID: nil,
                    status: .taken,
                    actualTimestamp: actual
                )
            )
            let context = ModelContext(fixture.container)
            let receipt = try XCTUnwrap(
                context.fetch(FetchDescriptor<OperationReceiptRecord>()).first
            )
            if mutation == "tamper" {
                receipt.commandDigest = String(repeating: "a", count: 64)
            } else {
                context.delete(receipt)
            }
            try context.save()

            XCTAssertThrowsError(
                try TodayExecutionRelationshipValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }
    }

    func testRelationshipValidatorRejectsSecondReceiptPointingAtSameAdministrationEvent() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let actual = try HistoricalTimestamp.captured(
            instant: fixture.occurrence.instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let result = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: nil,
                status: .taken,
                actualTimestamp: actual
            )
        )
        let context = ModelContext(fixture.container)
        context.insert(
            OperationReceiptRecord(
                operationID: UUID(),
                commandDigest: String(repeating: "b", count: 64),
                resultRecordType: "AdministrationEventRecord",
                resultRecordID: result.eventID,
                committedAt: fixture.occurrence.instant
            )
        )
        let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
        let ledger = try XCTUnwrap(
            context.fetch(FetchDescriptor<OperationReceiptLedgerRecord>()).first
        )
        ledger.receiptCount = receipts.count
        ledger.receiptSetDigest = TodayExecutionDigestV1.receiptSetDigest(receipts)
        ledger.updatedAt = fixture.occurrence.instant
        try context.save()

        XCTAssertThrowsError(
            try TodayExecutionRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testRelationshipValidatorRejectsSecondReceiptPointingAtSameReminderOverride() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let result = try await writer.applyReminderOverride(
            ApplyReminderOverrideCommand(
                operationID: UUID(),
                overrideID: UUID(),
                occurrence: fixture.occurrence,
                expectedOverrideID: nil,
                fireAt: fixture.occurrence.instant.addingTimeInterval(900),
                committedAt: fixture.occurrence.instant.addingTimeInterval(-600)
            )
        )
        let context = ModelContext(fixture.container)
        context.insert(
            OperationReceiptRecord(
                operationID: UUID(),
                commandDigest: String(repeating: "c", count: 64),
                resultRecordType: "ReminderOverrideRecord",
                resultRecordID: result.overrideID,
                committedAt: fixture.occurrence.instant
            )
        )
        let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
        let ledger = try XCTUnwrap(
            context.fetch(FetchDescriptor<OperationReceiptLedgerRecord>()).first
        )
        ledger.receiptCount = receipts.count
        ledger.receiptSetDigest = TodayExecutionDigestV1.receiptSetDigest(receipts)
        ledger.updatedAt = fixture.occurrence.instant
        try context.save()

        XCTAssertThrowsError(
            try TodayExecutionRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testNextSealedVersionImplicitlyEndsOldExecutionReadAndWrite() async throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let newRegimen = RegimenPlanVersionRecord(
            code: "R-02",
            title: "新方案",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 7, day: 23),
            editState: .sealed
        )
        let newItem = RegimenItemRecord(
            regimenVersionID: newRegimen.id,
            sortOrder: 0,
            displayName: "新方案项目",
            doseOriginal: "原始用量",
            unitOriginal: "原始单位"
        )
        let newRule = ScheduleRuleRecord(
            regimenItemID: newItem.id,
            kind: .dailyTimes,
            anchorDate: try CivilDateFact(year: 2026, month: 7, day: 23),
            localTimes: "08:00",
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC"
        )
        context.insert(newRegimen)
        context.insert(newItem)
        context.insert(newRule)
        try context.save()

        let snapshot = try await AppReadActor(
            modelContainer: fixture.container
        ).todayExecutionSnapshot(
            now: ISO8601DateFormatter().date(from: "2026-07-23T12:00:00Z")!,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.items.map(\.occurrence.regimenVersionID), [newRegimen.id])

        let oldRule = try XCTUnwrap(
            context.fetch(FetchDescriptor<ScheduleRuleRecord>()).first {
                $0.id == fixture.occurrence.scheduleRuleID
            }
        )
        let oldOccurrence = try XCTUnwrap(
            ScheduleOccurrenceResolver.occurrences(
                rules: [
                    ScheduleRuleSpec(
                        id: oldRule.id,
                        regimenVersionID: fixture.occurrence.regimenVersionID,
                        regimenItemID: fixture.occurrence.regimenItemID,
                        displayName: fixture.occurrence.displayName,
                        kind: .dailyTimes,
                        anchorDate: try CivilDateFact(year: 2026, month: 7, day: 1),
                        endDate: nil,
                        localTimes: "08:00",
                        weekdays: "",
                        intervalDays: nil,
                        timeZoneBehavior: .fixedZone,
                        fixedTimeZoneIdentifier: "UTC",
                        revision: 1
                    )
                ],
                interval: DateInterval(
                    start: ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z")!,
                    end: ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z")!
                ),
                displayTimeZoneIdentifier: "UTC"
            ).occurrences.first
        )
        let actual = try HistoricalTimestamp.captured(
            instant: oldOccurrence.instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        do {
            _ = try await AppWriteActor(modelContainer: fixture.container).commitAdministration(
                CommitAdministrationCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    occurrence: oldOccurrence,
                    expectedLeafEventID: nil,
                    status: .taken,
                    actualTimestamp: actual
                )
            )
            XCTFail("旧方案在下一封存版本开始日必须停止")
        } catch let error as TodayExecutionWriteFailure {
            XCTAssertEqual(error, .invalidOccurrence)
        }
    }

    func testCoverageWriteRejectsImpossibleConfirmedCount() async throws {
        let fixture = try makeFixture()
        do {
            try await AppWriteActor(modelContainer: fixture.container)
                .updateNotificationCoverage(
                    LocalReminderReconciliationObservation(
                        status: .scheduledForWindow,
                        scheduledThrough: fixture.occurrence.instant,
                        desiredCount: 1,
                        confirmedPendingCount: 2,
                        lastErrorCode: nil,
                        observedAt: fixture.occurrence.instant
                    )
                )
            XCTFail("confirmed 不得超过 desired")
        } catch let error as AppDataFailure {
            XCTAssertEqual(error, .corruptionSuspected)
        }
    }

    func testAdministrationCommitIsAppendOnlyIdempotentAndRejectsOperationConflict() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let operationID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let eventID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let actual = try HistoricalTimestamp.captured(
            instant: fixture.occurrence.instant.addingTimeInterval(180),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let command = CommitAdministrationCommand(
            operationID: operationID,
            eventID: eventID,
            occurrence: fixture.occurrence,
            expectedLeafEventID: nil,
            status: .taken,
            actualTimestamp: actual,
            note: "按计划",
            committedAt: actual.instant
        )

        let first = try await writer.commitAdministration(command)
        let replay = try await writer.commitAdministration(command)

        XCTAssertTrue(first.didCreate)
        XCTAssertFalse(replay.didCreate)
        XCTAssertEqual(first.eventID, eventID)
        let context = ModelContext(fixture.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdministrationEventRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceiptRecord>()), 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<HistoricalTimeRecord>()).filter {
                $0.sourceRecordType == "AdministrationEventRecord"
            }.count,
            1
        )

        let conflict = CommitAdministrationCommand(
            operationID: operationID,
            eventID: UUID(),
            occurrence: fixture.occurrence,
            expectedLeafEventID: nil,
            status: .skipped,
            actualTimestamp: actual,
            committedAt: actual.instant
        )
        do {
            _ = try await writer.commitAdministration(conflict)
            XCTFail("同 operation ID 的不同命令必须失败")
        } catch let error as TodayExecutionWriteFailure {
            XCTAssertEqual(error, .operationConflict)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdministrationEventRecord>()), 1)
    }

    func testAdministrationCommitAllowsSafeSlotsBesideAndAfterDSTGap() async throws {
        let fixtures = try [
            makeDSTFixture(
                localTimes: "01:30,02:30",
                targetInstant: "2026-03-08T01:30:00-06:00",
                targetHour: 1,
                targetDay: 8
            ),
            makeDSTFixture(
                localTimes: "02:30",
                targetInstant: "2026-03-09T02:30:00-05:00",
                targetHour: 2,
                targetDay: 9
            )
        ]

        for fixture in fixtures {
            let actual = try HistoricalTimestamp.captured(
                instant: fixture.occurrence.instant,
                timeZoneIdentifier: "America/Chicago",
                precision: .minute,
                provenance: .userEntered
            )
            let result = try await AppWriteActor(
                modelContainer: fixture.container
            ).commitAdministration(
                CommitAdministrationCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    occurrence: fixture.occurrence,
                    expectedLeafEventID: nil,
                    status: .taken,
                    actualTimestamp: actual
                )
            )
            XCTAssertTrue(result.didCreate)
        }
    }

    func testActualTimeAssociationUsesItsLocalDateAcrossPlanBoundaryAndMissingGap() async throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let oldRegimen = try XCTUnwrap(
            context.fetch(FetchDescriptor<RegimenPlanVersionRecord>()).first {
                $0.id == fixture.occurrence.regimenVersionID
            }
        )
        let nextRegimen = RegimenPlanVersionRecord(
            code: "R-02",
            title: "下一方案",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 7, day: 23),
            previousVersionID: oldRegimen.id,
            editState: .sealed
        )
        context.insert(nextRegimen)
        try context.save()

        let writer = AppWriteActor(modelContainer: fixture.container)
        let nextPlanTimestamp = try HistoricalTimestamp.captured(
            instant: ISO8601DateFormatter().date(from: "2026-07-23T09:00:00Z")!,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let first = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: nil,
                status: .taken,
                actualTimestamp: nextPlanTimestamp
            )
        )

        let nextHistorical = try XCTUnwrap(
            context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first {
                $0.sourceRecordType == "AdministrationEventRecord"
                    && $0.sourceRecordID == first.eventID
            }
        )
        XCTAssertEqual(nextHistorical.resolvedRegimenVersionID, nextRegimen.id)
        XCTAssertEqual(nextHistorical.associationStateRawValue, HistoricalAssociationState.resolved.rawValue)

        let missingTimestamp = try HistoricalTimestamp.captured(
            instant: ISO8601DateFormatter().date(from: "2026-06-30T09:00:00Z")!,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let correction = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: first.eventID,
                status: .taken,
                actualTimestamp: missingTimestamp
            )
        )
        let missingHistorical = try XCTUnwrap(
            context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first {
                $0.sourceRecordType == "AdministrationEventRecord"
                    && $0.sourceRecordID == correction.eventID
            }
        )
        XCTAssertNil(missingHistorical.resolvedRegimenVersionID)
        XCTAssertEqual(missingHistorical.associationStateRawValue, HistoricalAssociationState.missing.rawValue)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<MigrationIssue>()).contains {
                $0.recordType == "AdministrationEventRecord"
                    && $0.recordID == correction.eventID
                    && $0.kind == .missingCanonicalRegimenAssociation
            }
        )

        let reopened = try await AppReadActor(
            modelContainer: fixture.container
        ).coreRegimenOverview(asOf: try CivilDateFact(year: 2026, month: 7, day: 23))
        XCTAssertGreaterThanOrEqual(reopened.reviewIssueCount, 1)
        XCTAssertNoThrow(
            try TodayExecutionRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testActualTimeAssociationCommitKeepsAmbiguousTimelineUnresolvedAndVisibleAfterReopen() async throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let original = try XCTUnwrap(
            context.fetch(FetchDescriptor<RegimenPlanVersionRecord>()).first {
                $0.id == fixture.occurrence.regimenVersionID
            }
        )
        for index in 2...3 {
            context.insert(
                RegimenPlanVersionRecord(
                    code: "R-0\(index)",
                    title: "冲突方案 \(index)",
                    effectiveStartDate: try CivilDateFact(year: 2026, month: 7, day: 23),
                    previousVersionID: original.id,
                    editState: .sealed
                )
            )
        }
        try context.save()
        let timestamp = try HistoricalTimestamp.captured(
            instant: ISO8601DateFormatter().date(from: "2026-07-24T09:00:00Z")!,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )

        let result = try await AppWriteActor(
            modelContainer: fixture.container
        ).commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: nil,
                status: .taken,
                actualTimestamp: timestamp
            )
        )
        let historical = try XCTUnwrap(
            context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first {
                $0.sourceRecordType == "AdministrationEventRecord"
                    && $0.sourceRecordID == result.eventID
            }
        )

        XCTAssertNil(historical.resolvedRegimenVersionID)
        XCTAssertEqual(
            historical.associationStateRawValue,
            HistoricalAssociationState.ambiguous.rawValue
        )
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<MigrationIssue>()).contains {
                $0.recordType == "AdministrationEventRecord"
                    && $0.recordID == result.eventID
                    && $0.kind == .ambiguousCanonicalRegimenAssociation
            }
        )
        let reopened = try await AppReadActor(
            modelContainer: fixture.container
        ).coreRegimenOverview(asOf: try CivilDateFact(year: 2026, month: 7, day: 24))
        XCTAssertGreaterThanOrEqual(reopened.reviewIssueCount, 1)
    }

    func testRelationshipValidatorRejectsHistoricalAssociationTampering() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let actual = try HistoricalTimestamp.captured(
            instant: fixture.occurrence.instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let result = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: nil,
                status: .taken,
                actualTimestamp: actual
            )
        )
        let context = ModelContext(fixture.container)
        let historical = try XCTUnwrap(
            context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first {
                $0.sourceRecordType == "AdministrationEventRecord"
                    && $0.sourceRecordID == result.eventID
            }
        )
        historical.resolvedRegimenVersionID = nil
        historical.associationStateRawValue = HistoricalAssociationState.missing.rawValue
        try context.save()

        XCTAssertThrowsError(
            try TodayExecutionRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testCorrectionRequiresCurrentLeafAndKeepsOneEffectiveLeaf() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let actual = try HistoricalTimestamp.captured(
            instant: fixture.occurrence.instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let first = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: nil,
                status: .taken,
                actualTimestamp: actual
            )
        )
        let correction = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: first.eventID,
                status: .skipped,
                actualTimestamp: actual
            )
        )

        let context = ModelContext(fixture.container)
        let events = try context.fetch(FetchDescriptor<AdministrationEventRecord>())
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first(where: { $0.id == correction.eventID })?.supersedesEventID, first.eventID)

        do {
            _ = try await writer.commitAdministration(
                CommitAdministrationCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    occurrence: fixture.occurrence,
                    expectedLeafEventID: first.eventID,
                    status: .taken,
                    actualTimestamp: actual
                )
            )
            XCTFail("过期 leaf 必须失败")
        } catch let error as TodayExecutionWriteFailure {
            XCTAssertEqual(error, .staleLeaf)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdministrationEventRecord>()), 2)
    }

    func testReminderPreferenceAndSnoozeDoNotCreateAdministrationFact() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let now = fixture.occurrence.instant.addingTimeInterval(-600)

        _ = try await writer.setReminderPreference(
            SetReminderPreferenceCommand(
                operationID: UUID(),
                scheduleRuleID: fixture.occurrence.scheduleRuleID,
                expectedRuleRevision: fixture.occurrence.scheduleRevision,
                isEnabled: true,
                defaultSnoozeMinutes: 15,
                committedAt: now
            )
        )
        let snoozeCommand = ApplyReminderOverrideCommand(
            operationID: UUID(),
            overrideID: UUID(),
            occurrence: fixture.occurrence,
            expectedOverrideID: nil,
            fireAt: fixture.occurrence.instant.addingTimeInterval(900),
            committedAt: now
        )
        let first = try await writer.applyReminderOverride(snoozeCommand)
        let replay = try await writer.applyReminderOverride(snoozeCommand)

        XCTAssertTrue(first.didCreate)
        XCTAssertFalse(replay.didCreate)
        let context = ModelContext(fixture.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdministrationEventRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReminderOverrideRecord>()), 1)
        let preference = try XCTUnwrap(
            context.fetch(FetchDescriptor<ReminderPreferenceRecord>()).first
        )
        XCTAssertTrue(preference.isEnabled)
        XCTAssertEqual(preference.defaultSnoozeMinutes, 15)
    }

    func testTodaySnapshotCombinesOccurrenceEffectiveLeafSnoozeAndCoverage() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let actual = try HistoricalTimestamp.captured(
            instant: fixture.occurrence.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let committed = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: UUID(),
                occurrence: fixture.occurrence,
                expectedLeafEventID: nil,
                status: .taken,
                actualTimestamp: actual
            )
        )

        let snapshot = try await AppReadActor(
            modelContainer: fixture.container
        ).todayExecutionSnapshot(
            now: ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z")!,
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.occurrence.key, fixture.occurrence.key)
        XCTAssertEqual(snapshot.items.first?.state, .taken)
        XCTAssertEqual(snapshot.items.first?.effectiveEventID, committed.eventID)
        XCTAssertEqual(snapshot.items.first?.actualTimestamp, actual)
        XCTAssertEqual(snapshot.coverage.status, .disabledByUser)
        XCTAssertTrue(snapshot.reviewIssues.isEmpty)
    }

    func testReminderPlanningUsesFourteenLocalDaysAndCoverageIsAReplaceableProjection() async throws {
        let fixture = try makeFixture()
        let reader = AppReadActor(modelContainer: fixture.container)
        let now = ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z")!

        _ = try await AppWriteActor(modelContainer: fixture.container).setReminderPreference(
            SetReminderPreferenceCommand(
                operationID: UUID(),
                scheduleRuleID: fixture.occurrence.scheduleRuleID,
                expectedRuleRevision: fixture.occurrence.scheduleRevision,
                isEnabled: true,
                defaultSnoozeMinutes: 10,
                committedAt: now
            )
        )
        let candidates = try await reader.reminderPlanningCandidates(
            now: now,
            displayTimeZoneIdentifier: "UTC",
            horizonLocalDays: 14
        )

        XCTAssertEqual(candidates.count, 13)
        XCTAssertTrue(candidates.allSatisfy(\.isEnabled))
        XCTAssertTrue(candidates.allSatisfy { $0.state == .unrecorded })

        let observation = LocalReminderReconciliationObservation(
            status: .scheduledForWindow,
            scheduledThrough: candidates.last?.occurrence.instant,
            desiredCount: candidates.count,
            confirmedPendingCount: candidates.count,
            lastErrorCode: nil,
            observedAt: now
        )
        try await AppWriteActor(modelContainer: fixture.container)
            .updateNotificationCoverage(observation)

        let snapshot = try await reader.todayExecutionSnapshot(
            now: now,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.coverage.status, .scheduledForWindow)
        XCTAssertEqual(snapshot.coverage.desiredCount, 13)
        XCTAssertEqual(snapshot.coverage.confirmedPendingCount, 13)
    }

    func testReminderPlanningKeepsPastOccurrenceWithFutureSnoozeAcrossMidnight() async throws {
        let fixture = try makeFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-07-22T23:50:00Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-07-23T00:05:00Z")!
        let snoozedUntil = ISO8601DateFormatter().date(from: "2026-07-23T00:10:00Z")!
        _ = try await writer.setReminderPreference(
            SetReminderPreferenceCommand(
                operationID: UUID(),
                scheduleRuleID: fixture.occurrence.scheduleRuleID,
                expectedRuleRevision: fixture.occurrence.scheduleRevision,
                isEnabled: true,
                defaultSnoozeMinutes: 20,
                committedAt: beforeMidnight
            )
        )
        _ = try await writer.applyReminderOverride(
            ApplyReminderOverrideCommand(
                operationID: UUID(),
                overrideID: UUID(),
                occurrence: fixture.occurrence,
                expectedOverrideID: nil,
                fireAt: snoozedUntil,
                committedAt: beforeMidnight
            )
        )

        let planning = try await AppReadActor(
            modelContainer: fixture.container
        ).reminderPlanningSnapshot(
            now: afterMidnight,
            displayTimeZoneIdentifier: "UTC",
            horizonLocalDays: 14
        )
        let snoozed = try XCTUnwrap(
            planning.candidates.first { $0.occurrence.key == fixture.occurrence.key }
        )
        XCTAssertEqual(snoozed.snoozedUntil, snoozedUntil)

        let plan = LocalReminderPlanner.plan(
            candidates: planning.candidates,
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: afterMidnight,
            hasEnabledIntent: planning.hasEnabledIntent
        )
        XCTAssertTrue(plan.requests.contains { request in
            request.occurrenceKey == fixture.occurrence.key
                && request.fireAt == snoozedUntil
        })
    }

    private struct Fixture {
        let container: ModelContainer
        let occurrence: PlannedOccurrence
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppModelContainerFactory.makeInMemoryTodayContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        _ = try TodayExecutionBackfill.run(in: container)
        let context = ModelContext(container)
        let regimen = RegimenPlanVersionRecord(
            code: "R-01",
            title: "当前方案",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 7, day: 1),
            editState: .sealed
        )
        let item = RegimenItemRecord(
            regimenVersionID: regimen.id,
            sortOrder: 0,
            displayName: "项目原文",
            doseOriginal: "原始用量",
            unitOriginal: "原始单位"
        )
        let rule = ScheduleRuleRecord(
            regimenItemID: item.id,
            kind: .dailyTimes,
            anchorDate: try CivilDateFact(year: 2026, month: 7, day: 1),
            localTimes: "08:00",
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC"
        )
        context.insert(regimen)
        context.insert(item)
        context.insert(rule)
        try context.save()
        let resolution = try ScheduleOccurrenceResolver.occurrences(
            rules: [
                ScheduleRuleSpec(
                    id: rule.id,
                    regimenVersionID: regimen.id,
                    regimenItemID: item.id,
                    displayName: item.displayName,
                    kind: .dailyTimes,
                    anchorDate: try CivilDateFact(year: 2026, month: 7, day: 1),
                    endDate: nil,
                    localTimes: "08:00",
                    weekdays: "",
                    intervalDays: nil,
                    timeZoneBehavior: .fixedZone,
                    fixedTimeZoneIdentifier: "UTC",
                    revision: 1
                )
            ],
            interval: DateInterval(
                start: ISO8601DateFormatter().date(from: "2026-07-22T00:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z")!
            ),
            displayTimeZoneIdentifier: "UTC"
        )
        return Fixture(container: container, occurrence: try XCTUnwrap(resolution.occurrences.first))
    }

    private func makeDSTFixture(
        localTimes: String,
        targetInstant: String,
        targetHour: Int,
        targetDay: Int
    ) throws -> Fixture {
        let container = try AppModelContainerFactory.makeInMemoryTodayContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "America/Chicago"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        let context = ModelContext(container)
        let regimen = RegimenPlanVersionRecord(
            code: "R-DST",
            title: "DST 测试方案",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 3, day: 1),
            editState: .sealed
        )
        let item = RegimenItemRecord(
            regimenVersionID: regimen.id,
            sortOrder: 0,
            displayName: "DST 测试项目",
            doseOriginal: "原始用量",
            unitOriginal: "原始单位"
        )
        let rule = ScheduleRuleRecord(
            regimenItemID: item.id,
            kind: .dailyTimes,
            anchorDate: try CivilDateFact(year: 2026, month: 3, day: 1),
            localTimes: localTimes,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "America/Chicago"
        )
        context.insert(regimen)
        context.insert(item)
        context.insert(rule)
        try context.save()

        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: targetInstant))
        let resolution = try ScheduleOccurrenceResolver.occurrences(
            rules: [
                ScheduleRuleSpec(
                    id: rule.id,
                    regimenVersionID: regimen.id,
                    regimenItemID: item.id,
                    displayName: item.displayName,
                    kind: .dailyTimes,
                    anchorDate: try CivilDateFact(year: 2026, month: 3, day: 1),
                    endDate: nil,
                    localTimes: localTimes,
                    weekdays: "",
                    intervalDays: nil,
                    timeZoneBehavior: .fixedZone,
                    fixedTimeZoneIdentifier: "America/Chicago",
                    revision: 1
                )
            ],
            interval: DateInterval(
                start: instant.addingTimeInterval(-10_800),
                end: instant.addingTimeInterval(10_800)
            ),
            displayTimeZoneIdentifier: "America/Chicago"
        )
        let occurrence = try XCTUnwrap(
            resolution.occurrences.first {
                $0.localDate == (try? CivilDateFact(year: 2026, month: 3, day: targetDay))
                    && $0.localTime.hour == targetHour
                    && $0.localTime.minute == 30
            }
        )
        return Fixture(container: container, occurrence: occurrence)
    }
}
