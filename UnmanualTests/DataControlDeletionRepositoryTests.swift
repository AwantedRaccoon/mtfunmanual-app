import Foundation
import SwiftData
import XCTest
@testable import Unmanual

final class DataControlDeletionRepositoryTests: XCTestCase {
    private let generationID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!

    func testPlansExactClosuresForAllFiveTargets() throws {
        let fixture = try makeComprehensiveFixture()
        let context = ModelContext(fixture.container)
        let pending = [
            DataControlPendingNotificationEntry(
                namespace: .execution,
                identifier: "unmanual.exec.v1.fixture"
            ),
            DataControlPendingNotificationEntry(
                namespace: .countdown,
                identifier: "unmanual.countdown.v1.fixture"
            )
        ]

        let journey = try plan(
            .journeyEntry(fixture.journeyID),
            context: context
        )
        assertSourceTypes(
            journey,
            equal: ["HistoricalTimeRecord", "JourneyEntry"]
        )
        XCTAssertEqual(journey.impact.affectedReminderCount, 0)

        let occurrence = try plan(
            .administrationOccurrence(fixture.occurrence),
            notifications: pending,
            context: context
        )
        assertSourceTypes(
            occurrence,
            equal: [
                "AdministrationEventRecord",
                "HistoricalTimeRecord",
                "RegimenItemRecord",
                "RegimenPlanVersionRecord",
                "ReminderOverrideRecord",
                "ScheduleRuleRecord"
            ]
        )
        XCTAssertFalse(
            sourceTypes(occurrence).contains(
                "ReminderPreferenceRecord"
            )
        )
        XCTAssertEqual(occurrence.impact.affectedReminderCount, 2)

        let draft = try plan(
            .draftRegimenVersion(fixture.draftVersionID),
            notifications: pending,
            context: context
        )
        assertSourceTypes(
            draft,
            equal: [
                "RegimenItemRecord",
                "RegimenPlanVersionRecord",
                "ReminderPreferenceRecord",
                "ScheduleRuleRecord"
            ]
        )

        let sealed = try plan(
            .sealedRegimenVersion(fixture.sealedVersionID),
            notifications: pending,
            context: context
        )
        assertSourceTypes(
            sealed,
            equal: [
                "AdministrationEventRecord",
                "HistoricalTimeRecord",
                "RegimenItemRecord",
                "RegimenPlanVersionRecord",
                "ReminderOverrideRecord",
                "ReminderPreferenceRecord",
                "ScheduleRuleRecord"
            ]
        )

        let hrt = try plan(
            .hrtJourney,
            context: context
        )
        assertSourceTypes(
            hrt,
            equal: [
                "HRTProfile",
                "HrtJourneyProfileRecord",
                "HrtPeriodRecord"
            ]
        )
        XCTAssertEqual(hrt.impact.affectedReminderCount, 0)

        for value in [journey, occurrence, draft, sealed, hrt] {
            XCTAssertEqual(
                value.impactDigest,
                try DataControlDigestV1.impact(value.impact)
            )
            XCTAssertEqual(
                DataControlTargetSnapshotManifest.encode(
                    try XCTUnwrap(
                        DataControlTargetSnapshotManifest.decode(
                            value.impact.targetSnapshotManifest
                        )
                    )
                ),
                value.impact.targetSnapshotManifest
            )
        }
    }

