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

    func testLabDecimalValuePreservesOriginalComparatorAndCanonicalDecimal() throws {
        let value = try LabDecimalValue.parse("  ＜ 00172。500 ")

        XCTAssertEqual(value.original, "  ＜ 00172。500 ")
        XCTAssertEqual(value.comparator, .lessThan)
        XCTAssertEqual(value.canonicalDecimal, "172.5")
    }

    func testLabDecimalValueRejectsMissingAndNonFiniteNumbers() {
        XCTAssertThrowsError(try LabDecimalValue.parse(""))
        XCTAssertThrowsError(try LabDecimalValue.parse("NaN"))
        XCTAssertThrowsError(try LabDecimalValue.parse("∞"))
        XCTAssertThrowsError(try LabDecimalValue.parse("<"))
    }
}
