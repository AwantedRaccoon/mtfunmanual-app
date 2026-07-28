import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Unmanual

@MainActor
final class ParentRecordLifecycleTests: XCTestCase {
    func testAttachmentActionsAreBlockedDuringParentMutationPreparation() {
        XCTAssertFalse(
            ParentRecordAttachmentActionGate.allowsAction(
                isPreparingParentMutation: true,
                isDeletingAttachment: false,
                isPreviewRequestInFlight: false,
                presentedAttachmentID: nil
            )
        )
        XCTAssertTrue(
            ParentRecordAttachmentActionGate.allowsAction(
                isPreparingParentMutation: false,
                isDeletingAttachment: false,
                isPreviewRequestInFlight: false,
                presentedAttachmentID: nil
            )
        )
        XCTAssertFalse(
            ParentRecordAttachmentActionGate.allowsAction(
                isPreparingParentMutation: false,
                isDeletingAttachment: true,
                isPreviewRequestInFlight: false,
                presentedAttachmentID: nil
            )
        )
        XCTAssertFalse(
            ParentRecordAttachmentActionGate.allowsAction(
                isPreparingParentMutation: false,
                isDeletingAttachment: false,
                isPreviewRequestInFlight: true,
                presentedAttachmentID: nil
            )
        )
        XCTAssertFalse(
            ParentRecordAttachmentActionGate.allowsAction(
                isPreparingParentMutation: false,
                isDeletingAttachment: false,
                isPreviewRequestInFlight: false,
                presentedAttachmentID: UUID()
            )
        )
    }

    func testCorrectionDraftPreservesNilAndTimestampMetadataUntilEdited()
        throws
    {
        let result = LabResultSnapshot(
            id: UUID(),
            itemDefinitionID: UUID(),
            itemDefinitionKind: .custom,
            bundledStableID: nil,
            itemNameSnapshot: "雌二醇",
            itemCodeSnapshot: "E2",
            rawValueOriginal: "100",
            comparator: nil,
            canonicalDecimalString: "100",
            unitOriginal: "pmol/L",
            referenceRangeOriginal: nil,
            assayOrVariantOriginal: nil
        )
        var draft = LabCorrectionResultDraft(result)
        XCTAssertNil(draft.reference.persistedValue)
        XCTAssertNil(draft.variant.persistedValue)

        let instant = Date(timeIntervalSince1970: 100.25)
        let baseline = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .subsecond,
            provenance: .migrationAssumed
        )
        XCTAssertEqual(
            try correctionTimestamp(
                baseline: baseline,
                selectedInstant: instant
            ),
            baseline
        )