    func testPlannerRequiresExactAttachmentOperationMapping() throws {
        let fixture = try makeComprehensiveFixture()
        let context = ModelContext(fixture.container)
        let attachment = try insertJourneyAttachment(
            ownerID: fixture.journeyID,
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try plan(
                .journeyEntry(fixture.journeyID),
                context: context
            )
        ) {
            XCTAssertEqual(
                $0 as? DataControlDeletionFailure,
                .attachmentOperationIDsRequired([attachment.id])
            )
        }

        let deletionOperationID = UUID()
        let value = try plan(
            .journeyEntry(fixture.journeyID),
            attachmentOperations: [
                attachment.id: deletionOperationID
            ],
            context: context
        )
        let entries = try XCTUnwrap(
            DataControlAttachmentManifest.decode(
                value.impact.attachmentManifest
            )
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].attachmentID, attachment.id)
        XCTAssertEqual(
            entries[0].deletionOperationID,
            deletionOperationID
        )
        XCTAssertEqual(
            value.impact.retainedRecordCount,
            try XCTUnwrap(
                DataControlDeletionRepository.retainedRecordCount(
                    sourceCount: 2,
                    associatedReceiptCount: 0,
                    deletedAttachmentCount: 1
                )
            )
        )
    }

    func testWriterCommitsTombstoneAndOverlayInOneRevision()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let context = ModelContext(fixture.container)
        let value = try plan(
            .journeyEntry(fixture.journeyID),
            context: context
        )
        let timestamp = try deletionTimestamp(1_800_200_000)
        let command = value.command(
            operationID: UUID(),
            timestamp: timestamp
        )
        let writer = AppWriteActor(
            modelContainer: fixture.container
        )

        let result = try await writer.commitDataControlDeletion(
            impact: value.impact,
            command: command,
            activeGenerationID: generationID
        )

        XCTAssertTrue(result.didApply)
        XCTAssertEqual(result.tombstoneID, command.operationID)
        let verification = ModelContext(fixture.container)
        let tombstone = try XCTUnwrap(
            verification.fetch(
                FetchDescriptor<
                    DataControlDeletionTombstoneRecord
                >()
            ).first
        )
        XCTAssertEqual(tombstone.id, command.operationID)
        XCTAssertEqual(
            tombstone.sourceNextLocalRevision,
            value.impact.expectedNextLocalRevision
        )
        let revision = try XCTUnwrap(
            verification.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate {
                        $0.recordType
                            == "DataControlDeletionTombstoneRecord"
                    }
                )
            ).first
        )
        XCTAssertEqual(
            revision.localRevision,
            value.impact.expectedNextLocalRevision
        )
        let metadata = try XCTUnwrap(
            verification.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        XCTAssertEqual(
            metadata.nextLocalRevision,
            value.impact.expectedNextLocalRevision + 1
        )
        XCTAssertNoThrow(
            try DataControlRelationshipValidator.validate(
                in: verification,
                failure: .corruptionSuspected
            )
        )
        let overlay = try await writer.dataControlTerminalOverlay()
        XCTAssertTrue(
            overlay.journeyEntryIDs.contains(fixture.journeyID)
        )
    }

    func testWriterSameOperationIsIdempotent() async throws {
        let fixture = try makeComprehensiveFixture()
        let value = try plan(
            .journeyEntry(fixture.journeyID),
            context: ModelContext(fixture.container)
        )
        let command = value.command(
            operationID: UUID(),
            timestamp: try deletionTimestamp(1_800_200_010)
        )
        let writer = AppWriteActor(
            modelContainer: fixture.container
        )
        let first = try await writer.commitDataControlDeletion(
            impact: value.impact,
            command: command,
            activeGenerationID: generationID
        )
        let second = try await writer.commitDataControlDeletion(
            impact: value.impact,
            command: command,
            activeGenerationID: generationID
        )

        XCTAssertTrue(first.didApply)
        XCTAssertFalse(second.didApply)
        XCTAssertEqual(first.tombstoneID, second.tombstoneID)
        let context = ModelContext(fixture.container)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<
                    DataControlDeletionTombstoneRecord
                >()
            ),
            1
        )
    }

    func testRelationshipValidationFailureRollsBackTombstoneAndAttachmentTerminal()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let context = ModelContext(fixture.container)
        let attachment = try insertJourneyAttachment(
            ownerID: fixture.journeyID,
            in: context
        )
        try context.save()
        let attachmentDeletionOperationID = UUID()
        let nextRevisionBefore = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        ).nextLocalRevision
        let revisionsBefore =
            try recordRevisionSnapshots(in: context)
        let receiptsBefore =
            try operationReceiptSnapshots(in: context)
        let ledgersBefore =
            try operationReceiptLedgerSnapshots(in: context)
        let plan = try plan(
            .journeyEntry(fixture.journeyID),
            attachmentOperations: [
                attachment.id:
                    attachmentDeletionOperationID
            ],
            context: context
        )
        let operationID = UUID()

        do {
            _ = try await AppWriteActor(
                modelContainer: fixture.container
            ).commitDataControlDeletion(
                impact: plan.impact,
                command: plan.command(
                    operationID: operationID,
                    timestamp: try deletionTimestamp(
                        1_800_200_011
                    )
                ),
                activeGenerationID: generationID,
                failureInjection:
                    .beforeRelationshipValidation
            )
            XCTFail(
                "in-transaction validation failure must abort"
            )
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .corruptionSuspected
            )
        }

        let verification = ModelContext(
            fixture.container
        )
        let attachmentID = attachment.id
        XCTAssertEqual(
            try verification.fetchCount(
                FetchDescriptor<
                    DataControlDeletionTombstoneRecord
                >()
            ),
            0
        )
        let persistedAttachment = try XCTUnwrap(
            verification.fetch(
                FetchDescriptor<AttachmentRecord>(
                    predicate: #Predicate {
                        $0.id == attachmentID
                    }
                )
            ).first
        )
        XCTAssertNil(persistedAttachment.deletedAt)
        XCTAssertNil(
            persistedAttachment.deleteOperationID
        )
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision,
            nextRevisionBefore
        )
        XCTAssertEqual(
            try recordRevisionSnapshots(
                in: verification
            ),
            revisionsBefore
        )
        XCTAssertEqual(
            try operationReceiptSnapshots(
                in: verification
            ),
            receiptsBefore
        )
        XCTAssertEqual(
            try operationReceiptLedgerSnapshots(
                in: verification
            ),
            ledgersBefore
        )
        XCTAssertFalse(
            try verification.fetch(
                FetchDescriptor<
                    OperationReceiptRecord
                >()
            ).contains {
                $0.operationID == operationID
            }
        )
        XCTAssertFalse(
            try verification.fetch(
                FetchDescriptor<
                    OperationReceiptRecord
                >()
            ).contains {
                $0.operationID
                    == attachmentDeletionOperationID
            }
        )
    }

    func testWriterRejectsDifferentOperationForTerminalTarget()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let value = try plan(
            .journeyEntry(fixture.journeyID),
            context: ModelContext(fixture.container)
        )
        let writer = AppWriteActor(
            modelContainer: fixture.container
        )
        let first = value.command(
            operationID: UUID(),
            timestamp: try deletionTimestamp(1_800_200_020)
        )
        _ = try await writer.commitDataControlDeletion(
            impact: value.impact,
            command: first,
            activeGenerationID: generationID
        )
        let second = value.command(
            operationID: UUID(),
            timestamp: try deletionTimestamp(1_800_200_021)
        )

        do {
            _ = try await writer.commitDataControlDeletion(
                impact: value.impact,
                command: second,
                activeGenerationID: generationID
            )
            XCTFail("terminal target must reject another operation")
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetAlreadyDeleted(
                    existingTombstoneID: first.operationID
                )
            )
        }
    }

    func testWriterRejectsStaleDatasetWatermarkWithZeroWrites()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let context = ModelContext(fixture.container)
        let value = try plan(
            .journeyEntry(fixture.journeyID),
            context: context
        )
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        metadata.nextLocalRevision += 1
        try context.save()
        let writer = AppWriteActor(
            modelContainer: fixture.container
        )

        do {
            _ = try await writer.commitDataControlDeletion(
                impact: value.impact,
                command: value.command(
                    operationID: UUID(),
                    timestamp: try deletionTimestamp(
                        1_800_200_030
                    )
                ),
                activeGenerationID: generationID
            )
            XCTFail("changed watermark must be stale")
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .staleToken
            )
        }
        let verification = ModelContext(fixture.container)
        XCTAssertEqual(
            try verification.fetchCount(
                FetchDescriptor<
                    DataControlDeletionTombstoneRecord
                >()
            ),
            0
        )
    }

    func testRetainedRecordCountFormulaAndOverflow() throws {
        XCTAssertEqual(
            DataControlDeletionRepository.retainedRecordCount(
                sourceCount: 3,
                associatedReceiptCount: 2,
                deletedAttachmentCount: 4
            ),
            38
        )
        XCTAssertEqual(
            DataControlDeletionRepository.retainedRecordCount(
                sourceCount: 0,
                associatedReceiptCount: 0,
                deletedAttachmentCount: 0
            ),
            4
        )
        XCTAssertNil(
            DataControlDeletionRepository.retainedRecordCount(
                sourceCount: Int.max,
                associatedReceiptCount: 0,
                deletedAttachmentCount: 0
            )
        )
        XCTAssertNil(
            DataControlDeletionRepository.retainedRecordCount(
                sourceCount: -1,
                associatedReceiptCount: 0,
                deletedAttachmentCount: 0
            )
        )
    }

    func testDeletionCatalogIncludesHistoricalAdministration()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let reader = AppReadActor(
            modelContainer: fixture.container
        )

        let candidates = try await reader
            .dataControlAdministrationDeletionCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(
            candidates.first?.target.stableKey,
            fixture.occurrence.key
        )
        XCTAssertEqual(
            candidates.first?.displayName,
            "sealed item"
        )
        XCTAssertEqual(
            candidates.first?.timestamp.instant,
            fixture.occurrence.instant
        )
    }

    func testDeletionCatalogUnionsCurrentPlannedOccurrenceWithoutEvent()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let reader = AppDataReader(
            storage: AppReadActor(
                modelContainer: fixture.container
            ),
            dataControlCoordinator:
                AppDataControlCoordinator(
                    generationID: generationID
                )
        )
        let now = try utcDate(
            year: 2026,
            month: 1,
            day: 3,
            hour: 12
        )

        let candidates = try await reader
            .dataControlAdministrationDeletionCandidates(
                now: now,
                displayTimeZoneIdentifier: "UTC"
            )
        let plannedKey = ScheduleOccurrenceResolver
            .occurrenceKey(
                ruleID:
                    fixture.occurrence.scheduleRuleID,
                revision:
                    Int(
                        fixture.occurrence
                            .scheduleRevision
                    ),
                date: try CivilDateFact(
                    year: 2026,
                    month: 1,
                    day: 3
                ),
                time: try HistoricalLocalTime(
                    hour: 9,
                    minute: 0,
                    second: 0
                )
            )

        XCTAssertEqual(
            Set(candidates.map(\.target.stableKey)),
            [fixture.occurrence.key, plannedKey]
        )
        let planned = try XCTUnwrap(
            candidates.first {
                $0.target.stableKey == plannedKey
            }
        )
        XCTAssertEqual(planned.displayName, "sealed item")
        XCTAssertEqual(
            planned.target.occurrenceProjection?
                .localDay,
            3
        )
        let plan = try await AppWriteActor(
            modelContainer: fixture.container
        ).dataControlDeletionPlan(
            DataControlDeletionPlanRequest(
                generationID: generationID,
                target: planned.target
            )
        )
        XCTAssertEqual(
            plan.impact.targetStableKey,
            plannedKey
        )
    }

    func testHistoricalCatalogUsesPlannedSlotWhenActualTimeCrossesDateAndDeduplicatesToday()
        async throws {
        let fixture = try makeComprehensiveFixture(
            actualOffset: 20 * 60 * 60
        )
        let reader = AppDataReader(
            storage: AppReadActor(
                modelContainer: fixture.container
            ),
            dataControlCoordinator:
                AppDataControlCoordinator(
                    generationID: generationID
                )
        )
        let candidates = try await reader
            .dataControlAdministrationDeletionCandidates(
                now: try utcDate(
                    year: 2026,
                    month: 1,
                    day: 4,
                    hour: 12
                ),
                displayTimeZoneIdentifier: "UTC"
            )
        let historical = try XCTUnwrap(
            candidates.first {
                $0.target.stableKey
                    == fixture.occurrence.key
            }
        )
        let projection = try XCTUnwrap(
            historical.target.occurrenceProjection
        )

        XCTAssertEqual(
            projection.instant,
            fixture.occurrence.instant
        )
        XCTAssertEqual(projection.localDay, 2)
        XCTAssertEqual(projection.localHour, 9)
        let expectedFallbackZone = try XCTUnwrap(
            TimeZone.knownTimeZoneIdentifiers
                .sorted()
                .first { identifier in
                    guard let timeZone = TimeZone(
                        identifier: identifier
                    ) else {
                        return false
                    }
                    var calendar = Calendar(
                        identifier: .gregorian
                    )
                    calendar.timeZone = timeZone
                    let components =
                        calendar.dateComponents(
                            [
                                .year,
                                .month,
                                .day,
                                .hour,
                                .minute,
                                .second,
                                .nanosecond
                            ],
                            from:
                                fixture.occurrence
                                    .instant
                        )
                    return components.year == 2026
                        && components.month == 1
                        && components.day == 2
                        && components.hour == 9
                        && components.minute == 0
                        && components.second == 0
                        && (components.nanosecond ?? 0)
                            == 0
                }
        )
        XCTAssertEqual(
            projection
                .resolvedTimeZoneIdentifier,
            expectedFallbackZone
        )
        XCTAssertEqual(
            projection
                .displayTimeZoneIdentifier,
            expectedFallbackZone
        )
        XCTAssertNotEqual(
            expectedFallbackZone,
            historical.timestamp
                .timeZoneIdentifier
        )
        XCTAssertEqual(
            historical.timestamp.instant,
            fixture.occurrence.instant
                .addingTimeInterval(
                    20 * 60 * 60
                )
        )
        XCTAssertNotEqual(
            historical.timestamp.instant,
            projection.instant
        )
        let plan = try await AppWriteActor(
            modelContainer: fixture.container
        ).dataControlDeletionPlan(
            DataControlDeletionPlanRequest(
                generationID: generationID,
                target: historical.target
            )
        )
        XCTAssertEqual(
            plan.impact.targetStableKey,
            fixture.occurrence.key
        )

        let sameDayCandidates = try await reader
            .dataControlAdministrationDeletionCandidates(
                now: try utcDate(
                    year: 2026,
                    month: 1,
                    day: 2,
                    hour: 12
                ),
                displayTimeZoneIdentifier: "UTC"
            )
        XCTAssertEqual(
            sameDayCandidates.filter {
                $0.target.stableKey
                    == fixture.occurrence.key
            }.count,
            1
        )
        XCTAssertEqual(
            sameDayCandidates.first {
                $0.target.stableKey
                    == fixture.occurrence.key
            }?.timestamp.instant,
            fixture.occurrence.instant
                .addingTimeInterval(
                    20 * 60 * 60
                )
        )
    }

    func testHistoricalCatalogUsesFixedZoneForSameScheduleRevision()
        async throws {
        let fixture = try makeComprehensiveFixture(
            scheduleTimeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC"
        )
        let candidates = try await AppReadActor(
            modelContainer: fixture.container
        ).dataControlAdministrationDeletionCandidates()
        let candidate = try XCTUnwrap(
            candidates.first {
                $0.target.stableKey
                    == fixture.occurrence.key
            }
        )
        let projection = try XCTUnwrap(
            candidate.target.occurrenceProjection
        )

        XCTAssertEqual(
            projection
                .resolvedTimeZoneIdentifier,
            "UTC"
        )
        XCTAssertEqual(
            projection
                .displayTimeZoneIdentifier,
            "UTC"
        )
        XCTAssertEqual(
            projection.instant,
            fixture.occurrence.instant
        )
        let plan = try await AppWriteActor(
            modelContainer: fixture.container
        ).dataControlDeletionPlan(
            DataControlDeletionPlanRequest(
                generationID: generationID,
                target: candidate.target
            )
        )
        XCTAssertEqual(
            plan.impact.targetStableKey,
            fixture.occurrence.key
        )
    }

    func testDeletionCatalogRedactsTerminalRegimenItemName()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let context = ModelContext(fixture.container)
        let deletion = try plan(
            .sealedRegimenVersion(
                fixture.sealedVersionID
            ),
            context: context
        )
        _ = try await AppWriteActor(
            modelContainer: fixture.container
        ).commitDataControlDeletion(
            impact: deletion.impact,
            command: deletion.command(
                operationID: UUID(),
                timestamp: try deletionTimestamp(
                    1_800_200_089
                )
            ),
            activeGenerationID: generationID
        )
        let reader = AppDataReader(
            storage: AppReadActor(
                modelContainer: fixture.container
            ),
            dataControlCoordinator:
                AppDataControlCoordinator(
                    generationID: generationID
                )
        )

        let candidates = try await reader
            .dataControlAdministrationDeletionCandidates(
                now: try utcDate(
                    year: 2026,
                    month: 1,
                    day: 3,
                    hour: 12
                ),
                displayTimeZoneIdentifier: "UTC"
            )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(
            candidates.first?.target.stableKey,
            fixture.occurrence.key
        )
        XCTAssertEqual(
            candidates.first?.displayName,
            "已删除方案"
        )
        XCTAssertNotEqual(
            candidates.first?.displayName,
            "sealed item"
        )
    }

    func testDeletedSealedRegimenRedactsAdministrationTitle()
        throws {
        let regimenID = UUID()
        let timestamp = try deletionTimestamp(
            1_800_200_090
        )
        let administration = try XCTUnwrap(
            DataControlTimelineRedaction.apply(
                PersonalTimelineItem(
                    id: UUID(),
                    kind: .administration,
                    title: "sealed item",
                    detail: "已记录",
                    timestamp: timestamp,
                    dateOnly: nil,
                    localDate: timestamp.localDate,
                    regimenVersionID: regimenID
                ),
                terminal: DataControlTerminalProjection(
                    overlay:
                        DataControlTerminalOverlay(
                            journeyEntryIDs: [],
                            administrationOccurrenceKeys:
                                [],
                            draftRegimenVersionIDs: [],
                            sealedRegimenVersionIDs:
                                [regimenID],
                            hidesHrtJourney: false
                        ),
                    administrationEventIDs: []
                )
            )
        )
        XCTAssertEqual(
            administration.title,
            "已删除方案"
        )
        XCTAssertNotEqual(
            administration.title,
            "sealed item"
        )
    }

    func testOrdinaryOnboardingArchiveAndRegimenReadsApplyTerminalOverlay()
        async throws {
        let container = try makeWritableDataControlContainer()
        let writer = AppWriteActor(modelContainer: container)
        let createdAt = Date(
            timeIntervalSince1970: 1_800_190_000
        )
        let startTimestamp = try timestamp(instant: createdAt)
        let regimen = try await createSealedRegimen(
            in: container,
            effectiveStartDate: startTimestamp.localDate,
            committedAt: createdAt
        )
        let draftID = UUID()
        let draftDate = try timestamp(
            instant: createdAt.addingTimeInterval(86_400)
        ).localDate
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: regimen.versionID,
                code: "DRAFT-PRIVATE",
                title: "待删除草稿",
                effectiveStartDate: draftDate,
                changeReason: "不应在删除后出现",
                items: [
                    RegimenItemInput(
                        displayName: "待删除草稿项目"
                    )
                ],
                committedAt:
                    createdAt.addingTimeInterval(3)
            )
        )
        let hrtTimestamp = try timestamp(
            instant: createdAt.addingTimeInterval(10)
        )
        _ = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: hrtTimestamp.localDate,
                timestamp: hrtTimestamp
            )
        )
        let reader = AppDataReader(
            storage: AppReadActor(
                modelContainer: container
            ),
            dataControlCoordinator:
                AppDataControlCoordinator(
                    generationID: generationID
                )
        )
        let before = try await reader.onboardingSnapshot(
            asOf: createdAt.addingTimeInterval(20),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertNotNil(before.profile)
        XCTAssertTrue(before.hasEligibleRegimen)
        XCTAssertTrue(
            before.reminderOptions.contains {
                $0.regimenVersionID == regimen.versionID
            }
        )
        XCTAssertTrue(
            before.drafts.contains {
                $0.id == draftID
                    && $0.title == "待删除草稿"
            }
        )
#if DEBUG
        let developmentBackup = try await reader
            .developmentBackup()
        XCTAssertGreaterThan(
            developmentBackup.totalRecordCount,
            0
        )
#endif

        var context = ModelContext(container)
        let hrtPlan = try plan(
            .hrtJourney,
            context: context
        )
        _ = try await writer.commitDataControlDeletion(
            impact: hrtPlan.impact,
            command: hrtPlan.command(
                operationID: UUID(),
                timestamp: try deletionTimestamp(
                    1_800_190_030
                )
            ),
            activeGenerationID: generationID
        )

        context = ModelContext(container)
        let regimenPlan = try plan(
            .sealedRegimenVersion(
                regimen.versionID
            ),
            context: context
        )
        _ = try await writer.commitDataControlDeletion(
            impact: regimenPlan.impact,
            command: regimenPlan.command(
                operationID: UUID(),
                timestamp: try deletionTimestamp(
                    1_800_190_040
                )
            ),
            activeGenerationID: generationID
        )

        context = ModelContext(container)
        let draftPlan = try plan(
            .draftRegimenVersion(draftID),
            context: context
        )
        _ = try await writer.commitDataControlDeletion(
            impact: draftPlan.impact,
            command: draftPlan.command(
                operationID: UUID(),
                timestamp: try deletionTimestamp(
                    1_800_190_045
                )
            ),
            activeGenerationID: generationID
        )

        let onboarding = try await reader.onboardingSnapshot(
            asOf: createdAt.addingTimeInterval(50),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertNil(onboarding.profile)
        XCTAssertFalse(onboarding.hasEligibleRegimen)
        XCTAssertTrue(onboarding.reminderOptions.isEmpty)
        XCTAssertTrue(onboarding.drafts.isEmpty)
        let profile = try await reader
            .onboardingProfileSnapshot()
        XCTAssertNil(profile)

        let overview = try await reader.coreRegimenOverview(
            asOf: hrtTimestamp.localDate
        )
        let redacted = try XCTUnwrap(overview.current)
        XCTAssertEqual(redacted.id, regimen.versionID)
        XCTAssertEqual(redacted.code, "已删除")
        XCTAssertEqual(redacted.title, "已删除方案")
        XCTAssertEqual(redacted.changeReason, "")
        XCTAssertTrue(redacted.items.isEmpty)

        let todayExecution = try await reader
            .todayExecutionSnapshot(
                now: createdAt.addingTimeInterval(50),
                displayTimeZoneIdentifier: "UTC"
            )
        XCTAssertFalse(
            todayExecution.items.contains {
                $0.occurrence.regimenVersionID
                    == regimen.versionID
            }
        )
        let reminderPlanning = try await reader
            .reminderPlanningSnapshot(
                now: createdAt.addingTimeInterval(50),
                displayTimeZoneIdentifier: "UTC",
                horizonLocalDays: 14
            )
        XCTAssertFalse(
            reminderPlanning.candidates.contains {
                $0.occurrence.regimenVersionID
                    == regimen.versionID
            }
        )

        let archive = try await reader.archiveSnapshot()
        XCTAssertEqual(archive.profileCount, 0)
        XCTAssertEqual(archive.regimenCount, 0)
        XCTAssertEqual(
            archive.developmentExportItemCount,
            0
        )
        XCTAssertNil(archive.firstActivityDate)
        XCTAssertNil(archive.latestActivityDate)
#if DEBUG
        do {
            _ = try await reader.developmentBackup()
            XCTFail(
                "terminal facts must disable legacy export"
            )
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetDeleted
            )
        }
#endif
    }

    func testArchiveCountIgnoresTombstoneForArchivedSealedVersion()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let context = ModelContext(fixture.container)
        let archived = RegimenPlanVersionRecord(
            code: "ARCHIVED",
            title: "已归档",
            effectiveStartDate: try CivilDateFact(
                year: 2025,
                month: 12,
                day: 1
            ),
            editState: .sealed,
            isArchived: true
        )
        context.insert(archived)
        try context.save()
        let snapshot = try await AppReadActor(
            modelContainer: fixture.container
        ).archiveSnapshot(
            terminalOverlay: DataControlTerminalOverlay(
                journeyEntryIDs: [],
                administrationOccurrenceKeys: [],
                draftRegimenVersionIDs: [],
                sealedRegimenVersionIDs: [archived.id],
                hidesHrtJourney: false
            )
        )
        XCTAssertEqual(snapshot.regimenCount, 1)
    }

    func testArchiveKeysetScansSecondPageWithSameDateUUIDTies()
        async throws {
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        let context = ModelContext(container)
        let total = 4_098
        let instant = Date(
            timeIntervalSince1970: 1_800_210_000
        )
        let civilDate = try CivilDateFact(
            year: 2027,
            month: 1,
            day: 15
        )
        var journeyIDs: [UUID] = []
        var regimenIDs: [UUID] = []
        journeyIDs.reserveCapacity(total)
        regimenIDs.reserveCapacity(total)
        for index in 0..<total {
            let journeyID = try XCTUnwrap(
                UUID(
                    uuidString: String(
                        format:
                            "10000000-0000-0000-0000-%012llx",
                        UInt64(index)
                    )
                )
            )
            let regimenID = try XCTUnwrap(
                UUID(
                    uuidString: String(
                        format:
                            "20000000-0000-0000-0000-%012llx",
                        UInt64(index)
                    )
                )
            )
            journeyIDs.append(journeyID)
            regimenIDs.append(regimenID)
            context.insert(
                JourneyEntry(
                    id: journeyID,
                    text: "分页回归",
                    kind: .moment,
                    occurredAt: instant,
                    createdAt: instant
                )
            )
            context.insert(
                RegimenPlanVersionRecord(
                    id: regimenID,
                    code: "PAGE-\(index)",
                    title: "分页回归",
                    effectiveStartDate: civilDate,
                    editState: .sealed,
                    createdAt: instant
                )
            )
        }
        try context.save()

        let snapshot = try await AppReadActor(
            modelContainer: container
        ).archiveSnapshot(
            terminalOverlay: DataControlTerminalOverlay(
                journeyEntryIDs: [
                    try XCTUnwrap(journeyIDs.first),
                    try XCTUnwrap(journeyIDs.last)
                ],
                administrationOccurrenceKeys: [],
                draftRegimenVersionIDs: [],
                sealedRegimenVersionIDs: [
                    try XCTUnwrap(regimenIDs.first),
                    try XCTUnwrap(regimenIDs.last)
                ],
                hidesHrtJourney: false
            )
        )

        XCTAssertEqual(snapshot.journeyCount, total - 2)
        XCTAssertEqual(snapshot.regimenCount, total - 2)
        XCTAssertEqual(snapshot.latestActivityDate, instant)
        XCTAssertLessThan(
            try XCTUnwrap(snapshot.firstActivityDate),
            instant
        )
    }

    func testParentRecordTombstoneRedactsLegacyLabArchiveAndExport()
        async throws {
        let legacyID = UUID(
            uuidString:
                "33333333-4444-5555-6666-777777777777"
        )!
        let sampledAt = Date(
            timeIntervalSince1970: 1_800_220_000
        )
        let container = try makeWritableDataControlContainer(
            legacyLab: LabRecord(
                id: legacyID,
                itemName: "雌二醇",
                itemCode: "E2",
                rawValue: "100",
                numericValue: 100,
                unit: "pmol/L",
                sampledAt: sampledAt,
                createdAt: sampledAt
            )
        )
        let storage = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppDataReader(
            storage: storage,
            dataControlCoordinator:
                AppDataControlCoordinator(
                    generationID: generationID
                )
        )
        let before = try await reader.archiveSnapshot()
        XCTAssertEqual(before.labRecordCount, 1)
        XCTAssertEqual(before.firstActivityDate, sampledAt)
        XCTAssertEqual(before.latestActivityDate, sampledAt)

        let sampleID = PersonalTimelineBackfill
            .legacySampleID(for: legacyID)
        let impact = try await storage
            .parentRecordDeletionImpact(
                type: .labSample,
                id: sampleID
            )
        _ = try await writer.deleteParentRecord(
            DeleteParentRecordCommand(
                parentType: .labSample,
                parentID: sampleID,
                expectedHead: impact.expectedHead,
                expectedImpactDigest:
                    impact.impactDigest,
                attachments: []
            )
        )

        let after = try await reader.archiveSnapshot()
        XCTAssertEqual(after.labRecordCount, 0)
        XCTAssertEqual(after.developmentExportItemCount, 0)
        XCTAssertNil(after.firstActivityDate)
        XCTAssertNil(after.latestActivityDate)
        let todaySnapshot = try await reader.todaySnapshot()
        XCTAssertTrue(todaySnapshot.labRecords.isEmpty)
        let overview = try await reader
            .coreRegimenOverview(
                asOf: try CivilDateFact(
                    year: 2027,
                    month: 1,
                    day: 1
                )
            )
        XCTAssertTrue(overview.labRecords.isEmpty)
        XCTAssertNil(overview.latestLabSample)
        let localDate = try timestamp(
            instant: sampledAt
        ).localDate
        let dayLabRecords = try await reader.labRecords(
            on: localDate,
            fallbackTimeZone:
                try XCTUnwrap(
                    TimeZone(identifier: "UTC")
                )
        )
        XCTAssertTrue(dayLabRecords.isEmpty)
#if DEBUG
        do {
            _ = try await reader.developmentBackup()
            XCTFail(
                "parent terminal facts must disable legacy export"
            )
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetDeleted
            )
        }
