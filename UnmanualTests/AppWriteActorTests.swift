import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class AppWriteActorTests: XCTestCase {
    func testRegimenDraftRejectsUnencodableCommittedAtWithoutReservingRevision() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let revisionBefore = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        ).nextLocalRevision
        let recordRevisionCountBefore = try context.fetchCount(
            FetchDescriptor<RecordRevision>()
        )

        do {
            try await AppWriteActor(modelContainer: container).saveRegimenDraft(
                SaveRegimenDraftCommand(
                    recordID: UUID(),
                    previousVersionID: nil,
                    code: "R-INVALID-TIME",
                    title: "不得保存",
                    effectiveStartDate: try CivilDateFact(year: 2026, month: 7, day: 22),
                    changeReason: "验证写入边界",
                    items: [RegimenItemInput(displayName: "测试项目")],
                    committedAt: Date(timeIntervalSince1970: 1e20)
                )
            )
            XCTFail("不可编码的 committedAt 必须在预留 revision 前失败")
        } catch let error as RecordDigestV1.EncodingError {
            XCTAssertEqual(error, .timestampOutOfRange)
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenPlanVersionRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenItemRecord>()), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<RecordRevision>()),
            recordRevisionCountBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).nextLocalRevision,
            revisionBefore
        )
    }

    func testRegimenSealRejectsUnencodableCommittedAtWithoutChangingDraftOrRevision() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let writer = AppWriteActor(modelContainer: container)
        let draftID = UUID()
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: nil,
                code: "R-DRAFT",
                title: "仍应保持草稿",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 7, day: 22),
                changeReason: "验证封存边界",
                items: [RegimenItemInput(displayName: "测试项目")],
                committedAt: Date(timeIntervalSince1970: 1_774_156_800)
            )
        )
        let preview = try await writer.previewRegimenChange(draftID: draftID)
        let context = ModelContext(container)
        let revisionBefore = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        ).nextLocalRevision
        let recordRevisionCountBefore = try context.fetchCount(
            FetchDescriptor<RecordRevision>()
        )

        do {
            try await writer.sealRegimenDraft(
                SealRegimenDraftCommand(
                    draftID: draftID,
                    expectedNextLocalRevision: preview.expectedNextLocalRevision,
                    draftDigest: preview.draftDigest,
                    committedAt: Date(timeIntervalSince1970: .infinity)
                )
            )
            XCTFail("不可编码的 committedAt 不得封存草稿")
        } catch let error as RecordDigestV1.EncodingError {
            XCTAssertEqual(error, .timestampOutOfRange)
        }

        let storedDraft = try XCTUnwrap(
            context.fetch(FetchDescriptor<RegimenPlanVersionRecord>()).first {
                $0.id == draftID
            }
        )
        XCTAssertEqual(storedDraft.editState, .draft)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<RecordRevision>()),
            recordRevisionCountBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).nextLocalRevision,
            revisionBefore
        )
    }

    func testSetStartDateWritesCanonicalCivilFactsInSameRevision() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let writer = AppWriteActor(modelContainer: container)
        let profileID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
        let instant = Date(timeIntervalSince1970: 1_767_225_600)

        try await writer.setStartDate(
            SetStartDateCommand(
                recordID: profileID,
                startDate: instant,
                timeZoneIdentifier: "America/Chicago",
                committedAt: instant
            )
        )

        let context = ModelContext(container)
        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<HrtJourneyProfileRecord>()).first)
        let period = try XCTUnwrap(context.fetch(FetchDescriptor<HrtPeriodRecord>()).first)
        XCTAssertEqual(profile.firstEverStartDate?.iso8601, "2025-12-31")
        XCTAssertEqual(period.startDate?.iso8601, "2025-12-31")
        let semanticRevisions = try context.fetch(FetchDescriptor<RecordRevision>()).filter {
            ["HRTProfile", "HrtJourneyProfileRecord", "HrtPeriodRecord"].contains($0.recordType)
        }
        XCTAssertEqual(semanticRevisions.count, 3)
        XCTAssertEqual(Set(semanticRevisions.map(\.localRevision)).count, 1)
        let today = try await AppReadActor(modelContainer: container).todaySnapshot()
        let displayed = try XCTUnwrap(today.profile?.startDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: displayed).year, 2025)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: displayed).month, 12)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: displayed).day, 31)
    }

    func testHistoricalWriteFreezesLocalTimeAndDerivesCanonicalRegimenAssociation() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let regimenID = UUID(uuidString: "32000000-0000-0000-0000-000000000001")!
        context.insert(
            RegimenPlanVersionRecord(
                id: regimenID,
                code: "R-01",
                title: "已封存方案",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
                editState: .sealed
            )
        )
        try context.save()

        let writer = AppWriteActor(modelContainer: container)
        let entryID = UUID(uuidString: "32000000-0000-0000-0000-000000000002")!
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "一次记录",
                kind: .change,
                occurredAt: Date(timeIntervalSince1970: 1_769_040_000),
                regimenVersionID: nil,
                timeZoneIdentifier: "America/Chicago",
                committedAt: Date(timeIntervalSince1970: 1_769_040_001)
            )
        )

        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<JourneyEntry>()).first)
        let historical = try XCTUnwrap(context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first)
        XCTAssertEqual(entry.regimenVersionID, regimenID)
        XCTAssertEqual(historical.timeZoneIdentifier, "America/Chicago")
        XCTAssertEqual(historical.resolvedRegimenVersionID, regimenID)
        XCTAssertEqual(historical.associationStateRawValue, HistoricalAssociationState.resolved.rawValue)
        XCTAssertEqual(historical.provenanceRawValue, HistoricalTimestampProvenance.userEntered.rawValue)
    }

    func testMissingRuntimeAssociationCreatesIssueAndSealResolvesIt() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let writer = AppWriteActor(modelContainer: container)
        let entryID = UUID(uuidString: "32000000-0000-0000-0000-000000000010")!
        let occurredAt = Date(timeIntervalSince1970: 1_769_040_000)

        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "等待方案关联",
                kind: .change,
                occurredAt: occurredAt,
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC"
            )
        )

        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MigrationIssue>()).filter {
                $0.kind == .missingCanonicalRegimenAssociation && $0.recordID == entryID
            }.count,
            1
        )

        let draftID = UUID(uuidString: "32000000-0000-0000-0000-000000000011")!
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: nil,
                code: "R-01",
                title: "补录方案",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
                changeReason: "补录",
                items: [RegimenItemInput(displayName: "原始记录")],
                committedAt: occurredAt.addingTimeInterval(1)
            )
        )
        let preview = try await writer.previewRegimenChange(draftID: draftID)
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: draftID,
                expectedNextLocalRevision: preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt: occurredAt.addingTimeInterval(2)
            )
        )

        let historical = try XCTUnwrap(context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first)
        XCTAssertEqual(historical.resolvedRegimenVersionID, draftID)
        XCTAssertEqual(historical.associationStateRawValue, HistoricalAssociationState.resolved.rawValue)
        XCTAssertFalse(try context.fetch(FetchDescriptor<MigrationIssue>()).contains {
            [.missingCanonicalRegimenAssociation, .ambiguousCanonicalRegimenAssociation].contains($0.kind)
                && $0.recordID == entryID
        })

        let page = try await AppReadActor(modelContainer: container).journeyPage(after: nil, limit: 10)
        XCTAssertEqual(page.entries.first?.regimenVersionID, draftID)
        XCTAssertEqual(page.regimenCodes[draftID], "R-01")
    }

    func testPreviewTokenRejectsInterveningWriteAndThenReassociatesAffectedHistory() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let priorID = UUID(uuidString: "34000000-0000-0000-0000-000000000001")!
        context.insert(
            RegimenPlanVersionRecord(
                id: priorID,
                code: "R-01",
                title: "旧方案",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
                editState: .sealed
            )
        )
        context.insert(
            RegimenItemRecord(
                regimenVersionID: priorID,
                sortOrder: 0,
                displayName: "旧项目"
            )
        )
        try context.save()
        let writer = AppWriteActor(modelContainer: container)
        let entryID = UUID(uuidString: "34000000-0000-0000-0000-000000000002")!
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "方案切换后的记录",
                kind: .change,
                occurredAt: Date(timeIntervalSince1970: 1_769_040_000),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC"
            )
        )

        let draftID = UUID(uuidString: "34000000-0000-0000-0000-000000000003")!
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: priorID,
                code: "R-02",
                title: "新方案",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 20),
                changeReason: "更正历史切换日",
                items: [RegimenItemInput(displayName: "自定义项目")],
                committedAt: Date(timeIntervalSince1970: 1_769_040_010)
            )
        )
        let stalePreview = try await writer.previewRegimenChange(draftID: draftID)
        XCTAssertEqual(stalePreview.affectedJourneyIDs, [entryID])
        XCTAssertEqual(stalePreview.affectedRecords.map(\.id), [entryID])
        XCTAssertEqual(stalePreview.affectedRecords.first?.localDate.iso8601, "2026-01-22")
        XCTAssertEqual(stalePreview.affectedRecords.first?.summary, "方案切换后的记录")
        XCTAssertEqual(stalePreview.affectedRecords.first?.beforeRegimenVersionID, priorID)
        XCTAssertEqual(stalePreview.affectedRecords.first?.afterRegimenVersionID, draftID)
        XCTAssertEqual(stalePreview.before?.code, "R-01")
        XCTAssertEqual(stalePreview.before?.items, ["旧项目"])
        XCTAssertEqual(stalePreview.after.code, "R-02")
        XCTAssertEqual(stalePreview.after.items, ["自定义项目"])

        try await writer.saveCountdown(
            SaveCountdownCommand(
                title: "推进修订号",
                gentleTitle: nil,
                targetDate: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        do {
            try await writer.sealRegimenDraft(
                SealRegimenDraftCommand(
                    draftID: draftID,
                    expectedNextLocalRevision: stalePreview.expectedNextLocalRevision,
                    draftDigest: stalePreview.draftDigest,
                    committedAt: Date(timeIntervalSince1970: 1_769_040_020)
                )
            )
            XCTFail("Expected stale preview token")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .staleRecord)
        }

        let freshPreview = try await writer.previewRegimenChange(draftID: draftID)
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: draftID,
                expectedNextLocalRevision: freshPreview.expectedNextLocalRevision,
                draftDigest: freshPreview.draftDigest,
                committedAt: Date(timeIntervalSince1970: 1_769_040_021)
            )
        )
        let historical = try XCTUnwrap(context.fetch(FetchDescriptor<HistoricalTimeRecord>()).first)
        XCTAssertEqual(historical.resolvedRegimenVersionID, draftID)
    }

    func testDraftItemsPersistAndSealWithoutOverwritingPriorSealedVersion() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        let writer = AppWriteActor(modelContainer: container)
        let draftID = UUID(uuidString: "33000000-0000-0000-0000-000000000001")!
        let itemID = UUID(uuidString: "33000000-0000-0000-0000-000000000002")!
        let command = SaveRegimenDraftCommand(
            recordID: draftID,
            previousVersionID: nil,
            code: "R-01",
            title: "当前记录",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 7, day: 21),
            changeReason: "首次建立",
            items: [
                RegimenItemInput(
                    id: itemID,
                    displayName: "药盒原文",
                    genericName: "",
                    dosageForm: "片剂",
                    route: "口服",
                    doseOriginal: "一片",
                    unitOriginal: "片",
                    productSnapshot: "用户照药盒录入"
                )
            ],
            committedAt: Date(timeIntervalSince1970: 1_769_904_000)
        )

        try await writer.saveRegimenDraft(command)
        let preview = try await writer.previewRegimenChange(draftID: draftID)
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: draftID,
                expectedNextLocalRevision: preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt: Date(timeIntervalSince1970: 1_769_904_001)
            )
        )

        let context = ModelContext(container)
        let version = try XCTUnwrap(
            context.fetch(FetchDescriptor<RegimenPlanVersionRecord>()).first {
                $0.id == draftID
            }
        )
        let item = try XCTUnwrap(
            context.fetch(FetchDescriptor<RegimenItemRecord>()).first {
                $0.id == itemID
            }
        )
        XCTAssertEqual(version.editState, .sealed)
        XCTAssertEqual(item.regimenVersionID, draftID)
        XCTAssertEqual(item.doseOriginal, "一片")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenVersion>()), 0)
    }

    func testDraftRejectsItemIdentityAlreadyOwnedByAnotherVersion() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let priorID = UUID(uuidString: "35000000-0000-0000-0000-000000000001")!
        let sharedItemID = UUID(uuidString: "35000000-0000-0000-0000-000000000002")!
        context.insert(
            RegimenPlanVersionRecord(
                id: priorID,
                code: "R-01",
                title: "已封存方案",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
                editState: .sealed
            )
        )
        context.insert(
            RegimenItemRecord(
                id: sharedItemID,
                regimenVersionID: priorID,
                sortOrder: 0,
                displayName: "旧版本项目"
            )
        )
        try context.save()

        let writer = AppWriteActor(modelContainer: container)
        let revisionBefore = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        ).nextLocalRevision
        do {
            try await writer.saveRegimenDraft(
                SaveRegimenDraftCommand(
                    recordID: UUID(uuidString: "35000000-0000-0000-0000-000000000003")!,
                    previousVersionID: priorID,
                    code: "R-02",
                    title: "新方案",
                    effectiveStartDate: try CivilDateFact(year: 2026, month: 2, day: 1),
                    changeReason: "测试身份边界",
                    items: [RegimenItemInput(id: sharedItemID, displayName: "复制项目")],
                    committedAt: Date(timeIntervalSince1970: 1_770_000_000)
                )
            )
            XCTFail("Expected cross-version item identity rejection")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .invalidInput)
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenPlanVersionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenItemRecord>()), 1)
        XCTAssertEqual(
            try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).nextLocalRevision,
            revisionBefore
        )
    }

    func testHistoricalInsertRelinksImmediateSuccessorInSealTransaction() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let firstID = UUID(uuidString: "36000000-0000-0000-0000-000000000001")!
        let lastID = UUID(uuidString: "36000000-0000-0000-0000-000000000003")!
        context.insert(
            RegimenPlanVersionRecord(
                id: firstID,
                code: "R-01",
                title: "第一版",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
                editState: .sealed
            )
        )
        context.insert(
            RegimenPlanVersionRecord(
                id: lastID,
                code: "R-03",
                title: "第三版",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 3, day: 1),
                previousVersionID: firstID,
                editState: .sealed
            )
        )
        try context.save()

        let writer = AppWriteActor(modelContainer: container)
        let middleID = UUID(uuidString: "36000000-0000-0000-0000-000000000002")!
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: middleID,
                previousVersionID: firstID,
                code: "R-02",
                title: "第二版",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 2, day: 1),
                changeReason: "补录",
                items: [RegimenItemInput(displayName: "项目")],
                committedAt: Date(timeIntervalSince1970: 1_770_000_000)
            )
        )
        let preview = try await writer.previewRegimenChange(draftID: middleID)
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: middleID,
                expectedNextLocalRevision: preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt: Date(timeIntervalSince1970: 1_770_000_001)
            )
        )

        let successor = try XCTUnwrap(
            context.fetch(FetchDescriptor<RegimenPlanVersionRecord>()).first { $0.id == lastID }
        )
        XCTAssertEqual(successor.previousVersionID, middleID)
        let sealedRevision = try XCTUnwrap(
            context.fetch(FetchDescriptor<RecordRevision>()).first {
                $0.recordType == "RegimenPlanVersionRecord" && $0.recordID == middleID
            }
        )
        let successorRevision = try XCTUnwrap(
            context.fetch(FetchDescriptor<RecordRevision>()).first {
                $0.recordType == "RegimenPlanVersionRecord" && $0.recordID == lastID
            }
        )
        XCTAssertEqual(successorRevision.localRevision, sealedRevision.localRevision)
    }

    func testHistoricalInsertRelinksFutureDraftInSealTransaction() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let firstID = UUID(uuidString: "36100000-0000-0000-0000-000000000001")!
        context.insert(
            RegimenPlanVersionRecord(
                id: firstID,
                code: "R-01",
                title: "第一版",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
                editState: .sealed
            )
        )
        try context.save()

        let writer = AppWriteActor(modelContainer: container)
        let futureDraftID = UUID(uuidString: "36100000-0000-0000-0000-000000000003")!
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: futureDraftID,
                previousVersionID: firstID,
                code: "R-03-DRAFT",
                title: "未来草稿",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 3, day: 1),
                changeReason: "预先规划",
                items: [RegimenItemInput(displayName: "未来项目")],
                committedAt: Date(timeIntervalSince1970: 1_770_000_000)
            )
        )

        let middleID = UUID(uuidString: "36100000-0000-0000-0000-000000000002")!
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: middleID,
                previousVersionID: firstID,
                code: "R-02",
                title: "第二版",
                effectiveStartDate: try CivilDateFact(year: 2026, month: 2, day: 1),
                changeReason: "补录",
                items: [RegimenItemInput(displayName: "当前项目")],
                committedAt: Date(timeIntervalSince1970: 1_770_000_001)
            )
        )
        let preview = try await writer.previewRegimenChange(draftID: middleID)
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: middleID,
                expectedNextLocalRevision: preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt: Date(timeIntervalSince1970: 1_770_000_002)
            )
        )

        let futureDraft = try XCTUnwrap(
            context.fetch(FetchDescriptor<RegimenPlanVersionRecord>()).first {
                $0.id == futureDraftID
            }
        )
        XCTAssertEqual(futureDraft.previousVersionID, middleID)
        XCTAssertNoThrow(
            try CoreRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testSingleRecordWriteCommitsBusinessFactAndRevisionTogether() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let writer = AppWriteActor(modelContainer: container)
        let recordID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)

        try await writer.setStartDate(
            SetStartDateCommand(recordID: recordID, startDate: startDate, committedAt: startDate)
        )

        let context = ModelContext(container)
        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<HRTProfile>()).first)
        let revision = try XCTUnwrap(
            context.fetch(FetchDescriptor<RecordRevision>()).first {
                $0.recordKey == "HRTProfile:" + recordID.uuidString.lowercased()
            }
        )
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
        XCTAssertEqual(profile.id, recordID)
        XCTAssertEqual(profile.startDate, startDate)
        XCTAssertEqual(revision.recordKey, "HRTProfile:" + recordID.uuidString.lowercased())
        XCTAssertEqual(revision.localRevision, 1)
        XCTAssertFalse(revision.digestHex.isEmpty)
        XCTAssertEqual(metadata.nextLocalRevision, 2)
    }

    func testFailureAfterReservationRollsBackBusinessFactsAndLeavesRevisionGap() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let writer = AppWriteActor(modelContainer: container)

        do {
            try await writer.setStartDate(
                SetStartDateCommand(
                    recordID: UUID(),
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    committedAt: Date(timeIntervalSince1970: 1_700_000_001)
                ),
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("Expected injected failure")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 0)
        XCTAssertEqual(
            try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).nextLocalRevision,
            2
        )
    }

    func testRevisionAllocatorAtMaximumFailsWithoutWritingBusinessFacts() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
        metadata.nextLocalRevision = Int64.max
        try context.save()
        let writer = AppWriteActor(modelContainer: container)

        do {
            try await writer.setStartDate(
                SetStartDateCommand(
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    committedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            )
            XCTFail("Expected exhausted revision allocator to fail")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .revisionExhausted)
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 0)
        XCTAssertEqual(metadata.nextLocalRevision, Int64.max)
    }

    func testLabBatchUsesOneRevisionForEveryChangedRecord() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let writer = AppWriteActor(modelContainer: container)
        let sampledAt = Date(timeIntervalSince1970: 1_700_000_000)

        let count = try await writer.saveLabImport(
            SaveLabImportCommand(
                entries: [
                    LabImportEntry(itemName: "雌二醇", itemCode: "E2", rawValue: "123", unit: "pmol/L"),
                    LabImportEntry(itemName: "睾酮", itemCode: "T", rawValue: "1.2", unit: "nmol/L")
                ],
                sampledAt: sampledAt,
                regimenVersionID: nil,
                committedAt: sampledAt
            )
        )

        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<RecordRevision>())
        let expectedSampledAt = Date(
            timeIntervalSinceReferenceDate:
                floor(sampledAt.timeIntervalSinceReferenceDate / 60) * 60
        )
        let savedLabs = try context.fetch(FetchDescriptor<LabRecord>())
        let historicalTimes = try context.fetch(FetchDescriptor<HistoricalTimeRecord>())
        XCTAssertEqual(count, 2)
        XCTAssertEqual(savedLabs.count, 2)
        XCTAssertTrue(savedLabs.allSatisfy { $0.sampledAt == expectedSampledAt })
        XCTAssertEqual(Set(revisions.map(\.localRevision)), [1, 2])
        XCTAssertEqual(revisions.filter { $0.localRevision == 2 }.count, 4)
        XCTAssertEqual(revisions.count, 5)
        XCTAssertTrue(historicalTimes.allSatisfy {
            $0.precisionRawValue == HistoricalTimestampPrecision.minute.rawValue
                && $0.instant == expectedSampledAt
                && $0.localSecond == 0
                && $0.localNanosecond == 0
        })
        XCTAssertEqual(
            try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).nextLocalRevision,
            3
        )
    }

    func testRegimenWriteRejectsMultipleLegacyActiveRecordsWithoutChangingThem() async throws {
        let container = try AppModelContainerFactory.makeInMemoryBridgeContainer()
        _ = try LegacyV1Backfill.run(in: container)
        let context = ModelContext(container)
        let first = RegimenVersion(code: "A", title: "A", startedAt: Date(timeIntervalSince1970: 100))
        let second = RegimenVersion(code: "B", title: "B", startedAt: Date(timeIntervalSince1970: 200))
        context.insert(first)
        context.insert(second)
        try context.save()
        let writer = AppWriteActor(modelContainer: container)

        do {
            try await writer.createRegimenVersion(
                CreateRegimenVersionCommand(
                    activeRegimenID: first.id,
                    code: "C",
                    title: "C",
                    startedAt: Date(timeIntervalSince1970: 300),
                    note: ""
                )
            )
            XCTFail("Expected anomalous active set to be rejected")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .staleRecord)
        }

        let activeCount = try context.fetchCount(
            FetchDescriptor<RegimenVersion>(predicate: #Predicate { $0.endedAt == nil })
        )
        XCTAssertEqual(activeCount, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 0)
    }
}
