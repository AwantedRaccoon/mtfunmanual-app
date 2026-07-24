import XCTest
@testable import Unmanual

final class PersonalTimelineFactsTests: XCTestCase {
    func testStatusScaleCopyDefinesDirectionAndNonMedicalMeaning() {
        let frozenMeaning =
            "1 到 4 从低到高；这是个人记录刻度，不是医学等级。"
        XCTAssertTrue(StatusScaleCopy.editorGuidance.contains(frozenMeaning))
        XCTAssertEqual(StatusScaleCopy.detailGuidance, frozenMeaning)
        XCTAssertEqual(StatusScaleCopy.accessibilityHint, frozenMeaning)
    }

    func testHistoricalAssociationReviewCopyDistinguishesMissingAndAmbiguousPlans() {
        XCTAssertNil(HistoricalAssociationState.resolved.reviewNotice)
        XCTAssertEqual(
            HistoricalAssociationState.missing.reviewNotice,
            "未找到可关联的当时方案，需要核对。"
        )
        XCTAssertEqual(
            HistoricalAssociationState.ambiguous.reviewNotice,
            "找到多个候选方案，需要核对。"
        )
    }

    func testAttachmentOwnerCapacityRejectsAggregateBytesBeforeStaging() {
        let twentyMiB = AttachmentFileStore.maximumFileBytes
        XCTAssertNoThrow(
            try AttachmentOwnerCapacity.validate(
                byteCounts: [twentyMiB, twentyMiB, twentyMiB]
            )
        )
        XCTAssertThrowsError(
            try AttachmentOwnerCapacity.validate(
                byteCounts: [twentyMiB, twentyMiB, twentyMiB, 1]
            )
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .ownerLimitReached
            )
        }
    }

    func testLabSaveGateBlocksWhileAttachmentFailureIsUnresolved() {
        XCTAssertFalse(
            AttachmentImportGate.allowsSave(
                baseConditionsMet: true,
                isImporting: true,
                hasUnresolvedFailures: false
            )
        )
    }

    func testStatusSaveGateBlocksWhileAttachmentFailureIsUnresolved() {
        XCTAssertFalse(
            AttachmentImportGate.allowsSave(
                baseConditionsMet: true,
                isImporting: false,
                hasUnresolvedFailures: true
            )
        )
        XCTAssertFalse(
            AttachmentImportGate.allowsSave(
                baseConditionsMet: false,
                isImporting: false,
                hasUnresolvedFailures: false
            )
        )
        XCTAssertTrue(
            AttachmentImportGate.allowsSave(
                baseConditionsMet: true,
                isImporting: false,
                hasUnresolvedFailures: false
            )
        )
    }

    func testAttachmentImportBatchKeepsStaleFailureUntilExplicitResolution() {
        var state = AttachmentImportBatchState()
        let first = state.begin()
        let second = state.begin()

        state.recordFailures(2)
        XCTAssertFalse(state.finish(first))
        XCTAssertTrue(state.isImporting)
        XCTAssertTrue(state.isCurrent(second))
        XCTAssertEqual(state.unresolvedFailureCount, 2)
        XCTAssertTrue(state.finish(second))
        XCTAssertFalse(state.isImporting)
        XCTAssertTrue(state.hasUnresolvedFailures)

        state.resolveFailures()
        XCTAssertFalse(state.hasUnresolvedFailures)
        XCTAssertEqual(state.unresolvedFailureCount, 0)
    }

    func testAttachmentImportBatchCountsEverySelectionSupersededByANewerBatch() {
        var state = AttachmentImportBatchState()
        let first = state.begin(selectedCount: 4)
        let second = state.begin(selectedCount: 2)

        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(second))
        XCTAssertEqual(state.unresolvedFailureCount, 4)
        XCTAssertTrue(state.finish(second))
        XCTAssertTrue(state.hasUnresolvedFailures)
    }

    func testAttachmentSelectionCapacityNeverUsesZeroAsPickerLimit() {
        XCTAssertEqual(
            AttachmentSelectionCapacity.remainingSlots(existingCount: 5),
            1
        )
        XCTAssertEqual(
            AttachmentSelectionCapacity.pickerLimit(existingCount: 6),
            1
        )
        XCTAssertFalse(
            AttachmentSelectionCapacity.canSelect(
                existingCount: 6,
                isImporting: false
            )
        )
        XCTAssertEqual(
            AttachmentSelectionCapacity.rejectedSelectionCount(
                selectedCount: 3,
                existingCount: 5
            ),
            2
        )
    }

    func testLabResultDraftRetainsUserEnteredItemCode() {
        var draft = LabResultDraft()
        draft.code = "E2"
        XCTAssertEqual(draft.code, "E2")
        XCTAssertFalse(draft.isEmpty)
    }

    func testTimelineRowIdentityIncludesKindAndRecordID() {
        let sharedID = UUID()
        let timestamp = try! HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_800),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .captured
        )
        let lab = PersonalTimelineItem(
            id: sharedID,
            kind: .labSample,
            title: "化验",
            detail: "",
            timestamp: timestamp,
            dateOnly: nil,
            localDate: timestamp.localDate
        )
        let status = PersonalTimelineItem(
            id: sharedID,
            kind: .statusObservation,
            title: "状态",
            detail: "",
            timestamp: timestamp,
            dateOnly: nil,
            localDate: timestamp.localDate
        )

        XCTAssertNotEqual(lab.rowIdentity, status.rowIdentity)
    }

    func testTimelineRefreshSupersedesAnOlderPaginationRequest() {
        var gate = TimelineRequestEpochGate()
        let olderPagination = gate.currentToken
        let refresh = gate.beginRefresh()

        XCTAssertFalse(gate.isCurrent(olderPagination))
        XCTAssertTrue(gate.isCurrent(refresh))
    }

    func testTimelineCorruptionRequiresRecoveryForInitialAndPaginationReads() {
        for context in [
            TimelineReadContext.firstPage,
            TimelineReadContext.olderPage,
        ] {
            XCTAssertEqual(
                TimelineReadFailurePolicy.action(
                    for: AppDataFailure.corruptionSuspected,
                    context: context,
                    requestIsCurrent: true
                ),
                .requireRecovery(
                    "时间线没有通过本地完整性检查。App 将进入恢复模式，不会把损坏资料显示成空状态。"
                )
            )
        }
    }

    func testTimelineExpiredCorruptionCompletionIsIgnored() {
        XCTAssertEqual(
            TimelineReadFailurePolicy.action(
                for: AppDataFailure.corruptionSuspected,
                context: .olderPage,
                requestIsCurrent: false
            ),
            .ignore
        )
    }

    func testTimelineRetryableReadFailureKeepsContextualCopy() {
        XCTAssertEqual(
            TimelineReadFailurePolicy.action(
                for: AppDataFailure.storageUnavailable,
                context: .firstPage,
                requestIsCurrent: true
            ),
            .retryable("暂时无法读取时间线，原记录没有被修改。")
        )
        XCTAssertEqual(
            TimelineReadFailurePolicy.action(
                for: AppDataFailure.storageUnavailable,
                context: .olderPage,
                requestIsCurrent: true
            ),
            .retryable("暂时无法读取更早的记录，请稍后重试。")
        )
    }

    func testPreviewRequestCompletedAfterDetailExitMustReleaseLease() async {
        var gate = AttachmentPreviewRequestGate()
        let request = gate.begin()
        gate.invalidate()
        let recorder = PreviewLeaseReleaseRecorder()

        let url = await AttachmentPreviewRequestResolution.presentableURL(
            URL(fileURLWithPath: "/test-only/report.pdf"),
            attachmentID: UUID(),
            requestToken: request,
            gate: gate,
            isCancelled: false,
            releaseLease: { _ in
                await recorder.record()
            }
        )

        XCTAssertNil(url)
        let releaseCount = await recorder.count()
        XCTAssertEqual(releaseCount, 1)
    }

    func testPendingOrPresentedPreviewRejectsAReplacementRequest() {
        XCTAssertTrue(
            AttachmentPreviewAdmission.canBegin(
                isRequestInFlight: false,
                presentedAttachmentID: nil
            )
        )
        XCTAssertFalse(
            AttachmentPreviewAdmission.canBegin(
                isRequestInFlight: true,
                presentedAttachmentID: nil
            )
        )
        XCTAssertFalse(
            AttachmentPreviewAdmission.canBegin(
                isRequestInFlight: false,
                presentedAttachmentID: UUID()
            )
        )
    }

    func testLabDecimalValuePreservesOriginalComparatorAndCanonicalDecimal() throws {
        let value = try LabDecimalValue.parse("  ＜ 00172。500 ")

        XCTAssertEqual(value.original, "  ＜ 00172。500 ")
        XCTAssertEqual(value.comparator, .lessThan)
        XCTAssertEqual(value.canonicalDecimal, "172.5")

        let compact = try LabDecimalValue.parse("<172.50")
        XCTAssertEqual(compact.comparator, .lessThan)
        XCTAssertEqual(compact.canonicalDecimal, "172.5")

        let scientific = try LabDecimalValue.parse("-1.2e-3")
        XCTAssertNil(scientific.comparator)
        XCTAssertEqual(scientific.canonicalDecimal, "-0.0012")

        let greaterOrEqual = try LabDecimalValue.parse("≥0")
        XCTAssertEqual(greaterOrEqual.comparator, .greaterThanOrEqual)
        XCTAssertEqual(greaterOrEqual.canonicalDecimal, "0")
    }

    func testLabDecimalValueRejectsMissingAndNonFiniteNumbers() {
        XCTAssertThrowsError(try LabDecimalValue.parse(""))
        XCTAssertThrowsError(try LabDecimalValue.parse("NaN"))
        XCTAssertThrowsError(try LabDecimalValue.parse("∞"))
        XCTAssertThrowsError(try LabDecimalValue.parse("<"))
    }
}

private actor PreviewLeaseReleaseRecorder {
    private var releases = 0

    func record() {
        releases += 1
    }

    func count() -> Int {
        releases
    }
}