#endif
    }

    func testProductionDeletionServiceCommitsOverlayAndWriterBarrier()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let coordinator = AppDataControlCoordinator(
            generationID: generationID
        )
        let storage = AppWriteActor(
            modelContainer: fixture.container
        )
        let writer = AppDataWriter(
            storage: storage,
            dataControlCoordinator: coordinator,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let metadata = try XCTUnwrap(
            ModelContext(fixture.container).fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let manifestProvider = FixedDataControlManifestProvider(
            manifest: DataInventoryManifest(
                generationID: generationID,
                datasetID: metadata.datasetID,
                nextLocalRevision: metadata.nextLocalRevision,
                capturedAt: Date(
                    timeIntervalSince1970: 1_800_199_000
                ),
                completeness: .complete,
                categories: [],
                unmanagedBoundaries: [],
                stateDigest: String(repeating: "a", count: 64),
                manifestDigest: String(
                    repeating: "b",
                    count: 64
                )
            )
        )
        let attachmentRoot = FileManager.default
            .temporaryDirectory
            .appending(
                path:
                    "DataControlDeletionService-"
                        + UUID().uuidString,
                directoryHint: .isDirectory
            )
        defer {
            try? FileManager.default.removeItem(
                at: attachmentRoot
            )
        }
        let latch = AttachmentMutationRecoveryLatch()
        let service = DataControlDeletionService(
            generationID: generationID,
            writer: writer,
            fileStore: AttachmentFileStore(
                rootURL: attachmentRoot
            ),
            inventoryService: manifestProvider,
            notificationClient:
                FixedDataControlNotificationClient(),
            dataControlCoordinator: coordinator,
            recoveryLatch: latch,
            onRecoveryRequired: {}
        )

        let preview = try await service.preview(
            target: .journeyEntry(fixture.journeyID),
            now: Date(timeIntervalSince1970: 1_800_200_100),
            timeZoneIdentifier: "UTC"
        )
        let result = try await service.confirm(preview)

        XCTAssertTrue(result.didApply)
        let replay = try await service.confirm(preview)
        XCTAssertFalse(replay.didApply)
        XCTAssertEqual(
            replay.tombstoneID,
            result.tombstoneID
        )
        XCTAssertFalse(latch.isInvalidated)
        let reader = AppDataReader(
            storage: AppReadActor(
                modelContainer: fixture.container
            ),
            dataControlCoordinator: coordinator
        )
        let page = try await reader.journeyPage(
            after: nil,
            limit: 100
        )
        XCTAssertFalse(
            page.entries.contains { $0.id == fixture.journeyID }
        )
        do {
            try await writer.addJourneyEntry(
                AddJourneyEntryCommand(
                    recordID: fixture.journeyID,
                    text: "must not revive",
                    kind: .moment,
                    occurredAt: Date(
                        timeIntervalSince1970: 1_800_200_101
                    ),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                )
            )
            XCTFail("terminal target must not be revived")
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetDeleted
            )
        }
        do {
            try await storage.addJourneyEntry(
                AddJourneyEntryCommand(
                    recordID: fixture.journeyID,
                    text: "raw actor must not revive",
                    kind: .moment,
                    occurredAt: Date(
                        timeIntervalSince1970:
                            1_800_200_102
                    ),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                )
            )
            XCTFail(
                "transaction-local barrier must reject raw actor mutation"
            )
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetDeleted
            )
        }
    }

    func testProductionDeletionServicePlannerTargetClearsOwnedPendingAndReconciles()
        async throws {
        let fixture = try makeComprehensiveFixture()
        let coordinator = AppDataControlCoordinator(
            generationID: generationID
        )
        let storage = AppWriteActor(
            modelContainer: fixture.container
        )
        let writer = AppDataWriter(
            storage: storage,
            dataControlCoordinator: coordinator,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let metadata = try XCTUnwrap(
            ModelContext(fixture.container).fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let manifestProvider =
            FixedDataControlManifestProvider(
                manifest: DataInventoryManifest(
                    generationID: generationID,
                    datasetID: metadata.datasetID,
                    nextLocalRevision:
                        metadata.nextLocalRevision,
                    capturedAt: Date(
                        timeIntervalSince1970:
                            1_800_199_100
                    ),
                    completeness: .complete,
                    categories: [],
                    unmanagedBoundaries: [],
                    stateDigest: String(
                        repeating: "c",
                        count: 64
                    ),
                    manifestDigest: String(
                        repeating: "d",
                        count: 64
                    )
                )
            )
        let notificationClient =
            FixedDataControlNotificationClient(
                pending: [
                    "unmanual.exec.v1.fixture",
                    "foreign.pending"
                ],
                delivered: [
                    "unmanual.countdown.v1.delivered",
                    "foreign.delivered"
                ]
            )
        let attachmentRoot = FileManager.default
            .temporaryDirectory
            .appending(
                path:
                    "DataControlPlannerDeletionService-"
                        + UUID().uuidString,
                directoryHint: .isDirectory
            )
        defer {
            try? FileManager.default.removeItem(
                at: attachmentRoot
            )
        }
        let latch = AttachmentMutationRecoveryLatch()
        let service = DataControlDeletionService(
            generationID: generationID,
            writer: writer,
            fileStore: AttachmentFileStore(
                rootURL: attachmentRoot
            ),
            inventoryService: manifestProvider,
            notificationClient: notificationClient,
            dataControlCoordinator: coordinator,
            recoveryLatch: latch,
            onRecoveryRequired: {}
        )
        let reconciliation =
            DataControlReconciliationRecorder()
        let preview = try await service.preview(
            target: .administrationOccurrence(
                fixture.occurrence
            ),
            now: Date(
                timeIntervalSince1970:
                    1_800_200_110
            ),
            timeZoneIdentifier: "UTC"
        )

        let result = try await service.confirm(
            preview,
            reconcileReminders: {
                await reconciliation.record()
                return true
            }
        )
        let reconciliationCount =
            await reconciliation.count()

        XCTAssertTrue(result.didApply)
        XCTAssertEqual(
            reconciliationCount,
            1
        )
        let notifications =
            await notificationClient.snapshot()
        XCTAssertEqual(
            notifications.pending,
            ["foreign.pending"]
        )
        XCTAssertEqual(
            Set(notifications.delivered),
            [
                "unmanual.countdown.v1.delivered",
                "foreign.delivered"
            ]
        )
        XCTAssertFalse(latch.isInvalidated)
        XCTAssertEqual(
            try ModelContext(fixture.container)
                .fetchCount(
                    FetchDescriptor<
                        DataControlDeletionTombstoneRecord
                    >()
                ),
            1
        )
    }

    func testProductionServiceCancelConfirmAndReopenForAllFiveTargets()
        async throws
    {
        var temporaryRoots: [URL] = []
        defer {
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
        }

        for targetIndex in 0..<5 {
            let temporaryRoot = FileManager.default
                .temporaryDirectory
                .appending(
                    path:
                        "DataControlAllTargets-"
                            + UUID().uuidString,
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: false
            )
            temporaryRoots.append(temporaryRoot)
            let storeURL = temporaryRoot.appending(
                path: "user.sqlite"
            )
            let attachmentRoot = temporaryRoot.appending(
                path: "Files",
                directoryHint: .isDirectory
            )
            let firstPass = try await
                performPersistentDeletionFirstPass(
                    targetIndex: targetIndex,
                    storeURL: storeURL,
                    attachmentRoot: attachmentRoot
                )
            let reopenedContainer = try AppModelContainerFactory
                .makeDataControlContainer(at: storeURL)
            let reopenedFixture = Fixture(
                container: reopenedContainer,
                journeyID: firstPass.journeyID,
                draftVersionID: firstPass.draftVersionID,
                sealedVersionID: firstPass.sealedVersionID,
                occurrence: firstPass.occurrence
            )
            let reopenedService = try makeProductionDeletionService(
                fixture: reopenedFixture,
                coordinator: AppDataControlCoordinator(
                    generationID: generationID
                ),
                attachmentRoot: attachmentRoot,
                manifestSeed: targetIndex
            )
            let replay = try await reopenedService.confirm(
                firstPass.preview
            )
            XCTAssertFalse(replay.didApply)
            XCTAssertEqual(
                replay.tombstoneID,
                firstPass.result.tombstoneID
            )

            let overlay = try await AppReadActor(
                modelContainer: reopenedContainer
            ).dataControlTerminalOverlay()
            XCTAssertTrue(
                overlay.contains(
                    kind: firstPass.target.kind,
                    stableKey: firstPass.target.stableKey,
                    targetID: firstPass.target.targetID
                ),
                "target \(firstPass.target.kind.rawValue)"
            )
            XCTAssertEqual(
                try ModelContext(reopenedContainer).fetchCount(
                    FetchDescriptor<
                        DataControlDeletionTombstoneRecord
                    >()
                ),
                1
            )
        }
    }

    func testSealRejectsDeletedSuccessorBeforeAnyMutation()
        async throws {
        let container = try makeWritableDataControlContainer()
        let writer = AppWriteActor(
            modelContainer: container
        )
        func saveAndSeal(
            id: UUID,
            previousVersionID: UUID?,
            month: Int,
            committedAt: TimeInterval
        ) async throws {
            try await writer.saveRegimenDraft(
                SaveRegimenDraftCommand(
                    recordID: id,
                    previousVersionID: previousVersionID,
                    code: "R-\(month)",
                    title: "方案 \(month)",
                    effectiveStartDate: try CivilDateFact(
                        year: 2026,
                        month: month,
                        day: 1
                    ),
                    changeReason: "写集屏障测试",
                    items: [
                        RegimenItemInput(
                            displayName: "项目 \(month)",
                            schedule: RegimenScheduleInput(
                                id: UUID(),
                                kind: .dailyTimes,
                                localTimes: "09:00"
                            )
                        )
                    ],
                    committedAt: Date(
                        timeIntervalSince1970: committedAt
                    )
                )
            )
            let preview = try await writer
                .previewRegimenChange(draftID: id)
            try await writer.sealRegimenDraft(
                SealRegimenDraftCommand(
                    draftID: id,
                    expectedNextLocalRevision:
                        preview.expectedNextLocalRevision,
                    draftDigest: preview.draftDigest,
                    committedAt: Date(
                        timeIntervalSince1970:
                            committedAt + 1
                    )
                )
            )
        }
        let firstID = UUID(
            uuidString:
                "52000000-0000-0000-0000-000000000001"
        )!
        do {
            try await saveAndSeal(
                id: firstID,
                previousVersionID: nil,
                month: 1,
                committedAt: 1_800_200_190
            )
        } catch {
            XCTFail("failed to create first version: \(error)")
            return
        }
        let successorID = UUID(
            uuidString:
                "52000000-0000-0000-0000-000000000003"
        )!
        do {
            try await saveAndSeal(
                id: successorID,
                previousVersionID: firstID,
                month: 3,
                committedAt: 1_800_200_200
            )
        } catch {
            XCTFail("failed to create successor: \(error)")
            return
        }

        let middleID = UUID(
            uuidString:
                "52000000-0000-0000-0000-000000000002"
        )!
        do {
            try await writer.saveRegimenDraft(
                SaveRegimenDraftCommand(
                recordID: middleID,
                previousVersionID: firstID,
                code: "MIDDLE",
                title: "中间方案",
                effectiveStartDate: try CivilDateFact(
                    year: 2026,
                    month: 2,
                    day: 1
                ),
                changeReason: "测试删除屏障",
                items: [
                    RegimenItemInput(
                        displayName: "中间项目",
                        schedule: RegimenScheduleInput(
                            id: UUID(),
                            kind: .dailyTimes,
                            localTimes: "09:00"
                        )
                    )
                ],
                committedAt: Date(
                    timeIntervalSince1970: 1_800_200_202
                )
                )
            )
        } catch {
            XCTFail("failed to create middle draft: \(error)")
            return
        }
        let deletionPlan: DataControlDeletionPlan
        do {
            deletionPlan = try plan(
                .sealedRegimenVersion(successorID),
                context: ModelContext(container)
            )
            _ = try await writer.commitDataControlDeletion(
                impact: deletionPlan.impact,
                command: deletionPlan.command(
                    operationID: UUID(),
                    timestamp: try deletionTimestamp(
                        1_800_200_203
                    )
                ),
                activeGenerationID: generationID
            )
        } catch {
            XCTFail("failed to delete successor: \(error)")
            return
        }

        let preview: RegimenChangePreview
        do {
            preview = try await writer.previewRegimenChange(
                draftID: middleID
            )
        } catch {
            XCTFail("failed to preview middle draft: \(error)")
            return
        }
        let before = ModelContext(container)
        let nextRevisionBefore = try XCTUnwrap(
            before.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        ).nextLocalRevision

        do {
            try await writer.sealRegimenDraft(
                SealRegimenDraftCommand(
                    draftID: middleID,
                    expectedNextLocalRevision:
                        preview.expectedNextLocalRevision,
                    draftDigest: preview.draftDigest,
                    committedAt: Date(
                        timeIntervalSince1970:
                            1_800_200_204
                    )
                )
            )
            XCTFail(
                "deleted successor must block the entire seal write set"
            )
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetDeleted
            )
        }

        let verification = ModelContext(container)
        let versions = try verification.fetch(
            FetchDescriptor<RegimenPlanVersionRecord>()
        )
        XCTAssertEqual(
            versions.first { $0.id == middleID }?.editState,
            .draft
        )
        XCTAssertEqual(
            versions.first { $0.id == successorID }?
                .previousVersionID,
            firstID
        )
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision,
            nextRevisionBefore
        )

        let reader = AppDataReader(
            storage: AppReadActor(
                modelContainer: container
            ),
            dataControlCoordinator:
                AppDataControlCoordinator(
                    generationID: generationID
                )
        )
        let overview: CoreRegimenOverviewSnapshot
        do {
            overview = try await reader.coreRegimenOverview(
                asOf: try CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 1
                )
            )
        } catch {
            XCTFail(
                "failed to read terminal regimen lineage: \(error)"
            )
            return
        }
        let deletedSuccessor = try XCTUnwrap(
            overview.allVersions.first {
                $0.id == successorID
            }
        )
        XCTAssertEqual(
            deletedSuccessor.title,
            "已删除方案"
        )
        XCTAssertEqual(deletedSuccessor.code, "已删除")
        XCTAssertTrue(deletedSuccessor.items.isEmpty)
        XCTAssertTrue(
            overview.lineageAnchors.contains {
                $0.id == successorID
            }
        )
        XCTAssertTrue(
            overview.terminalDeletedVersionIDs
                .contains(successorID)
        )
        let deletionCandidates =
            ArchiveDataControlInteractionPolicy
                .regimenDeletionCandidates(in: overview)
        XCTAssertFalse(
            deletionCandidates.contains {
                $0.id == successorID
            }
        )
        XCTAssertTrue(
            deletionCandidates.contains {
                $0.id == middleID
                    && $0.editState == .draft
            }
        )
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: UUID(),
                previousVersionID: successorID,
                code: "AFTER-TERMINAL",
                title: "删除后的后续方案",
                effectiveStartDate: try CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 1
                ),
                changeReason: "terminal 只作为谱系锚点",
                items: [
                    RegimenItemInput(
                        displayName: "后续项目"
                    )
                ],
                committedAt: Date(
                    timeIntervalSince1970:
                        1_800_200_205
                )
            )
        )
    }

    func testSealRejectsDeletedJourneyHistoricalReassociationWithZeroWrites()
        async throws {
        let container = try makeWritableDataControlContainer()
        let first = try await createSealedRegimen(
            in: container,
            effectiveStartDate: try CivilDateFact(
                year: 2026,
                month: 1,
                day: 1
            ),
            committedAt: try utcDate(
                year: 2026,
                month: 1,
                day: 1,
                hour: 1
            )
        )
        let journeyID = UUID()
        let occurredAt = try utcDate(
            year: 2026,
            month: 3,
            day: 15,
            hour: 12
        )
        let writer = AppWriteActor(
            modelContainer: container
        )
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: journeyID,
                text: "将被 terminal 删除的旅程",
                kind: .moment,
                occurredAt: occurredAt,
                regimenVersionID: first.versionID,
                timeZoneIdentifier: "UTC"
            )
        )
        let draftID = UUID()
        try await saveDraft(
            in: container,
            draftID: draftID,
            previousVersionID: first.versionID,
            effectiveStartDate: try CivilDateFact(
                year: 2026,
                month: 3,
                day: 1
            ),
            committedAt:
                occurredAt.addingTimeInterval(1)
        )
        let deletion = try plan(
            .journeyEntry(journeyID),
            context: ModelContext(container)
        )
        _ = try await writer.commitDataControlDeletion(
            impact: deletion.impact,
            command: deletion.command(
                operationID: UUID(),
                timestamp: try timestamp(
                    instant:
                        occurredAt.addingTimeInterval(2)
                )
            ),
            activeGenerationID: generationID
        )
        let preview = try await writer
            .previewRegimenChange(draftID: draftID)
        let before = ModelContext(container)
        let nextRevision = try XCTUnwrap(
            before.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        ).nextLocalRevision

        do {
            try await writer.sealRegimenDraft(
                SealRegimenDraftCommand(
                    draftID: draftID,
                    expectedNextLocalRevision:
                        preview.expectedNextLocalRevision,
                    draftDigest: preview.draftDigest,
                    committedAt:
                        occurredAt.addingTimeInterval(3)
                )
            )
            XCTFail(
                "deleted journey history must block reassociation"
            )
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetDeleted
            )
        }

        let verification = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision,
            nextRevision
        )
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<RegimenPlanVersionRecord>()
                ).first { $0.id == draftID }
            ).editState,
            .draft
        )
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<HistoricalTimeRecord>()
                ).first {
                    $0.sourceRecordType == "JourneyEntry"
                        && $0.sourceRecordID == journeyID
                }
            ).resolvedRegimenVersionID,
            first.versionID
        )
    }

    func testSealRejectsDeletedAdministrationHistoricalReassociationWithZeroWrites()
        async throws {
        let container = try makeWritableDataControlContainer()
        let first = try await createSealedRegimen(
            in: container,
            effectiveStartDate: try CivilDateFact(
                year: 2026,
                month: 1,
                day: 1
            ),
            committedAt: try utcDate(
                year: 2026,
                month: 1,
                day: 1,
                hour: 1
            )
        )
        let localDate = try CivilDateFact(
            year: 2026,
            month: 3,
            day: 15
        )
        let dayStart = try utcDate(
            year: 2026,
            month: 3,
            day: 15,
            hour: 0
        )
        let occurrence = try XCTUnwrap(
            ScheduleOccurrenceResolver.occurrences(
                rules: [
                    ScheduleRuleSpec(
                        id: first.scheduleRuleID,
                        regimenVersionID: first.versionID,
                        regimenItemID: first.itemID,
                        displayName: "测试项目",
                        kind: .dailyTimes,
                        anchorDate: try CivilDateFact(
                            year: 2026,
                            month: 1,
                            day: 1
                        ),
                        endDate: nil,
                        localTimes: "09:00",
                        weekdays: "",
                        intervalDays: nil,
                        timeZoneBehavior: .floatingLocal,
                        fixedTimeZoneIdentifier: nil,
                        revision: 1
                    )
                ],
                interval: DateInterval(
                    start: dayStart,
                    duration: 86_400
                ),
                displayTimeZoneIdentifier: "UTC"
            ).occurrences.first
        )
        let localTime = occurrence.localTime
        let instant = occurrence.instant
        let writer = AppWriteActor(
            modelContainer: container
        )
        let eventID = UUID()
        _ = try await writer.commitAdministration(
            CommitAdministrationCommand(
                operationID: UUID(),
                eventID: eventID,
                occurrence: occurrence,
                expectedLeafEventID: nil,
                status: .taken,
                actualTimestamp: try timestamp(
                    instant: instant
                ),
                committedAt: instant,
                displayTimeZoneIdentifier: "UTC"
            )
        )
        let draftID = UUID()
        try await saveDraft(
            in: container,
            draftID: draftID,
            previousVersionID: first.versionID,
            effectiveStartDate: try CivilDateFact(
                year: 2026,
                month: 3,
                day: 1
            ),
            committedAt: instant.addingTimeInterval(1)
        )
        let target = DataControlOccurrenceProjection(
            key: occurrence.key,
            scheduleRuleID: occurrence.scheduleRuleID,
            scheduleRevision: Int64(
                occurrence.scheduleRevision
            ),
            regimenVersionID: occurrence.regimenVersionID,
            regimenItemID: occurrence.regimenItemID,
            displayTimeZoneIdentifier: "UTC",
            localYear: Int64(localDate.year),
            localMonth: Int64(localDate.month),
            localDay: Int64(localDate.day),
            localHour: Int64(localTime.hour),
            localMinute: Int64(localTime.minute),
            localSecond: Int64(localTime.second),
            localNanosecond:
                Int64(localTime.nanosecond),
            resolvedTimeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            instant: instant
        )
        let deletion = try plan(
            .administrationOccurrence(target),
            context: ModelContext(container)
        )
        _ = try await writer.commitDataControlDeletion(
            impact: deletion.impact,
            command: deletion.command(
                operationID: UUID(),
                timestamp: try timestamp(
                    instant: instant.addingTimeInterval(2)
                )
            ),
            activeGenerationID: generationID
        )
        let preview = try await writer
            .previewRegimenChange(draftID: draftID)
        let before = ModelContext(container)
        let nextRevision = try XCTUnwrap(
            before.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        ).nextLocalRevision

        do {
            try await writer.sealRegimenDraft(
                SealRegimenDraftCommand(
                    draftID: draftID,
                    expectedNextLocalRevision:
                        preview.expectedNextLocalRevision,
                    draftDigest: preview.draftDigest,
                    committedAt:
                        instant.addingTimeInterval(3)
                )
            )
            XCTFail(
                "deleted administration history must block reassociation"
            )
        } catch {
            XCTAssertEqual(
                error as? DataControlDeletionFailure,
                .targetDeleted
            )
        }

        let verification = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision,
            nextRevision
        )
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<RegimenPlanVersionRecord>()
                ).first { $0.id == draftID }
            ).editState,
            .draft
        )
        XCTAssertEqual(
            try XCTUnwrap(
                verification.fetch(
                    FetchDescriptor<HistoricalTimeRecord>()
                ).first {
                    $0.sourceRecordType
                        == "AdministrationEventRecord"
                        && $0.sourceRecordID == eventID
                }
            ).resolvedRegimenVersionID,
            first.versionID
        )
    }

    private struct Fixture {
        let container: ModelContainer
        let journeyID: UUID
        let draftVersionID: UUID
        let sealedVersionID: UUID
        let occurrence: DataControlOccurrenceProjection
    }

    private struct PersistentDeletionFirstPass {
        let target: DataControlDeletionTarget
        let preview: DataControlDeletionPreview
        let result: DataControlDeletionWriteResult
        let journeyID: UUID
        let draftVersionID: UUID
        let sealedVersionID: UUID
        let occurrence: DataControlOccurrenceProjection
    }

    private struct RecordRevisionSnapshot:
        Equatable {
        let recordKey: String
        let recordType: String
        let recordID: UUID
        let datasetID: UUID
        let localRevision: Int64
        let digestVersion: Int
        let digestHex: String
        let committedAt: Date
    }

    private struct OperationReceiptSnapshot:
        Equatable {
        let operationID: UUID
        let commandDigest: String
        let resultRecordType: String
        let resultRecordID: UUID
        let committedAt: Date
    }

    private struct OperationReceiptLedgerSnapshot:
        Equatable {
        let ledgerKey: String
        let receiptCount: Int
        let receiptSetDigest: String
        let updatedAt: Date
    }

    private func recordRevisionSnapshots(
        in context: ModelContext
    ) throws -> [RecordRevisionSnapshot] {
        try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        .map {
            RecordRevisionSnapshot(
                recordKey: $0.recordKey,
                recordType: $0.recordType,
                recordID: $0.recordID,
                datasetID: $0.datasetID,
                localRevision: $0.localRevision,
                digestVersion: $0.digestVersion,
                digestHex: $0.digestHex,
                committedAt: $0.committedAt
            )
        }
        .sorted { $0.recordKey < $1.recordKey }
    }

    private func operationReceiptSnapshots(
        in context: ModelContext
    ) throws -> [OperationReceiptSnapshot] {
        try context.fetch(
            FetchDescriptor<OperationReceiptRecord>()
        )
        .map {
            OperationReceiptSnapshot(
                operationID: $0.operationID,
                commandDigest: $0.commandDigest,
                resultRecordType: $0.resultRecordType,
                resultRecordID: $0.resultRecordID,
                committedAt: $0.committedAt
            )
        }
        .sorted {
            $0.operationID.uuidString
                < $1.operationID.uuidString
        }
    }

    private func operationReceiptLedgerSnapshots(
        in context: ModelContext
    ) throws -> [OperationReceiptLedgerSnapshot] {
        try context.fetch(
            FetchDescriptor<
                OperationReceiptLedgerRecord
            >()
        )
        .map {
            OperationReceiptLedgerSnapshot(
                ledgerKey: $0.ledgerKey,
                receiptCount: $0.receiptCount,
                receiptSetDigest: $0.receiptSetDigest,
                updatedAt: $0.updatedAt
            )
        }
        .sorted { $0.ledgerKey < $1.ledgerKey }
    }

    private func makeComprehensiveFixture(
        container suppliedContainer: ModelContainer? = nil,
        actualOffset: TimeInterval = 0,
        scheduleTimeZoneBehavior:
            ScheduleTimeZoneBehavior = .floatingLocal,
        fixedTimeZoneIdentifier: String? = nil
    ) throws -> Fixture {
        let container = try suppliedContainer
            ?? makeReadyContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let committedAt = Date(timeIntervalSince1970: 1_800_150_000)

        let journey = JourneyEntry(
            text: "private journey",
            kind: .moment,
            occurredAt: committedAt,
            createdAt: committedAt
        )
        let journeyTime = HistoricalTimeRecord(
            sourceRecordType: "JourneyEntry",
            sourceRecordID: journey.id,
            timestamp: try timestamp(instant: committedAt),
            legacyAssociationID: nil,
            resolvedRegimenVersionID: nil,
            associationState: .missing
        )
        context.insert(journey)
        context.insert(journeyTime)
        try insertRevision(
            recordType: "JourneyEntry",
            recordID: journey.id,
            fields: try FactDigestV1.journey(journey),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "HistoricalTimeRecord",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: journeyTime.recordKey
            ),
            fields: try CoreFactDigestV1.historicalTime(
                journeyTime
            ),
            committedAt: committedAt,
            context: context
        )

        let start = try CivilDateFact(
            year: 2026,
            month: 1,
            day: 1
        )
        let draft = RegimenPlanVersionRecord(
            code: "DRAFT",
            title: "draft",
            effectiveStartDate: start,
            editState: .draft,
            createdAt: committedAt
        )
        let draftItem = RegimenItemRecord(
            regimenVersionID: draft.id,
            sortOrder: 0,
            displayName: "draft item",
            createdAt: committedAt
        )
        let draftRule = ScheduleRuleRecord(
            regimenItemID: draftItem.id,
            kind: .dailyTimes,
            anchorDate: start,
            localTimes: "09:00",
            timeZoneBehavior: .floatingLocal,
            reminderEnabled: true,
            revision: 1,
            createdAt: committedAt
        )
        let draftPreference = ReminderPreferenceRecord(
            scheduleRuleID: draftRule.id,
            expectedRuleRevision: 1,
            isEnabled: true,
            lastOperationID: UUID(),
            updatedAt: committedAt
        )
        try insertRegimenFacts(
            version: draft,
            item: draftItem,
            rule: draftRule,
            preference: draftPreference,
            committedAt: committedAt,
            context: context
        )

        let sealed = RegimenPlanVersionRecord(
            code: "SEALED",
            title: "sealed",
            effectiveStartDate: start,
            editState: .sealed,
            createdAt: committedAt
        )
        let sealedItem = RegimenItemRecord(
            regimenVersionID: sealed.id,
            sortOrder: 0,
            displayName: "sealed item",
            createdAt: committedAt
        )
        let sealedRule = ScheduleRuleRecord(
            regimenItemID: sealedItem.id,
            kind: .dailyTimes,
            anchorDate: start,
            localTimes: "09:00",
            timeZoneBehavior:
                scheduleTimeZoneBehavior,
            fixedTimeZoneIdentifier:
                fixedTimeZoneIdentifier,
            reminderEnabled: true,
            revision: 1,
            createdAt: committedAt
        )
        let sealedPreference = ReminderPreferenceRecord(
            scheduleRuleID: sealedRule.id,
            expectedRuleRevision: 1,
            isEnabled: true,
            lastOperationID: UUID(),
            updatedAt: committedAt
        )
        try insertRegimenFacts(
            version: sealed,
            item: sealedItem,
            rule: sealedRule,
            preference: sealedPreference,
            committedAt: committedAt,
            context: context
        )

        let occurrenceDate = try CivilDateFact(
            year: 2026,
            month: 1,
            day: 2
        )
        let occurrenceTime = try HistoricalLocalTime(
            hour: 9,
            minute: 0,
            second: 0
        )
        let occurrenceInstant = try utcDate(
            year: 2026,
            month: 1,
            day: 2,
            hour: 9
        )
        let occurrenceKey = ScheduleOccurrenceResolver
            .occurrenceKey(
                ruleID: sealedRule.id,
                revision: sealedRule.revision,
                date: occurrenceDate,
                time: occurrenceTime
            )
        let occurrence = DataControlOccurrenceProjection(
            key: occurrenceKey,
            scheduleRuleID: sealedRule.id,
            scheduleRevision: Int64(sealedRule.revision),
            regimenVersionID: sealed.id,
            regimenItemID: sealedItem.id,
            displayTimeZoneIdentifier: "UTC",
            localYear: 2026,
            localMonth: 1,
            localDay: 2,
            localHour: 9,
            localMinute: 0,
            localSecond: 0,
            localNanosecond: 0,
            resolvedTimeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            instant: occurrenceInstant
        )
        let override = ReminderOverrideRecord(
            occurrenceKey: occurrenceKey,
            scheduleRuleID: sealedRule.id,
            scheduleRevision: sealedRule.revision,
            fireAt: occurrenceInstant.addingTimeInterval(300),
            plannedInstant: occurrenceInstant,
            operationID: UUID(),
            createdAt: committedAt
        )
        let event = AdministrationEventRecord(
            occurrenceKey: occurrenceKey,
            scheduleRuleID: sealedRule.id,
            scheduleRevision: sealedRule.revision,
            regimenVersionID: sealed.id,
            regimenItemID: sealedItem.id,
            status: .taken,
            plannedInstant: occurrenceInstant,
            operationID: UUID(),
            createdAt: committedAt
        )
        let eventTime = HistoricalTimeRecord(
            sourceRecordType: "AdministrationEventRecord",
            sourceRecordID: event.id,
            timestamp: try timestamp(
                instant: occurrenceInstant
                    .addingTimeInterval(
                        actualOffset
                    )
            ),
            legacyAssociationID: nil,
            resolvedRegimenVersionID: sealed.id,
            associationState: .resolved
        )
        context.insert(override)
        context.insert(event)
        context.insert(eventTime)
        try insertRevision(
            recordType: "ReminderOverrideRecord",
            recordID: override.id,
            fields: try TodayExecutionDigestV1.reminderOverride(
                override
            ),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "AdministrationEventRecord",
            recordID: event.id,
            fields: try TodayExecutionDigestV1.administrationEvent(
                event
            ),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "HistoricalTimeRecord",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: eventTime.recordKey
            ),
            fields: try CoreFactDigestV1.historicalTime(
                eventTime
            ),
            committedAt: committedAt,
            context: context
        )

        let legacyHrt = HRTProfile(
            startDate: committedAt,
            createdAt: committedAt
        )
        let hrtProfile = HrtJourneyProfileRecord(
            firstEverStartDate: start,
            createdAt: committedAt
        )
        let period = HrtPeriodRecord(
            startDate: start,
            createdAt: committedAt
        )
        context.insert(legacyHrt)
        context.insert(hrtProfile)
        context.insert(period)
        try insertRevision(
            recordType: "HRTProfile",
            recordID: legacyHrt.id,
            fields: try FactDigestV1.profile(legacyHrt),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "HrtJourneyProfileRecord",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: hrtProfile.singletonKey
            ),
            fields: CoreFactDigestV1.journeyProfile(hrtProfile),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "HrtPeriodRecord",
            recordID: period.id,
            fields: try CoreFactDigestV1.period(period),
            committedAt: committedAt,
            context: context
        )
        try context.save()

        return Fixture(
            container: container,
            journeyID: journey.id,
            draftVersionID: draft.id,
            sealedVersionID: sealed.id,
            occurrence: occurrence
        )
    }

    private func performPersistentDeletionFirstPass(
        targetIndex: Int,
        storeURL: URL,
        attachmentRoot: URL
    ) async throws -> PersistentDeletionFirstPass {
        let container = try makeReadyContainer(at: storeURL)
        let fixture = try makeComprehensiveFixture(
            container: container
        )
        let target: DataControlDeletionTarget
        switch targetIndex {
        case 0:
            target = .journeyEntry(fixture.journeyID)
        case 1:
            target = .administrationOccurrence(
                fixture.occurrence
            )
        case 2:
            target = .draftRegimenVersion(
                fixture.draftVersionID
            )
        case 3:
            target = .sealedRegimenVersion(
                fixture.sealedVersionID
            )
        default:
            target = .hrtJourney
        }
        let service = try makeProductionDeletionService(
            fixture: fixture,
            coordinator: AppDataControlCoordinator(
                generationID: generationID
            ),
            attachmentRoot: attachmentRoot,
            manifestSeed: targetIndex
        )
        let cancelledPreview = try await service.preview(
            target: target,
            now: Date(
                timeIntervalSince1970:
                    1_800_201_000
                        + TimeInterval(targetIndex)
            ),
            timeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(
            try ModelContext(container).fetchCount(
                FetchDescriptor<
                    DataControlDeletionTombstoneRecord
                >()
            ),
            0,
            "discarding preview must be a no-op"
        )
        let cancelledOverlay = try await AppReadActor(
            modelContainer: container
        ).dataControlTerminalOverlay()
        XCTAssertEqual(cancelledOverlay, .empty)
        let confirmedPreview = try await service.preview(
            target: target,
            now: Date(
                timeIntervalSince1970:
                    1_800_201_100
                        + TimeInterval(targetIndex)
            ),
            timeZoneIdentifier: "UTC"
        )
        XCTAssertNotEqual(
            cancelledPreview.operationID,
            confirmedPreview.operationID
        )
        let result = try await service.confirm(
            confirmedPreview
        )
        XCTAssertTrue(result.didApply)
        return PersistentDeletionFirstPass(
            target: target,
            preview: confirmedPreview,
            result: result,
            journeyID: fixture.journeyID,
            draftVersionID: fixture.draftVersionID,
            sealedVersionID: fixture.sealedVersionID,
            occurrence: fixture.occurrence
        )
    }

    private func makeProductionDeletionService(
        fixture: Fixture,
        coordinator: AppDataControlCoordinator,
        attachmentRoot: URL,
        manifestSeed: Int
    ) throws -> DataControlDeletionService {
        let metadata = try XCTUnwrap(
            ModelContext(fixture.container).fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let nibble = String(
            manifestSeed % 16,
            radix: 16
        )
        let manifest = DataInventoryManifest(
            generationID: generationID,
            datasetID: metadata.datasetID,
            nextLocalRevision: metadata.nextLocalRevision,
            capturedAt: Date(
                timeIntervalSince1970:
                    1_800_200_500
                        + TimeInterval(manifestSeed)
            ),
            completeness: .complete,
            categories: [],
            unmanagedBoundaries: [],
            stateDigest: String(repeating: nibble, count: 64),
            manifestDigest: String(
                repeating: nibble == "f" ? "e" : "f",
                count: 64
            )
        )
        let storage = AppWriteActor(
            modelContainer: fixture.container
        )
        return DataControlDeletionService(
            generationID: generationID,
            writer: AppDataWriter(
                storage: storage,
                dataControlCoordinator: coordinator,
                verifyStoreProtection: { true },
                onProtectionFailure: {}
            ),
            fileStore: AttachmentFileStore(
                rootURL: attachmentRoot
            ),
            inventoryService:
                FixedDataControlManifestProvider(
                    manifest: manifest
                ),
            notificationClient:
                FixedDataControlNotificationClient(),
            dataControlCoordinator: coordinator,
            recoveryLatch: AttachmentMutationRecoveryLatch(),
            onRecoveryRequired: {}
        )
    }

    private func makeReadyContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        try seedReadyContainer(container)
        return container
    }

    private func makeReadyContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeDataControlContainer(at: storeURL)
        try seedReadyContainer(container)
        return container
    }

    private func seedReadyContainer(
        _ container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.insert(
            DatasetMetadata(
                datasetID: UUID(
                    uuidString:
                        "11111111-2222-3333-4444-555555555555"
                )!,
                createdAt: Date(
                    timeIntervalSince1970: 1_800_100_000
                )
            )
        )
        try context.save()
        _ = try TodayExecutionBackfill.run(
            in: container,
            now: Date(timeIntervalSince1970: 1_800_100_001)
        )
        _ = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11,
            now: Date(timeIntervalSince1970: 1_800_100_002)
        )
        _ = try DataControlBackfill.run(
            in: container,
            source: .bootstrapV12,
            now: Date(timeIntervalSince1970: 1_800_100_003)
        )
    }

    private func makeWritableDataControlContainer(
        legacyLab: LabRecord? = nil
    ) throws
        -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        if let legacyLab {
            let context = ModelContext(container)
            context.insert(legacyLab)
            try context.save()
        }
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        _ = try CountdownLifecycleBackfill.run(
            in: container
        )
        _ = try CountdownIntegrityBackfill.run(
            in: container
        )
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
        _ = try DataControlBackfill.run(
            in: container,
            source: .bootstrapV12
        )
        return container
    }

    private struct WritableRegimenFixture {
        let versionID: UUID
        let itemID: UUID
        let scheduleRuleID: UUID
    }

    private func createSealedRegimen(
        in container: ModelContainer,
        versionID: UUID = UUID(),
        previousVersionID: UUID? = nil,
        effectiveStartDate: CivilDateFact,
        committedAt: Date
    ) async throws -> WritableRegimenFixture {
        let itemID = UUID()
        let ruleID = UUID()
        let writer = AppWriteActor(
            modelContainer: container
        )
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: versionID,
                previousVersionID: previousVersionID,
                code: "TEST-\(effectiveStartDate.month)",
                title: "测试方案",
                effectiveStartDate: effectiveStartDate,
                changeReason: "删除屏障回归",
                items: [
                    RegimenItemInput(
                        id: itemID,
                        displayName: "测试项目",
                        schedule: RegimenScheduleInput(
                            id: ruleID,
                            kind: .dailyTimes,
                            localTimes: "09:00"
                        )
                    )
                ],
                committedAt: committedAt
            )
        )
        let preview = try await writer
            .previewRegimenChange(draftID: versionID)
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: versionID,
                expectedNextLocalRevision:
                    preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt:
                    committedAt.addingTimeInterval(1)
            )
        )
        return WritableRegimenFixture(
            versionID: versionID,
            itemID: itemID,
            scheduleRuleID: ruleID
        )
    }

    private func saveDraft(
        in container: ModelContainer,
        draftID: UUID,
        previousVersionID: UUID,
        effectiveStartDate: CivilDateFact,
        committedAt: Date
    ) async throws {
        try await AppWriteActor(
            modelContainer: container
        ).saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: previousVersionID,
                code: "NEXT",
                title: "下一方案",
                effectiveStartDate: effectiveStartDate,
                changeReason: "触发历史重关联",
                items: [
                    RegimenItemInput(
                        displayName: "下一项目"
                    )
                ],
                committedAt: committedAt
            )
        )
    }

    private func insertRegimenFacts(
        version: RegimenPlanVersionRecord,
        item: RegimenItemRecord,
        rule: ScheduleRuleRecord,
        preference: ReminderPreferenceRecord,
        committedAt: Date,
        context: ModelContext
    ) throws {
        context.insert(version)
        context.insert(item)
        context.insert(rule)
        context.insert(preference)
        try insertRevision(
            recordType: "RegimenPlanVersionRecord",
            recordID: version.id,
            fields: try CoreFactDigestV1.regimen(version),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "RegimenItemRecord",
            recordID: item.id,
            fields: CoreFactDigestV1.item(item),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "ScheduleRuleRecord",
            recordID: rule.id,
            fields: CoreFactDigestV1.schedule(rule),
            committedAt: committedAt,
            context: context
        )
        try insertRevision(
            recordType: "ReminderPreferenceRecord",
            recordID: preference.id,
            fields: TodayExecutionDigestV1.reminderPreference(
                preference
            ),
            committedAt: committedAt,
            context: context
        )
    }

    private func insertJourneyAttachment(
        ownerID: UUID,
        in context: ModelContext
    ) throws -> AttachmentRecord {
        let createdAt = Date(timeIntervalSince1970: 1_800_160_000)
        let attachment = AttachmentRecord(
            ownerType: .journeyEntry,
            ownerID: ownerID,
            relativePath: "Attachments/fixture/file.pdf",
            originalFilename: "file.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 25,
            sha256Hex: String(repeating: "a", count: 64),
            operationID: UUID(),
            createdAt: createdAt
        )
        context.insert(attachment)
        let addCommand = AddAttachmentMetadataCommand(
            operationID: attachment.operationID,
            attachmentID: attachment.id,
            ownerType: .journeyEntry,
            ownerID: ownerID,
            relativePath: attachment.relativePath,
            originalFilename: attachment.originalFilename,
            typeIdentifier: attachment.typeIdentifier,
            byteCount: attachment.byteCount,
            sha256Hex: attachment.sha256Hex,
            committedAt: createdAt
        )
        let receipt = OperationReceiptRecord(
            operationID: attachment.operationID,
            commandDigest: try AttachmentDigestV1.command(
                addCommand
            ),
            resultRecordType: "AttachmentRecord",
            resultRecordID: attachment.id,
            committedAt: createdAt
        )
        context.insert(receipt)
        try insertRevision(
            recordType: "AttachmentRecord",
            recordID: attachment.id,
            fields: try AttachmentDigestV1.record(attachment),
            committedAt: createdAt,
            context: context
        )
        try insertRevision(
            recordType: "OperationReceiptRecord",
            recordID: receipt.operationID,
            fields: TodayExecutionDigestV1.operationReceipt(receipt),
            committedAt: createdAt,
            context: context
        )
        try refreshReceiptLedger(
            updatedAt: createdAt,
            context: context
        )
        return attachment
    }

    private func insertRevision(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        committedAt: Date,
        context: ModelContext
    ) throws {
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let revision = metadata.nextLocalRevision
        context.insert(
            RecordRevision(
                recordKey: recordType + ":"
                    + recordID.uuidString.lowercased(),
                recordType: recordType,
                recordID: recordID,
                datasetID: metadata.datasetID,
                localRevision: revision,
                digestVersion: RecordDigestV1.version,
                digestHex: try RecordDigestV1.sha256Hex(
                    recordType: recordType,
                    recordID: recordID,
                    fields: fields
                ),
                committedAt: committedAt
            )
        )
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
    }

    private func refreshReceiptLedger(
        updatedAt: Date,
        context: ModelContext
    ) throws {
        let ledger = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<OperationReceiptLedgerRecord>()
            ).first
        )
        let receipts = try context.fetch(
            FetchDescriptor<OperationReceiptRecord>()
        )
        ledger.receiptCount = receipts.count
        ledger.receiptSetDigest = try TodayExecutionDigestV1
            .receiptSetDigest(receipts)
        ledger.updatedAt = updatedAt
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let recordKey = "OperationReceiptLedgerRecord:"
            + TodayExecutionDigestV1.receiptLedgerID
                .uuidString.lowercased()
        let revision = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate {
                        $0.recordKey == recordKey
                    }
                )
            ).first
        )
        revision.datasetID = metadata.datasetID
        revision.localRevision = metadata.nextLocalRevision
        revision.digestVersion = RecordDigestV1.version
        revision.digestHex = try RecordDigestV1.sha256Hex(
            recordType: "OperationReceiptLedgerRecord",
            recordID: TodayExecutionDigestV1.receiptLedgerID,
            fields: TodayExecutionDigestV1
                .operationReceiptLedger(ledger)
        )
        revision.committedAt = updatedAt
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = updatedAt
    }

    private func plan(
        _ target: DataControlDeletionTarget,
        attachmentOperations: [UUID: UUID] = [:],
        notifications: [DataControlPendingNotificationEntry] = [],
        context: ModelContext
    ) throws -> DataControlDeletionPlan {
        try DataControlDeletionRepository.plan(
            DataControlDeletionPlanRequest(
                generationID: generationID,
                target: target,
                attachmentDeletionOperationIDs:
                    attachmentOperations,
                pendingNotifications: notifications
            ),
            in: context
        )
    }

    private func sourceTypes(
        _ plan: DataControlDeletionPlan
    ) -> Set<String> {
        let snapshot = DataControlTargetSnapshotManifest.decode(
            plan.impact.targetSnapshotManifest
        )
        return Set(
            snapshot?.sources.compactMap {
                $0.recordKey.split(separator: ":").first.map(
                    String.init
                )
            } ?? []
        )
    }

    private func assertSourceTypes(
        _ plan: DataControlDeletionPlan,
        equal expected: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            sourceTypes(plan),
            expected,
            file: file,
            line: line
        )
    }

    private func timestamp(
        instant: Date
    ) throws -> HistoricalTimestamp {
        try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .second,
            provenance: .userEntered
        )
    }

    private func deletionTimestamp(
        _ interval: TimeInterval
    ) throws -> HistoricalTimestamp {
        let instant = Date(timeIntervalSince1970: interval)
        return try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .second,
            provenance: .userEntered
        )
    }

    private func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "UTC")
        )
        return try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour
                )
            )
        )
    }
}

private actor FixedDataControlManifestProvider:
    DataControlManifestProvider {
    private let value: DataInventoryManifest

    init(manifest: DataInventoryManifest) {
        self.value = manifest
    }

    func manifest() async throws -> DataInventoryManifest {
        value
    }
}

private actor FixedDataControlNotificationClient:
    DataControlNotificationClient {
    private var pending: [String]
    private var delivered: [String]

    init(
        pending: [String] = [],
        delivered: [String] = []
    ) {
        self.pending = pending
        self.delivered = delivered
    }

    func pendingIdentifiers() async throws -> [String] {
        pending
    }

    func deliveredIdentifiers() async throws -> [String] {
        delivered
    }

    func removePendingIdentifiers(
        _ identifiers: [String]
    ) async throws {
        let removed = Set(identifiers)
        pending.removeAll {
            removed.contains($0)
        }
    }

    func snapshot()
        -> (
            pending: [String],
            delivered: [String]
        ) {
        (pending, delivered)
    }
}

private actor DataControlReconciliationRecorder {
    private var invocationCount = 0

    func record() {
        invocationCount += 1
    }

    func count() -> Int {
        invocationCount
    }
}