        draft.reference.replaceWithUserInput("")
        XCTAssertEqual(draft.reference.persistedValue, "")
        let edited = try correctionTimestamp(
            baseline: baseline,
            selectedInstant: instant.addingTimeInterval(60)
        )
        XCTAssertEqual(edited.precision, .minute)
        XCTAssertEqual(edited.provenance, .userEntered)
    }

    func testLabCorrectionReviewNamesAddedRemovedReorderedAndOptionalChanges() {
        let first = labDraft(
            id: UUID(),
            name: "雌二醇",
            reference: nil
        )
        let second = labDraft(
            id: UUID(),
            name: "睾酮",
            reference: "原区间"
        )
        var changedFirst = first
        changedFirst.reference.replaceWithUserInput("")
        let added = labDraft(
            id: UUID(),
            name: "泌乳素",
            reference: nil
        )

        let changes = labCorrectionResultChanges(
            baseline: [first, second],
            current: [changedFirst, added]
        )

        XCTAssertTrue(changes.contains { $0.contains("移除结果：睾酮") })
        XCTAssertTrue(changes.contains { $0.contains("新增结果：泌乳素") })
        XCTAssertTrue(
            changes.contains {
                $0.contains("参考区间 未提供")
                    && $0.contains("参考区间 （空）")
            }
        )

        let reordered = labCorrectionResultChanges(
            baseline: [first, second],
            current: [second, first]
        )
        let firstLabel = LabDefinitionIdentityPresentation.label(
            id: first.itemDefinitionID,
            displayName: first.itemName,
            code: first.itemCode
        )
        let secondLabel = LabDefinitionIdentityPresentation.label(
            id: second.itemDefinitionID,
            displayName: second.itemName,
            code: second.itemCode
        )
        XCTAssertTrue(
            reordered.contains {
                $0 == "结果顺序：\(firstLabel)、\(secondLabel)"
                    + " → \(secondLabel)、\(firstLabel)"
            }
        )

        var codeChanged = first
        codeChanged.itemCode = "E2-ALT"
        let codeChanges = labCorrectionResultChanges(
            baseline: [first],
            current: [codeChanged]
        )
        XCTAssertTrue(
            codeChanges.contains {
                $0.contains("项目代码 雌二醇")
                    && $0.contains("项目代码 E2-ALT")
            }
        )
    }

    func testDuplicateNameAndCodeDefinitionsStayDistinctInPickersAndReview() {
        let firstDefinitionID = UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!
        let secondDefinitionID = UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"
        )!
        let firstLabel = LabDefinitionIdentityPresentation.label(
            id: firstDefinitionID,
            displayName: "雌二醇",
            code: "E2"
        )
        let secondLabel = LabDefinitionIdentityPresentation.label(
            id: secondDefinitionID,
            displayName: "雌二醇",
            code: "E2"
        )
        XCTAssertNotEqual(firstLabel, secondLabel)
        XCTAssertTrue(firstLabel.contains("11111111"))
        XCTAssertTrue(secondLabel.contains("22222222"))

        let resultID = UUID()
        let first = LabCorrectionResultDraft(
            LabResultSnapshot(
                id: resultID,
                itemDefinitionID: firstDefinitionID,
                itemDefinitionKind: .custom,
                bundledStableID: nil,
                itemNameSnapshot: "雌二醇",
                itemCodeSnapshot: "E2",
                rawValueOriginal: "1",
                comparator: nil,
                canonicalDecimalString: "1",
                unitOriginal: "pmol/L",
                referenceRangeOriginal: nil,
                assayOrVariantOriginal: nil
            )
        )
        let second = LabCorrectionResultDraft(
            LabResultSnapshot(
                id: resultID,
                itemDefinitionID: secondDefinitionID,
                itemDefinitionKind: .custom,
                bundledStableID: nil,
                itemNameSnapshot: "雌二醇",
                itemCodeSnapshot: "E2",
                rawValueOriginal: "1",
                comparator: nil,
                canonicalDecimalString: "1",
                unitOriginal: "pmol/L",
                referenceRangeOriginal: nil,
                assayOrVariantOriginal: nil
            )
        )

        XCTAssertNotEqual(first.auditText, second.auditText)
        let changes = labCorrectionResultChanges(
            baseline: [first],
            current: [second]
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].contains("11111111"))
        XCTAssertTrue(changes[0].contains("22222222"))
    }

    func testDefinitionIdentityLabelsDoNotCollideForSharedUUIDPrefix() {
        let firstID = UUID(
            uuidString: "89000000-0000-0000-0000-000000000001"
        )!
        let secondID = UUID(
            uuidString: "89000000-0000-0000-0000-000000000002"
        )!

        let firstLabel = LabDefinitionIdentityPresentation.label(
            id: firstID,
            displayName: "雌二醇",
            code: "E2"
        )
        let secondLabel = LabDefinitionIdentityPresentation.label(
            id: secondID,
            displayName: "雌二醇",
            code: "E2"
        )

        XCTAssertNotEqual(firstLabel, secondLabel)
        XCTAssertTrue(firstLabel.contains(firstID.uuidString))
        XCTAssertTrue(secondLabel.contains(secondID.uuidString))
    }

    func testLabCorrectionResultMovePreservesIdentityAndBounds() {
        let first = labDraft(
            id: UUID(),
            name: "雌二醇",
            reference: nil
        )
        let second = labDraft(
            id: UUID(),
            name: "睾酮",
            reference: nil
        )
        let third = labDraft(
            id: UUID(),
            name: "泌乳素",
            reference: nil
        )
        var results = [first, second, third]

        XCTAssertFalse(
            moveLabCorrectionResult(
                in: &results,
                id: first.id,
                direction: .up
            )
        )
        XCTAssertTrue(
            moveLabCorrectionResult(
                in: &results,
                id: first.id,
                direction: .down
            )
        )
        XCTAssertEqual(
            results.map(\.id),
            [second.id, first.id, third.id]
        )
        XCTAssertTrue(
            moveLabCorrectionResult(
                in: &results,
                id: third.id,
                direction: .up
            )
        )
        XCTAssertEqual(
            results.map(\.id),
            [second.id, third.id, first.id]
        )
        XCTAssertFalse(
            moveLabCorrectionResult(
                in: &results,
                id: first.id,
                direction: .down
            )
        )
    }

    func testParentDetailHeaderUsesEffectiveLeafAndHidesDeletedRouteText()
        throws
    {
        let currentTimestamp = try timestamp(instant: 100)
        let route = PersonalTimelineItem(
            id: UUID(),
            kind: .statusObservation,
            title: "旧敏感指标",
            detail: "旧级别",
            timestamp: currentTimestamp,
            dateOnly: nil,
            localDate: currentTimestamp.localDate
        )
        let current = StatusObservationSnapshot(
            id: route.id,
            metricDefinitionID: UUID(),
            metricNameSnapshot: "当前指标",
            ordinalLevel: 3,
            note: "",
            timestamp: currentTimestamp,
            regimenVersionID: nil,
            associationState: .missing
        )
        XCTAssertEqual(
            personalTimelineDetailHeader(
                item: route,
                lab: nil,
                status: current,
                recordWasDeleted: false
            ),
            PersonalTimelineDetailHeader(
                title: "当前指标",
                detail: "第 3 级，共 4 级"
            )
        )
        let deleted = personalTimelineDetailHeader(
            item: route,
            lab: nil,
            status: nil,
            recordWasDeleted: true
        )
        XCTAssertEqual(deleted.title, "记录已删除")
        XCTAssertFalse(deleted.title.contains(route.title))
        XCTAssertFalse(deleted.detail.contains(route.detail))

        let gentleDeleted = personalTimelineDetailHeader(
            item: route,
            lab: nil,
            status: nil,
            recordWasDeleted: true,
            gentleModeEnabled: true
        )
        XCTAssertEqual(
            gentleDeleted.detail,
            "这条检查或状态记录已经从正常视图移除。"
        )
        XCTAssertFalse(gentleDeleted.detail.contains("化验"))
    }

    func testCorrectionCapacityReservesTerminalDeletionSlot() {
        let maximum = ParentRecordLifecycleCapacity
            .maximumCorrectionsPerParent
        XCTAssertTrue(
            ParentRecordLifecycleCapacity.canAppendCorrection(
                toEventCount: maximum
            )
        )
        XCTAssertFalse(
            ParentRecordLifecycleCapacity.canAppendCorrection(
                toEventCount: maximum + 1
            )
        )
        XCTAssertEqual(
            ParentRecordLifecycleCapacity.maximumEventCount(for: .active),
            maximum + 1
        )
        XCTAssertEqual(
            ParentRecordLifecycleCapacity.maximumEventCount(for: .deleted),
            maximum + 2
        )
    }

    func testParentDeletionAttachmentPresentationsExposeFrozenIdentity()
    {
        let ownerID = UUID(
            uuidString:
                "93000000-0000-0000-0000-000000000001"
        )!
        let first = AttachmentSnapshot(
            id: UUID(
                uuidString:
                    "93000000-0000-0000-0000-000000000101"
            )!,
            ownerType: .labSample,
            ownerID: ownerID,
            relativePath: "Attachments/opaque-a",
            originalFilename: "化验单.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 2_048,
            sha256Hex: String(repeating: "a", count: 64),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let second = AttachmentSnapshot(
            id: UUID(
                uuidString:
                    "93000000-0000-0000-0000-000000000102"
            )!,
            ownerType: .labSample,
            ownerID: ownerID,
            relativePath: "Attachments/opaque-b",
            originalFilename:
                "第二份很长的原始检查附件名称.png",
            typeIdentifier: "public.png",
            byteCount: 4_096,
            sha256Hex: String(repeating: "b", count: 64),
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let rows = parentRecordDeletionAttachmentPresentations(
            [first, second]
        )

        XCTAssertEqual(rows.map(\.id), [first.id, second.id])
        XCTAssertEqual(rows.map(\.ordinal), [1, 2])
        XCTAssertEqual(
            rows.map(\.originalFilename),
            [first.originalFilename, second.originalFilename]
        )
        XCTAssertEqual(rows.map(\.byteCount), [2_048, 4_096])
        XCTAssertEqual(
            rows.map(\.typeIdentifier),
            ["com.adobe.pdf", "public.png"]
        )
        XCTAssertEqual(
            rows.map(\.fileTypeLabel),
            ["文件类型：PDF", "文件类型：PNG"]
        )
        for row in rows {
            XCTAssertTrue(
                row.accessibilityLabel.contains(
                    "附件 \(row.ordinal)"
                )
            )
            XCTAssertTrue(
                row.accessibilityLabel.contains(
                    row.originalFilename
                )
            )
            XCTAssertTrue(
                row.accessibilityLabel.contains(
                    row.formattedByteCount
                )
            )
            XCTAssertTrue(
                row.accessibilityLabel.contains(
                    row.fileTypeLabel
                )
            )
        }
    }

    func testNewLabCreatesRootAndTwoCorrectionsPreserveBaseFacts()
        async throws {
        let container = try preparedV10Container()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let sampleID = UUID()
        let definitionID = UUID()
        let originalResultID = UUID()
        let originalTimestamp = try timestamp(instant: 100)
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: originalTimestamp,
                specimenOriginal: "血清 ",
                contextNote: "原始",
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: definitionID,
                        displayName: "雌二醇",
                        code: "E2"
                    )
                ],
                results: [
                    LabResultInput(
                        id: originalResultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "＜ 100 ",
                        unitOriginal: "pg/mL",
                        assayOrVariantOriginal: nil
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let context = ModelContext(container)
        let baseBefore = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<LabSampleRecord>(
                    predicate: #Predicate { $0.id == sampleID }
                )
            ).first
        )
        let baseSpecimen = baseBefore.specimenOriginal
        let baseResultBefore = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<LabResultRecord>(
                    predicate: #Predicate {
                        $0.id == originalResultID
                    }
                )
            ).first
        )
        let baseRaw = baseResultBefore.rawValueOriginal
        let baseTimeBefore = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<HistoricalTimeRecord>(
                    predicate: #Predicate {
                        $0.sourceRecordType == "LabSampleRecord"
                            && $0.sourceRecordID == sampleID
                    }
                )
            ).first
        )
        let baseInstant = baseTimeBefore.instant
        let loadedFirstToken = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: sampleID
        )
        let firstToken = try XCTUnwrap(loadedFirstToken)
        let secondResultID = UUID()
        let firstCorrection = try await writer.correctLabSample(
            CorrectLabSampleCommand(
                parentID: sampleID,
                expectedHead: firstToken,
                timestamp: try timestamp(instant: 300),
                specimenOriginal: "血清　",
                contextNote: "第一次更正",
                results: [
                    CorrectedLabResultInput(
                        logicalResultID: secondResultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: " 200 ",
                        unitOriginal: "pg/mL",
                        assayOrVariantOriginal: ""
                    ),
                    CorrectedLabResultInput(
                        logicalResultID: originalResultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "＜ 90 ",
                        unitOriginal: "pg/mL",
                        assayOrVariantOriginal: nil
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 301)
            )
        )
        XCTAssertTrue(firstCorrection.didApply)
        let loadedSecondToken = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: sampleID
        )
        let secondToken = try XCTUnwrap(loadedSecondToken)
        _ = try await writer.correctLabSample(
            CorrectLabSampleCommand(
                parentID: sampleID,
                expectedHead: secondToken,
                timestamp: try timestamp(instant: 200),
                specimenOriginal: "血清　",
                contextNote: "第二次更正",
                results: [
                    CorrectedLabResultInput(
                        logicalResultID: originalResultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "＜ 80 ",
                        unitOriginal: "pg/mL",
                        assayOrVariantOriginal: nil
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 302)
            )
        )

        let loadedEffective = try await reader.labSample(id: sampleID)
        let effective = try XCTUnwrap(loadedEffective)
        XCTAssertEqual(
            effective.timestamp.instant,
            try timestamp(instant: 200).instant
        )
        XCTAssertEqual(effective.contextNote, "第二次更正")
        XCTAssertEqual(effective.results.map(\.id), [originalResultID])
        XCTAssertEqual(effective.results[0].rawValueOriginal, "＜ 80 ")
        XCTAssertNil(effective.results[0].assayOrVariantOriginal)
        XCTAssertEqual(baseBefore.specimenOriginal, baseSpecimen)
        XCTAssertEqual(baseResultBefore.rawValueOriginal, baseRaw)
        XCTAssertEqual(baseTimeBefore.instant, baseInstant)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<ParentRecordMutationEventRecord>()
            ),
            3
        )
        try ParentRecordLifecycleValidator.validate(
            in: context,
            failure: .corruptionSuspected
        )
    }

    func testLabCorrectionRejectsNoOpStaleHeadAndDigestConflict()
        async throws {
        let fixture = try await makeLabFixture()
        let reader = AppReadActor(modelContainer: fixture.container)
        let writer = AppWriteActor(modelContainer: fixture.container)
        let loadedToken = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: fixture.sampleID
        )
        let token = try XCTUnwrap(loadedToken)
        let noOp = CorrectLabSampleCommand(
            parentID: fixture.sampleID,
            expectedHead: token,
            timestamp: fixture.timestamp,
            specimenOriginal: "",
            contextNote: "",
            results: [
                CorrectedLabResultInput(
                    logicalResultID: fixture.resultID,
                    itemDefinitionID: fixture.definitionID,
                    rawValueOriginal: "10",
                    unitOriginal: "mg/L"
                )
            ]
        )
        await assertThrows(noOp, using: writer, equals: .noEffectiveChange)

        let operationID = UUID()
        let command = CorrectLabSampleCommand(
            operationID: operationID,
            parentID: fixture.sampleID,
            expectedHead: token,
            timestamp: try timestamp(instant: 200),
            specimenOriginal: "",
            contextNote: "更正",
            results: [
                CorrectedLabResultInput(
                    logicalResultID: fixture.resultID,
                    itemDefinitionID: fixture.definitionID,
                    rawValueOriginal: "11",
                    unitOriginal: "mg/L"
                )
            ],
            committedAt: Date(timeIntervalSince1970: 201)
        )
        let applied = try await writer.correctLabSample(command)
        let replay = try await writer.correctLabSample(command)
        XCTAssertTrue(applied.didApply)
        XCTAssertFalse(replay.didApply)

        let conflict = CorrectLabSampleCommand(
            operationID: operationID,
            parentID: fixture.sampleID,
            expectedHead: token,
            timestamp: try timestamp(instant: 200),
            specimenOriginal: "",
            contextNote: "不同",
            results: [
                CorrectedLabResultInput(
                    logicalResultID: fixture.resultID,
                    itemDefinitionID: fixture.definitionID,
                    rawValueOriginal: "12",
                    unitOriginal: "mg/L"
                )
            ],
            committedAt: Date(timeIntervalSince1970: 201)
        )
        await assertThrows(
            conflict,
            using: writer,
            equals: .operationConflict
        )
        let stale = CorrectLabSampleCommand(
            parentID: fixture.sampleID,
            expectedHead: token,
            timestamp: try timestamp(instant: 300),
            specimenOriginal: "",
            contextNote: "旧令牌",
            results: [
                CorrectedLabResultInput(
                    logicalResultID: fixture.resultID,
                    itemDefinitionID: fixture.definitionID,
                    rawValueOriginal: "13",
                    unitOriginal: "mg/L"
                )
            ]
        )
        await assertThrows(stale, using: writer, equals: .staleHead)
    }

    func testLabCorrectionRejectsLogicalResultIdentityOwnedByAnotherActiveSample()
        async throws {
        let container = try preparedV10Container()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let definitionID = UUID()
        let firstSampleID = UUID()
        let firstResultID = UUID()
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: firstSampleID,
                timestamp: try timestamp(instant: 100),
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: definitionID,
                        displayName: "共享项目",
                        code: "SHARED"
                    )
                ],
                results: [
                    LabResultInput(
                        id: firstResultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "10",
                        unitOriginal: "mg/L"
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let secondSampleID = UUID()
        let secondResultID = UUID()
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: secondSampleID,
                timestamp: try timestamp(instant: 200),
                newDefinitions: [],
                results: [
                    LabResultInput(
                        id: secondResultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "20",
                        unitOriginal: "mg/L"
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 200)
            )
        )
        let loadedHead = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: secondSampleID
        )
        let headBefore = try XCTUnwrap(loadedHead)
        let loadedSampleBefore = try await reader.labSample(
            id: secondSampleID
        )
        let sampleBefore = try XCTUnwrap(loadedSampleBefore)
        let contextBefore = ModelContext(container)
        let metadataBefore = try XCTUnwrap(
            contextBefore.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let nextRevisionBefore = metadataBefore.nextLocalRevision
        let eventCountBefore = try contextBefore.fetchCount(
            FetchDescriptor<ParentRecordMutationEventRecord>()
        )
        let correctionCountBefore = try contextBefore.fetchCount(
            FetchDescriptor<LabSampleCorrectionSnapshotRecord>()
        )
        let correctedResultCountBefore = try contextBefore.fetchCount(
            FetchDescriptor<LabResultCorrectionSnapshotRecord>()
        )
        let receiptCountBefore = try contextBefore.fetchCount(
            FetchDescriptor<OperationReceiptRecord>()
        )
        let revisionCountBefore = try contextBefore.fetchCount(
            FetchDescriptor<RecordRevision>()
        )

        do {
            _ = try await writer.correctLabSample(
                CorrectLabSampleCommand(
                    parentID: secondSampleID,
                    expectedHead: headBefore,
                    timestamp: try timestamp(instant: 300),
                    specimenOriginal: "",
                    contextNote: "不得借用另一份样本的结果身份",
                    results: [
                        CorrectedLabResultInput(
                            logicalResultID: firstResultID,
                            itemDefinitionID: definitionID,
                            rawValueOriginal: "30",
                            unitOriginal: "mg/L"
                        )
                    ],
                    committedAt: Date(timeIntervalSince1970: 300)
                )
            )
            XCTFail("有效样本之间不得共享 logical result identity")
        } catch {
            XCTAssertEqual(
                error as? ParentRecordMutationFailure,
                .invalidInput
            )
        }

        let loadedSampleAfter = try await reader.labSample(
            id: secondSampleID
        )
        let sampleAfter = try XCTUnwrap(loadedSampleAfter)
        let loadedHeadAfter = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: secondSampleID
        )
        let headAfter = try XCTUnwrap(loadedHeadAfter)
        let contextAfter = ModelContext(container)
        let metadataAfter = try XCTUnwrap(
            contextAfter.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        XCTAssertEqual(sampleAfter, sampleBefore)
        XCTAssertEqual(headAfter, headBefore)
        XCTAssertEqual(metadataAfter.nextLocalRevision, nextRevisionBefore)
        XCTAssertEqual(
            try contextAfter.fetchCount(
                FetchDescriptor<ParentRecordMutationEventRecord>()
            ),
            eventCountBefore
        )
        XCTAssertEqual(
            try contextAfter.fetchCount(
                FetchDescriptor<LabSampleCorrectionSnapshotRecord>()
            ),
            correctionCountBefore
        )
        XCTAssertEqual(
            try contextAfter.fetchCount(
                FetchDescriptor<LabResultCorrectionSnapshotRecord>()
            ),
            correctedResultCountBefore
        )
        XCTAssertEqual(
            try contextAfter.fetchCount(
                FetchDescriptor<OperationReceiptRecord>()
            ),
            receiptCountBefore
        )
        XCTAssertEqual(
            try contextAfter.fetchCount(
                FetchDescriptor<RecordRevision>()
            ),
            revisionCountBefore
        )
    }

    func testStatusCorrectionChangesOnlyEffectiveObservation()
        async throws {
        let container = try preparedV10Container()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let metricID = UUID()
        _ = try await writer.createStatusMetric(
            CreateStatusMetricCommand(
                operationID: UUID(),
                metricID: metricID,
                displayName: "睡眠"
            )
        )
        let observationID = UUID()
        let originalTimestamp = try timestamp(instant: 100)
        _ = try await writer.recordStatusObservation(
            RecordStatusObservationCommand(
                operationID: UUID(),
                observationID: observationID,
                metricDefinitionID: metricID,
                ordinalLevel: 2,
                note: "原始",
                timestamp: originalTimestamp,
                committedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let loadedToken = try await reader.parentRecordHeadToken(
            type: .statusObservation,
            id: observationID
        )
        let token = try XCTUnwrap(loadedToken)
        _ = try await writer.correctStatusObservation(
            CorrectStatusObservationCommand(
                parentID: observationID,
                expectedHead: token,
                metricDefinitionID: metricID,
                ordinalLevel: 4,
                note: "修正后",
                timestamp: try timestamp(instant: 300),
                committedAt: Date(timeIntervalSince1970: 301)
            )
        )
        let loadedEffective = try await reader.statusObservation(
            id: observationID
        )
        let effective = try XCTUnwrap(loadedEffective)
        XCTAssertEqual(effective.ordinalLevel, 4)
        XCTAssertEqual(effective.note, "修正后")
        XCTAssertEqual(effective.timestamp.instant, Date(timeIntervalSince1970: 300))
        let context = ModelContext(container)
        let base = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<StatusObservationRecord>(
                    predicate: #Predicate {
                        $0.id == observationID
                    }
                )
            ).first
        )
        XCTAssertEqual(base.ordinalLevel, 2)
        XCTAssertEqual(base.note, "原始")
    }

    func testCorrectionToZeroKeepsAttachmentOnlyInvariant()
        async throws {
        let fixture = try await makeLabFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let reader = AppReadActor(modelContainer: fixture.container)
        let attachmentID = UUID()
        let attachmentOperationID = UUID()
        let path = try XCTUnwrap(
            AttachmentPathFacts.relativePath(
                attachmentID: attachmentID,
                typeIdentifier: UTType.pdf.identifier
            )
        )
        _ = try await writer.addAttachmentMetadata(
            AddAttachmentMetadataCommand(
                operationID: attachmentOperationID,
                attachmentID: attachmentID,
                ownerType: .labSample,
                ownerID: fixture.sampleID,
                relativePath: path,
                originalFilename: "report.pdf",
                typeIdentifier: UTType.pdf.identifier,
                byteCount: 4,
                sha256Hex: String(repeating: "a", count: 64),
                committedAt: Date(timeIntervalSince1970: 150)
            )
        )
        let loadedToken = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: fixture.sampleID
        )
        let token = try XCTUnwrap(loadedToken)
        _ = try await writer.correctLabSample(
            CorrectLabSampleCommand(
                parentID: fixture.sampleID,
                expectedHead: token,
                timestamp: fixture.timestamp,
                specimenOriginal: "",
                contextNote: "仅保留附件",
                results: [],
                committedAt: Date(timeIntervalSince1970: 200)
            )
        )
        let loadedAttachments = try await reader.attachments(
            ownerType: .labSample,
            ownerID: fixture.sampleID
        )
        let attachment = try XCTUnwrap(loadedAttachments.first)
        do {
            _ = try await writer.deleteAttachment(
                DeleteAttachmentCommand(
                    operationID: UUID(),
                    attachmentID: attachment.id
                )
            )
            XCTFail("附件-only 化验不得删除最后一个附件")
        } catch {
            XCTAssertEqual(
                error as? PersonalTimelineWriteFailure,
                .lastAttachmentRequired
            )
        }
    }

    func testConcurrentZeroResultCorrectionAndLastAttachmentDeleteStayValid()
        async throws
    {
        let fixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "only.pdf")
            ]
        )
        let loadedAttachments = try await fixture.reader.attachments(
            ownerType: .labSample,
            ownerID: fixture.sampleID
        )
        let attachment = try XCTUnwrap(loadedAttachments.first)
        let loadedHead = try await fixture.reader.parentRecordHeadToken(
            type: .labSample,
            id: fixture.sampleID
        )
        let head = try XCTUnwrap(loadedHead)
        let correctionTask = Task { () -> Bool in
            do {
                _ = try await fixture.service.correctLabSample(
                    CorrectLabSampleCommand(
                        parentID: fixture.sampleID,
                        expectedHead: head,
                        timestamp: try self.timestamp(instant: 200),
                        specimenOriginal: "",
                        contextNote: "仅附件",
                        results: []
                    )
                )
                return true
            } catch {
                return false
            }
        }
        let deletionTask = Task { () -> Bool in
            do {
                try await fixture.service.deleteAttachment(attachment)
                return true
            } catch {
                return false
            }
        }
        let correctionSucceeded = await correctionTask.value
        let deletionSucceeded = await deletionTask.value
        let loadedEffective = try await fixture.reader.labSample(
            id: fixture.sampleID
        )
        let effective = try XCTUnwrap(loadedEffective)
        let attachments = try await fixture.reader.attachments(
            ownerType: .labSample,
            ownerID: fixture.sampleID
        )

        XCTAssertFalse(effective.results.isEmpty && attachments.isEmpty)
        XCTAssertFalse(correctionSucceeded && deletionSucceeded)
    }

    func testValidatorRejectsMissingPredecessorCycleAndFork()
        async throws
    {
        do {
            let fixture = try await correctedLabFixture()
            let context = ModelContext(fixture.container)
            let corrected = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<ParentRecordMutationEventRecord>()
                ).first(where: { $0.kind == .corrected })
            )
            corrected.previousEventID = UUID()
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }

        do {
            let fixture = try await correctedLabFixture()
            let context = ModelContext(fixture.container)
            let events = try context.fetch(
                FetchDescriptor<ParentRecordMutationEventRecord>()
            )
            let root = try XCTUnwrap(
                events.first(where: { $0.previousEventID == nil })
            )
            let corrected = try XCTUnwrap(
                events.first(where: { $0.kind == .corrected })
            )
            root.previousEventID = corrected.id
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }

        do {
            let fixture = try await correctedLabFixture()
            let context = ModelContext(fixture.container)
            let events = try context.fetch(
                FetchDescriptor<ParentRecordMutationEventRecord>()
            )
            let corrected = try XCTUnwrap(
                events.first(where: { $0.kind == .corrected })
            )
            let fork = ParentRecordMutationEventRecord(
                parentType: .labSample,
                parentID: fixture.sampleID,
                kind: .corrected,
                previousEventID: corrected.previousEventID,
                payloadRecordType: corrected.payloadRecordType,
                payloadID: corrected.payloadID,
                operationID: UUID(),
                commandDigest: String(repeating: "a", count: 64),
                preFactsDigest: corrected.preFactsDigest,
                postFactsDigest: corrected.postFactsDigest,
                committedAt: corrected.committedAt
                    .addingTimeInterval(1)
            )
            context.insert(fork)
            let head = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<ParentRecordLifecycleHeadRecord>()
                ).first
            )
            head.eventCount += 1
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }
    }

    func testValidatorRecomputesCorrectionAndDeletionCommandDigests()
        async throws
    {
        do {
            let fixture = try await correctedLabFixture()
            let context = ModelContext(fixture.container)
            let event = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<ParentRecordMutationEventRecord>()
                ).first(where: { $0.kind == .corrected })
            )
            let receipt = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<OperationReceiptRecord>()
                ).first(where: { $0.operationID == event.operationID })
            )
            let driftedDigest = String(repeating: "a", count: 64)
            event.commandDigest = driftedDigest
            receipt.commandDigest = driftedDigest
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }

        do {
            let fixture = try await makeLabFixture()
            let reader = AppReadActor(modelContainer: fixture.container)
            let writer = AppWriteActor(modelContainer: fixture.container)
            let impact = try await reader.parentRecordDeletionImpact(
                type: .labSample,
                id: fixture.sampleID
            )
            _ = try await writer.deleteParentRecord(
                DeleteParentRecordCommand(
                    parentType: .labSample,
                    parentID: fixture.sampleID,
                    expectedHead: impact.expectedHead,
                    expectedImpactDigest: impact.impactDigest,
                    attachments: [],
                    committedAt: Date(timeIntervalSince1970: 300)
                )
            )
            let context = ModelContext(fixture.container)
            let event = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<ParentRecordMutationEventRecord>()
                ).first(where: { $0.kind == .deleted })
            )
            let receipt = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<OperationReceiptRecord>()
                ).first(where: { $0.operationID == event.operationID })
            )
            let driftedDigest = String(repeating: "b", count: 64)
            event.commandDigest = driftedDigest
            receipt.commandDigest = driftedDigest
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }
    }

    func testValidatorBindsDeletionManifestToAttachmentOperation()
        async throws
    {
        let fixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "manifest.pdf")
            ]
        )
        let impact = try await fixture.reader.parentRecordDeletionImpact(
            type: .labSample,
            id: fixture.sampleID
        )
        _ = try await fixture.service.deleteParentRecord(impact: impact)
        let context = ModelContext(fixture.container)
        let tombstone = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<ParentRecordDeletionTombstoneRecord>()
            ).first
        )
        let entries = try XCTUnwrap(
            ParentRecordDeletionAttachmentManifest.decode(
                tombstone.attachmentManifest
            )
        )
        let original = try XCTUnwrap(entries.first)
        tombstone.attachmentManifest =
            ParentRecordDeletionAttachmentManifest.encode([
                ParentRecordDeletionAttachmentManifestEntry(
                    attachmentID: original.attachmentID,
                    sha256Hex: original.sha256Hex,
                    deletionOperationID: UUID()
                )
            ])
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<ParentRecordMutationEventRecord>()
            ).first(where: { $0.kind == .deleted })
        )
        event.postFactsDigest = try RecordDigestV1.sha256Hex(
            recordType: "ParentRecordDeletionTombstoneRecord",
            recordID: tombstone.id,
            fields: try ParentRecordLifecycleDigest.tombstone(tombstone)
        )
        try context.save()
        XCTAssertThrowsError(
            try ParentRecordLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testValidatorBindsParentMutationSemanticRevisions()
        async throws
    {
        do {
            let fixture = try await correctedLabFixture()
            let context = ModelContext(fixture.container)
            let events = try context.fetch(
                FetchDescriptor<ParentRecordMutationEventRecord>()
            )
            let corrected = try XCTUnwrap(
                events.first(where: { $0.kind == .corrected })
            )
            let predecessorID = try XCTUnwrap(
                corrected.previousEventID
            )
            let predecessorKey =
                "ParentRecordMutationEventRecord:"
                + predecessorID.uuidString.lowercased()
            let predecessorRevision = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<RecordRevision>(
                        predicate: #Predicate {
                            $0.recordKey == predecessorKey
                        }
                    )
                ).first
            )
            predecessorRevision.localRevision += 1
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }

        do {
            let fixture = try await correctedLabFixture()
            let context = ModelContext(fixture.container)
            let corrected = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<ParentRecordMutationEventRecord>()
                ).first(where: { $0.kind == .corrected })
            )
            let payloadID = try XCTUnwrap(corrected.payloadID)
            let payloadKey =
                "LabSampleCorrectionSnapshotRecord:"
                + payloadID.uuidString.lowercased()
            let payloadRevision = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<RecordRevision>(
                        predicate: #Predicate {
                            $0.recordKey == payloadKey
                        }
                    )
                ).first
            )
            payloadRevision.localRevision += 1
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }

        do {
            let fixture = try await makeAttachmentParentFixture(
                attachmentDrafts: [
                    attachmentDraft(filename: "revision.pdf")
                ]
            )
            let impact = try await fixture.reader
                .parentRecordDeletionImpact(
                    type: .labSample,
                    id: fixture.sampleID
                )
            _ = try await fixture.service.deleteParentRecord(
                impact: impact
            )
            let context = ModelContext(fixture.container)
            let attachment = try XCTUnwrap(
                try context.fetch(FetchDescriptor<AttachmentRecord>())
                    .first
            )
            let attachmentKey =
                "AttachmentRecord:"
                + attachment.id.uuidString.lowercased()
            let attachmentRevision = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<RecordRevision>(
                        predicate: #Predicate {
                            $0.recordKey == attachmentKey
                        }
                    )
                ).first
            )
            attachmentRevision.localRevision += 1
            try context.save()
            XCTAssertThrowsError(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }
    }

    func testDeletionDigestFreezesCompleteAttachmentIdentity()
        throws
    {
        let attachmentID = UUID()
        let parentID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let base = AttachmentSnapshot(
            id: attachmentID,
            ownerType: .labSample,
            ownerID: parentID,
            relativePath: "Attachments/report.pdf",
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier,
            byteCount: 4,
            sha256Hex: String(repeating: "a", count: 64),
            createdAt: createdAt
        )
        let renamed = AttachmentSnapshot(
            id: attachmentID,
            ownerType: .labSample,
            ownerID: parentID,
            relativePath: base.relativePath,
            originalFilename: "renamed.pdf",
            typeIdentifier: base.typeIdentifier,
            byteCount: base.byteCount,
            sha256Hex: base.sha256Hex,
            createdAt: createdAt
        )
        let redated = AttachmentSnapshot(
            id: attachmentID,
            ownerType: .labSample,
            ownerID: parentID,
            relativePath: base.relativePath,
            originalFilename: base.originalFilename,
            typeIdentifier: base.typeIdentifier,
            byteCount: base.byteCount,
            sha256Hex: base.sha256Hex,
            createdAt: createdAt.addingTimeInterval(1)
        )
        let token = ParentRecordHeadToken(
            latestEventID: UUID(),
            eventCount: 1,
            localRevision: 10,
            factsDigest: String(repeating: "b", count: 64)
        )
        let baseDigest = try ParentRecordLifecycleCommandDigest.impact(
            type: .labSample,
            parentID: parentID,
            token: token,
            effectiveResultCount: 1,
            correctionCount: 0,
            attachments: [base]
        )
        let renamedDigest =
            try ParentRecordLifecycleCommandDigest.impact(
                type: .labSample,
                parentID: parentID,
                token: token,
                effectiveResultCount: 1,
                correctionCount: 0,
                attachments: [renamed]
            )
        let redatedDigest =
            try ParentRecordLifecycleCommandDigest.impact(
                type: .labSample,
                parentID: parentID,
                token: token,
                effectiveResultCount: 1,
                correctionCount: 0,
                attachments: [redated]
            )
        XCTAssertNotEqual(baseDigest, renamedDigest)
        XCTAssertNotEqual(baseDigest, redatedDigest)

        let operationID = UUID()
        let deletionOperationID = UUID()
        func commandDigest(
            attachment: AttachmentSnapshot,
            impactDigest: String
        ) throws -> String {
            try ParentRecordLifecycleCommandDigest.delete(
                DeleteParentRecordCommand(
                    operationID: operationID,
                    parentType: .labSample,
                    parentID: parentID,
                    expectedHead: token,
                    expectedImpactDigest: impactDigest,
                    attachments: [
                        ParentRecordDeletionAttachment(
                            attachment: attachment,
                            deletionOperationID: deletionOperationID
                        )
                    ],
                    committedAt: Date(timeIntervalSince1970: 200)
                )
            )
        }
        let baseCommand = try commandDigest(
            attachment: base,
            impactDigest: baseDigest
        )
        XCTAssertNotEqual(
            baseCommand,
            try commandDigest(
                attachment: renamed,
                impactDigest: baseDigest
            )
        )
        XCTAssertNotEqual(
            baseCommand,
            try commandDigest(
                attachment: redated,
                impactDigest: baseDigest
            )
        )
    }

    func testValidatorRejectsOrphanParentMutationReceipt()
        async throws
    {
        let fixture = try await correctedLabFixture()
        let context = ModelContext(fixture.container)
        context.insert(
            OperationReceiptRecord(
                operationID: UUID(),
                commandDigest: String(repeating: "c", count: 64),
                resultRecordType:
                    "ParentRecordMutationEventRecord",
                resultRecordID: UUID(),
                committedAt: Date(timeIntervalSince1970: 400)
            )
        )
        try context.save()
        XCTAssertThrowsError(
            try ParentRecordLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testValidatorRejectsOrphanParentMutationEvent()
        async throws
    {
        let fixture = try await correctedLabFixture()
        let context = ModelContext(fixture.container)
        context.insert(
            ParentRecordMutationEventRecord(
                parentType: .labSample,
                parentID: UUID(),
                kind: .migratedSnapshot,
                previousEventID: nil,
                payloadRecordType: nil,
                payloadID: nil,
                operationID: UUID(),
                commandDigest: String(repeating: "a", count: 64),
                preFactsDigest: String(repeating: "b", count: 64),
                postFactsDigest: String(repeating: "b", count: 64),
                committedAt: Date(timeIntervalSince1970: 400)
            )
        )
        try context.save()
        XCTAssertThrowsError(
            try ParentRecordLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testCorrectionReordersTimelineAndDeleteDoesNotTouchOtherParent()
        async throws
    {
        let first = try await makeLabFixture()
        let writer = AppWriteActor(modelContainer: first.container)
        let reader = AppReadActor(modelContainer: first.container)
        let otherID = UUID()
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: otherID,
                timestamp: try timestamp(instant: 300),
                newDefinitions: [],
                results: [
                    LabResultInput(
                        itemDefinitionID: first.definitionID,
                        rawValueOriginal: "20",
                        unitOriginal: "mg/L"
                    )
                ]
            )
        )
        let loadedHead = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: first.sampleID
        )
        let head = try XCTUnwrap(loadedHead)
        _ = try await writer.correctLabSample(
            CorrectLabSampleCommand(
                parentID: first.sampleID,
                expectedHead: head,
                timestamp: try timestamp(instant: 400),
                specimenOriginal: "",
                contextNote: "移动到时间线首位",
                results: [
                    CorrectedLabResultInput(
                        logicalResultID: first.resultID,
                        itemDefinitionID: first.definitionID,
                        rawValueOriginal: "10",
                        unitOriginal: "mg/L"
                    )
                ]
            )
        )
        let timeline = try await reader.personalTimelinePage(limit: 10)
        XCTAssertEqual(
            timeline.items.first(where: { $0.kind == .labSample })?.id,
            first.sampleID
        )
        let impact = try await reader.parentRecordDeletionImpact(
            type: .labSample,
            id: first.sampleID
        )
        _ = try await writer.deleteParentRecord(
            DeleteParentRecordCommand(
                parentType: .labSample,
                parentID: first.sampleID,
                expectedHead: impact.expectedHead,
                expectedImpactDigest: impact.impactDigest,
                attachments: []
            )
        )
        let otherAfterDelete = try await reader.labSample(id: otherID)
        XCTAssertNotNil(otherAfterDelete)
    }

    func testDeleteHidesNormalReadsTimelineAndTrendButKeepsBase()
        async throws {
        let fixture = try await makeLabFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let reader = AppReadActor(modelContainer: fixture.container)
        let impact = try await reader.parentRecordDeletionImpact(
            type: .labSample,
            id: fixture.sampleID
        )
        let result = try await writer.deleteParentRecord(
            DeleteParentRecordCommand(
                parentType: .labSample,
                parentID: fixture.sampleID,
                expectedHead: impact.expectedHead,
                expectedImpactDigest: impact.impactDigest,
                attachments: []
            )
        )
        XCTAssertTrue(result.didApply)
        let effectiveAfterDelete = try await reader.labSample(
            id: fixture.sampleID
        )
        let isDeleted = try await reader.parentRecordIsDeleted(
            type: .labSample,
            id: fixture.sampleID
        )
        let baseAfterDelete = try await reader.baseLabSample(
            id: fixture.sampleID
        )
        XCTAssertNil(effectiveAfterDelete)
        XCTAssertTrue(isDeleted)
        XCTAssertNotNil(baseAfterDelete)
        let timeline = try await reader.personalTimelinePage(limit: 50)
        XCTAssertFalse(timeline.items.contains {
            $0.kind == .labSample && $0.id == fixture.sampleID
        })
        let trend = try await reader.labTrendPage(
            LabTrendRequest(
                itemDefinitionID: fixture.definitionID,
                assayOrVariantOriginal: nil,
                sourceUnitOriginal: "mg/L",
                displayUnitID: nil
            )
        )
        XCTAssertTrue(trend.points.isEmpty)
    }

    func testDeletingLatestLabFallsBackToEarlierActiveSample()
        async throws {
        let first = try await makeLabFixture()
        let writer = AppWriteActor(
            modelContainer: first.container
        )
        let reader = AppReadActor(
            modelContainer: first.container
        )
        let newerID = UUID()
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: newerID,
                timestamp: try timestamp(instant: 300),
                newDefinitions: [],
                results: [
                    LabResultInput(
                        itemDefinitionID:
                            first.definitionID,
                        rawValueOriginal: "20",
                        unitOriginal: "mg/L"
                    )
                ]
            )
        )
        let before = try await reader.coreRegimenOverview(
            asOf: try CivilDateFact(
                year: 2026,
                month: 7,
                day: 28
            )
        )
        XCTAssertEqual(before.latestLabSample?.id, newerID)

        let impact = try await reader
            .parentRecordDeletionImpact(
                type: .labSample,
                id: newerID
            )
        _ = try await writer.deleteParentRecord(
            DeleteParentRecordCommand(
                parentType: .labSample,
                parentID: newerID,
                expectedHead: impact.expectedHead,
                expectedImpactDigest:
                    impact.impactDigest,
                attachments: []
            )
        )

        let after = try await reader.coreRegimenOverview(
            asOf: try CivilDateFact(
                year: 2026,
                month: 7,
                day: 28
            )
        )
        XCTAssertEqual(
            after.latestLabSample?.id,
            first.sampleID
        )
        XCTAssertEqual(
            after.latestLabSample?.results.first?
                .rawValueOriginal,
            "10"
        )
    }

    func testDeleteImpactFailsClosedWhenAttachmentsChange()
        async throws {
        let fixture = try await makeLabFixture()
        let writer = AppWriteActor(modelContainer: fixture.container)
        let reader = AppReadActor(modelContainer: fixture.container)
        let impact = try await reader.parentRecordDeletionImpact(
            type: .labSample,
            id: fixture.sampleID
        )
        let attachmentID = UUID()
        let path = try XCTUnwrap(
            AttachmentPathFacts.relativePath(
                attachmentID: attachmentID,
                typeIdentifier: UTType.pdf.identifier
            )
        )
        _ = try await writer.addAttachmentMetadata(
            AddAttachmentMetadataCommand(
                operationID: UUID(),
                attachmentID: attachmentID,
                ownerType: .labSample,
                ownerID: fixture.sampleID,
                relativePath: path,
                originalFilename: "changed.pdf",
                typeIdentifier: UTType.pdf.identifier,
                byteCount: 4,
                sha256Hex: String(repeating: "b", count: 64)
            )
        )
        do {
            _ = try await writer.deleteParentRecord(
                DeleteParentRecordCommand(
                    parentType: .labSample,
                    parentID: fixture.sampleID,
                    expectedHead: impact.expectedHead,
                    expectedImpactDigest: impact.impactDigest,
                    attachments: []
                )
            )
            XCTFail("影响预览变化后不得删除")
        } catch {
            XCTAssertEqual(
                error as? ParentRecordMutationFailure,
                .impactChanged
            )
        }
        let effectiveAfterRejectedDelete = try await reader.labSample(
            id: fixture.sampleID
        )
        XCTAssertNotNil(effectiveAfterRejectedDelete)
    }

    func testAttachmentServiceDeletesParentFilesAndMetadataTogether()
        async throws {
        let container = try preparedV10Container()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Parent-Delete-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = ParentRecoveryRecorder()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: AttachmentFileStore(rootURL: root),
            onRecoveryRequired: {
                await recovery.record()
            }
        )
        let sampleID = UUID()
        let definitionID = UUID()
        _ = try await service.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: try timestamp(instant: 100),
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: definitionID,
                        displayName: "雌二醇"
                    )
                ],
                results: [
                    LabResultInput(
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "10",
                        unitOriginal: "mg/L"
                    )
                ]
            ),
            attachmentDrafts: [
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46]),
                    filename: "report.pdf",
                    typeIdentifier: UTType.pdf.identifier
                )
            ]
        )
        let impact = try await reader.parentRecordDeletionImpact(
            type: .labSample,
            id: sampleID
        )
        XCTAssertEqual(impact.attachments.count, 1)
        _ = try await service.deleteParentRecord(impact: impact)

        let effectiveAfterDelete = try await reader.labSample(id: sampleID)
        let attachmentsAfterDelete = try await reader.attachments(
            ownerType: .labSample,
            ownerID: sampleID
        )
        XCTAssertNil(effectiveAfterDelete)
        XCTAssertTrue(attachmentsAfterDelete.isEmpty)
        let recoveryCallCount = await recovery.callCount()
        XCTAssertEqual(recoveryCallCount, 0)
        let staging = root.appendingPathComponent(
            ".staging",
            isDirectory: true
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: staging.path
            ).isEmpty
        )
    }

    func testParentDeleteRevalidatesStaleHeadBeforeMovingFiles()
        async throws
    {
        let fixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "report.pdf")
            ]
        )
        let impact = try await fixture.reader.parentRecordDeletionImpact(
            type: .labSample,
            id: fixture.sampleID
        )
        let attachment = try XCTUnwrap(impact.attachments.first)
        let fileURL = fixture.root.appendingPathComponent(
            attachment.relativePath
        )
        _ = try await fixture.service.correctLabSample(
            CorrectLabSampleCommand(
                parentID: fixture.sampleID,
                expectedHead: impact.expectedHead,
                timestamp: try timestamp(instant: 200),
                specimenOriginal: "",
                contextNote: "并发更正",
                results: [
                    CorrectedLabResultInput(
                        logicalResultID: fixture.resultID,
                        itemDefinitionID: fixture.definitionID,
                        rawValueOriginal: "11",
                        unitOriginal: "mg/L"
                    )
                ]
            )
        )

        do {
            _ = try await fixture.service.deleteParentRecord(
                impact: impact
            )
            XCTFail("stale head 必须在移动附件前拒绝")
        } catch {
            XCTAssertEqual(
                error as? ParentRecordMutationFailure,
                .staleHead
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let staleRecoveryCount = await fixture.recovery.callCount()
        XCTAssertEqual(staleRecoveryCount, 0)
    }

    func testParentDeleteRevalidatesChangedAttachmentSetBeforeMovingFiles()
        async throws
    {
        let fixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "first.pdf"),
                attachmentDraft(filename: "second.pdf")
            ]
        )
        let impact = try await fixture.reader.parentRecordDeletionImpact(
            type: .labSample,
            id: fixture.sampleID
        )
        XCTAssertEqual(impact.attachments.count, 2)
        try await fixture.service.deleteAttachment(impact.attachments[0])
        let remaining = impact.attachments[1]
        let remainingURL = fixture.root.appendingPathComponent(
            remaining.relativePath
        )

        do {
            _ = try await fixture.service.deleteParentRecord(
                impact: impact
            )
            XCTFail("附件集合变化后必须在 staging 前拒绝")
        } catch {
            XCTAssertEqual(
                error as? ParentRecordMutationFailure,
                .impactChanged
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: remainingURL.path)
        )
        let changedImpactRecoveryCount =
            await fixture.recovery.callCount()
        XCTAssertEqual(changedImpactRecoveryCount, 0)
    }

    func testParentDeleteRollsBackEarlierFilesWhenLaterStageFails()
        async throws
    {
        let fixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "first.pdf"),
                attachmentDraft(filename: "second.pdf")
            ]
        )
        let impact = try await fixture.reader.parentRecordDeletionImpact(
            type: .labSample,
            id: fixture.sampleID
        )
        let secondID = try XCTUnwrap(impact.attachments.last?.id)
        let failingService = AttachmentMutationService(
            writer: fixture.writer,
            fileStore: AttachmentFileStore(
                rootURL: fixture.root,
                failureInjection: .stageDeletion(secondID)
            ),
            onRecoveryRequired: {
                await fixture.recovery.record()
            }
        )

        do {
            _ = try await failingService.deleteParentRecord(
                impact: impact
            )
            XCTFail("第二个 staging 故障必须回滚第一个")
        } catch {
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .simulatedInterruption
            )
        }
        for attachment in impact.attachments {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent(attachment.relativePath)
                        .path
                )
            )
        }
        let sampleAfterStageFailure = try await fixture.reader.labSample(
            id: fixture.sampleID
        )
        XCTAssertNotNil(sampleAfterStageFailure)
        let stageRecoveryCount = await fixture.recovery.callCount()
        XCTAssertEqual(stageRecoveryCount, 0)
    }

    func testParentDeleteDatabaseFailureRestoresStagedFiles()
        async throws
    {
        let fixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "report.pdf")
            ]
        )
        let impact = try await fixture.reader.parentRecordDeletionImpact(
            type: .labSample,
            id: fixture.sampleID
        )

        do {
            _ = try await fixture.service.deleteParentRecord(
                impact: impact,
                writeFailureInjection: .beforeRevisionCommit
            )
            XCTFail("数据库故障必须回滚文件")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }
        let sampleAfterDatabaseFailure = try await fixture.reader.labSample(
            id: fixture.sampleID
        )
        XCTAssertNotNil(sampleAfterDatabaseFailure)
        XCTAssertTrue(
            impact.attachments.allSatisfy {
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent($0.relativePath)
                        .path
                )
            }
        )
        let databaseRecoveryCount = await fixture.recovery.callCount()
        XCTAssertEqual(databaseRecoveryCount, 0)
    }

    func testParentDeleteRollbackAndFinalizeFailuresRequireRecovery()
        async throws
    {
        let rollbackFixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "rollback.pdf")
            ],
            failureInjection: .rollbackDeletion
        )
        let rollbackImpact = try await rollbackFixture.reader
            .parentRecordDeletionImpact(
                type: .labSample,
                id: rollbackFixture.sampleID
            )
        do {
            _ = try await rollbackFixture.service.deleteParentRecord(
                impact: rollbackImpact,
                writeFailureInjection: .beforeRevisionCommit
            )
            XCTFail("rollback failure 必须进入 Recovery")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .recoveryRequired
            )
        }
        let rollbackRecoveryCount =
            await rollbackFixture.recovery.callCount()
        XCTAssertEqual(rollbackRecoveryCount, 1)

        let finalizeFixture = try await makeAttachmentParentFixture(
            attachmentDrafts: [
                attachmentDraft(filename: "finalize.pdf")
            ],
            failureInjection: .finalizeDeletion
        )
        let finalizeImpact = try await finalizeFixture.reader
            .parentRecordDeletionImpact(
                type: .labSample,
                id: finalizeFixture.sampleID
            )
        do {
            _ = try await finalizeFixture.service.deleteParentRecord(
                impact: finalizeImpact
            )
            XCTFail("finalize failure 必须进入 Recovery")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .recoveryRequired
            )
        }
        let isDeletedAfterFinalizeFailure = try await finalizeFixture.reader
            .parentRecordIsDeleted(
                type: .labSample,
                id: finalizeFixture.sampleID
            )
        XCTAssertTrue(
            isDeletedAfterFinalizeFailure
        )
        let finalizeRecoveryCount =
            await finalizeFixture.recovery.callCount()
        XCTAssertEqual(finalizeRecoveryCount, 1)
    }

    private struct AttachmentParentFixture {
        let container: ModelContainer
        let writer: AppDataWriter
        let reader: AppReadActor
        let service: AttachmentMutationService
        let recovery: ParentRecoveryRecorder
        let root: URL
        let sampleID: UUID
        let definitionID: UUID
        let resultID: UUID
    }

    private func attachmentDraft(filename: String) -> AttachmentDraft {
        AttachmentDraft(
            data: Data([0x25, 0x50, 0x44, 0x46]),
            filename: filename,
            typeIdentifier: UTType.pdf.identifier
        )
    }

    private func makeAttachmentParentFixture(
        attachmentDrafts: [AttachmentDraft],
        failureInjection: AttachmentFileStoreFailureInjection? = nil
    ) async throws -> AttachmentParentFixture {
        let container = try preparedV10Container()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Parent-Fixture-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let recovery = ParentRecoveryRecorder()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: AttachmentFileStore(
                rootURL: root,
                failureInjection: failureInjection
            ),
            onRecoveryRequired: {
                await recovery.record()
            }
        )
        let sampleID = UUID()
        let definitionID = UUID()
        let resultID = UUID()
        _ = try await service.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: try timestamp(instant: 100),
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: definitionID,
                        displayName: "雌二醇"
                    )
                ],
                results: [
                    LabResultInput(
                        id: resultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "10",
                        unitOriginal: "mg/L"
                    )
                ]
            ),
            attachmentDrafts: attachmentDrafts
        )
        return AttachmentParentFixture(
            container: container,
            writer: writer,
            reader: reader,
            service: service,
            recovery: recovery,
            root: root,
            sampleID: sampleID,
            definitionID: definitionID,
            resultID: resultID
        )
    }

    private struct LabFixture {
        let container: ModelContainer
        let sampleID: UUID
        let definitionID: UUID
        let resultID: UUID
        let timestamp: HistoricalTimestamp
    }

    private func makeLabFixture() async throws -> LabFixture {
        let container = try preparedV10Container()
        let writer = AppWriteActor(modelContainer: container)
        let sampleID = UUID()
        let definitionID = UUID()
        let resultID = UUID()
        let captured = try timestamp(instant: 100)
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: captured,
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: definitionID,
                        displayName: "项目",
                        code: "ITEM"
                    )
                ],
                results: [
                    LabResultInput(
                        id: resultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "10",
                        unitOriginal: "mg/L"
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 100)
            )
        )
        return LabFixture(
            container: container,
            sampleID: sampleID,
            definitionID: definitionID,
            resultID: resultID,
            timestamp: captured
        )
    }

    private func correctedLabFixture() async throws -> LabFixture {
        let fixture = try await makeLabFixture()
        let reader = AppReadActor(modelContainer: fixture.container)
        let writer = AppWriteActor(modelContainer: fixture.container)
        let loadedHead = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: fixture.sampleID
        )
        let head = try XCTUnwrap(loadedHead)
        _ = try await writer.correctLabSample(
            CorrectLabSampleCommand(
                parentID: fixture.sampleID,
                expectedHead: head,
                timestamp: try timestamp(instant: 200),
                specimenOriginal: "",
                contextNote: "更正",
                results: [
                    CorrectedLabResultInput(
                        logicalResultID: fixture.resultID,
                        itemDefinitionID: fixture.definitionID,
                        rawValueOriginal: "11",
                        unitOriginal: "mg/L"
                    )
                ]
            )
        )
        return fixture
    }

    private func preparedV10Container() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryParentRecordLifecycleContainer()
        let now = Date(timeIntervalSince1970: 1)
        _ = try LegacyV1Backfill.run(in: container, now: now)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC",
            now: now
        )
        _ = try TodayExecutionBackfill.run(in: container, now: now)
        _ = try PersonalTimelineBackfill.run(in: container, now: now)
        _ = try CountdownLifecycleBackfill.run(
            in: container,
            now: now,
            includeIntegrityFacts: true
        )
        _ = try OnboardingBackfill.run(
            in: container,
            source: .newInstallV8,
            now: now
        )
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: now
        )
        _ = try ParentRecordLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: now
        )
        return container
    }

    private func timestamp(instant: TimeInterval) throws
        -> HistoricalTimestamp {
        try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: instant),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
    }

    private func labDraft(
        id: UUID,
        name: String,
        reference: String?
    ) -> LabCorrectionResultDraft {
        LabCorrectionResultDraft(
            LabResultSnapshot(
                id: id,
                itemDefinitionID: UUID(),
                itemDefinitionKind: .custom,
                bundledStableID: nil,
                itemNameSnapshot: name,
                itemCodeSnapshot: name,
                rawValueOriginal: "1",
                comparator: nil,
                canonicalDecimalString: "1",
                unitOriginal: "mg/L",
                referenceRangeOriginal: reference,
                assayOrVariantOriginal: nil
            )
        )
    }

    private func assertThrows(
        _ command: CorrectLabSampleCommand,
        using writer: AppWriteActor,
        equals expected: ParentRecordMutationFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await writer.correctLabSample(command)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ParentRecordMutationFailure,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private actor ParentRecoveryRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func callCount() -> Int {
        count
    }
}
