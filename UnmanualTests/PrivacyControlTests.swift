import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class PrivacyControlTests: XCTestCase {
    func testBackfillCreatesDefaultOffPrivacyFactsOnce() throws {
        let container = try makePrivacyContainer()
        let first = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11,
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )

        XCTAssertTrue(first.didComplete)
        XCTAssertTrue(first.didChangeStore)
        XCTAssertTrue(second.didComplete)
        XCTAssertFalse(second.didChangeStore)

        let context = ModelContext(container)
        let snapshot = try PrivacyControlRelationshipValidator.snapshot(
            in: context,
            failure: .corruptionSuspected
        )
        XCTAssertFalse(snapshot.appLockEnabled)
        XCTAssertNil(snapshot.lastOperationID)

        let privacyRevisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        ).filter {
            [
                "PrivacyControlRecord",
                "PrivacyControlBackfillState"
            ].contains($0.recordType)
        }
        XCTAssertEqual(privacyRevisions.count, 2)
        XCTAssertEqual(Set(privacyRevisions.map(\.localRevision)).count, 1)
    }

    func testCompletedBackfillRejectsDifferentCurrentStepSource() throws {
        let container = try makePrivacyContainer()
        _ = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11
        )

        XCTAssertThrowsError(
            try PrivacyControlBackfill.run(
                in: container,
                source: .schemaUpgradeV10
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
    }

    func testValidatorRecomputesInitialDefaultPrivacyDigest() throws {
        let container = try makePrivacyContainer()
        _ = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let context = ModelContext(container)
        let state = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<PrivacyControlBackfillState>()
            ).first
        )
        state.initialPrivacyDigest = String(repeating: "a", count: 64)
        let revision = try XCTUnwrap(
            context.fetch(FetchDescriptor<RecordRevision>())
                .first {
                    $0.recordType
                        == "PrivacyControlBackfillState"
                }
        )
        revision.digestHex = try RecordDigestV1.sha256Hex(
            recordType: "PrivacyControlBackfillState",
            recordID: PrivacyControlBackfillState.stableID,
            fields: try PrivacyControlDigestV1.backfillState(state)
        )
        try context.save()

        XCTAssertThrowsError(
            try PrivacyControlRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testSetAppLockWritesReceiptAndSupportsExactReplay() async throws {
        let container = try makeReadyPrivacyContainer()
        let writer = AppWriteActor(modelContainer: container)
        let initial = try await AppReadActor(
            modelContainer: container
        ).privacyControlSnapshot()
        let operationID = UUID()
        let command = SetAppLockCommand(
            operationID: operationID,
            expectedLocalRevision: initial.localRevision,
            expectedDigestHex: initial.digestHex,
            isEnabled: true,
            committedAt: Date(timeIntervalSince1970: 1_800_000_010)
        )

        let first = try await writer.setAppLock(command)
        let replay = try await writer.setAppLock(command)

        XCTAssertTrue(first.didApply)
        XCTAssertFalse(replay.didApply)
        XCTAssertTrue(first.snapshot.appLockEnabled)
        XCTAssertEqual(first.snapshot.lastOperationID, operationID)
        XCTAssertEqual(replay.snapshot, first.snapshot)

        let context = ModelContext(container)
        let receipt = try XCTUnwrap(
            context.fetch(FetchDescriptor<OperationReceiptRecord>())
                .first { $0.operationID == operationID }
        )
        XCTAssertEqual(receipt.resultRecordType, "PrivacyControlRecord")
        XCTAssertEqual(
            receipt.resultRecordID,
            PrivacyControlRecord.stableID
        )
    }

    func testHistoricalReplayReturnsCurrentHeadWithoutRewinding() async throws {
        let container = try makeReadyPrivacyContainer()
        let reader = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let initial = try await reader.privacyControlSnapshot()
        let enable = SetAppLockCommand(
            operationID: UUID(),
            expectedLocalRevision: initial.localRevision,
            expectedDigestHex: initial.digestHex,
            isEnabled: true,
            committedAt: Date(timeIntervalSince1970: 1_800_000_020)
        )
        let enabled = try await writer.setAppLock(enable).snapshot
        let disable = SetAppLockCommand(
            operationID: UUID(),
            expectedLocalRevision: enabled.localRevision,
            expectedDigestHex: enabled.digestHex,
            isEnabled: false,
            committedAt: Date(timeIntervalSince1970: 1_800_000_030)
        )
        let disabled = try await writer.setAppLock(disable).snapshot

        let replay = try await writer.setAppLock(enable)

        XCTAssertFalse(replay.didApply)
        XCTAssertEqual(replay.snapshot, disabled)
        XCTAssertFalse(replay.snapshot.appLockEnabled)
        XCTAssertEqual(
            replay.snapshot.lastOperationID,
            disable.operationID
        )
    }

    func testSetAppLockRejectsStaleAndConflictingCommands() async throws {
        let container = try makeReadyPrivacyContainer()
        let reader = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let initial = try await reader.privacyControlSnapshot()
        let operationID = UUID()
        let applied = SetAppLockCommand(
            operationID: operationID,
            expectedLocalRevision: initial.localRevision,
            expectedDigestHex: initial.digestHex,
            isEnabled: true,
            committedAt: Date(timeIntervalSince1970: 1_800_000_040)
        )
        _ = try await writer.setAppLock(applied)

        do {
            _ = try await writer.setAppLock(
                SetAppLockCommand(
                    operationID: operationID,
                    expectedLocalRevision: initial.localRevision,
                    expectedDigestHex: initial.digestHex,
                    isEnabled: false,
                    committedAt: applied.committedAt
                )
            )
            XCTFail("同一 operationID 的不同命令必须冲突")
        } catch let error as PrivacyControlWriteFailure {
            XCTAssertEqual(error, .operationConflict)
        }

        do {
            _ = try await writer.setAppLock(
                SetAppLockCommand(
                    operationID: UUID(),
                    expectedLocalRevision: initial.localRevision,
                    expectedDigestHex: initial.digestHex,
                    isEnabled: false,
                    committedAt: Date(timeIntervalSince1970: 1_800_000_050)
                )
            )
            XCTFail("陈旧 token 不得覆盖当前事实")
        } catch let error as PrivacyControlWriteFailure {
            XCTAssertEqual(error, .staleRecord)
        }
    }

    func testInjectedFailureRollsBackPrivacyReceiptAndRevision() async throws {
        let container = try makeReadyPrivacyContainer()
        let reader = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let initial = try await reader.privacyControlSnapshot()
        let context = ModelContext(container)
        let operationID = UUID()
        let revisionCount = try context.fetchCount(
            FetchDescriptor<RecordRevision>()
        )

        do {
            _ = try await writer.setAppLock(
                SetAppLockCommand(
                    operationID: operationID,
                    expectedLocalRevision: initial.localRevision,
                    expectedDigestHex: initial.digestHex,
                    isEnabled: true,
                    committedAt: Date(timeIntervalSince1970: 1_800_000_060)
                ),
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("注入故障必须回滚")
        } catch let error as AppWriteFailure {
            XCTAssertEqual(error, .injected)
        }

        let afterFailure = try await reader.privacyControlSnapshot()
        XCTAssertEqual(afterFailure, initial)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<RecordRevision>()),
            revisionCount
        )
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<OperationReceiptRecord>())
                .contains { $0.operationID == operationID }
        )
    }

    func testValidatorRejectsReceiptMovedOutsidePrivacyMutationRevision()
        async throws {
        let container = try makeReadyPrivacyContainer()
        let reader = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let initial = try await reader.privacyControlSnapshot()
        let operationID = UUID()
        _ = try await writer.setAppLock(
            SetAppLockCommand(
                operationID: operationID,
                expectedLocalRevision: initial.localRevision,
                expectedDigestHex: initial.digestHex,
                isEnabled: true
            )
        )
        let context = ModelContext(container)
        let receiptKey = "OperationReceiptRecord:"
            + operationID.uuidString.lowercased()
        let receiptRevision = try XCTUnwrap(
            context.fetch(FetchDescriptor<RecordRevision>())
                .first { $0.recordKey == receiptKey }
        )
        receiptRevision.localRevision += 1_000
        try context.save()

        XCTAssertThrowsError(
            try PrivacyControlRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testHistoricalReplayRejectsTamperedReceiptRevision()
        async throws {
        let container = try makeReadyPrivacyContainer()
        let reader = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let initial = try await reader.privacyControlSnapshot()
        let enable = SetAppLockCommand(
            operationID: UUID(),
            expectedLocalRevision: initial.localRevision,
            expectedDigestHex: initial.digestHex,
            isEnabled: true,
            committedAt: Date(timeIntervalSince1970: 1_800_000_070)
        )
        let enabled = try await writer.setAppLock(enable).snapshot
        _ = try await writer.setAppLock(
            SetAppLockCommand(
                operationID: UUID(),
                expectedLocalRevision: enabled.localRevision,
                expectedDigestHex: enabled.digestHex,
                isEnabled: false,
                committedAt: Date(timeIntervalSince1970: 1_800_000_080)
            )
        )

        let context = ModelContext(container)
        let receiptKey = "OperationReceiptRecord:"
            + enable.operationID.uuidString.lowercased()
        let receiptRevision = try XCTUnwrap(
            context.fetch(FetchDescriptor<RecordRevision>())
                .first { $0.recordKey == receiptKey }
        )
        receiptRevision.localRevision += 100_000
        try context.save()

        do {
            _ = try await writer.setAppLock(enable)
            XCTFail("损坏的历史 receipt revision 不得通过 replay")
        } catch let error as AppDataFailure {
            XCTAssertEqual(error, .corruptionSuspected)
        }
    }

    func testPrivacyWriteRejectsReceiptLedgerTampering() async throws {
        enum TamperCase: CaseIterable {
            case count
            case setDigest
            case revision
        }

        for tamper in TamperCase.allCases {
            let container = try makeReadyPrivacyContainer()
            let reader = AppReadActor(modelContainer: container)
            let writer = AppWriteActor(modelContainer: container)
            let initial = try await reader.privacyControlSnapshot()
            _ = try await writer.setAppLock(
                SetAppLockCommand(
                    operationID: UUID(),
                    expectedLocalRevision: initial.localRevision,
                    expectedDigestHex: initial.digestHex,
                    isEnabled: true
                )
            )
            let context = ModelContext(container)
            let ledger = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<OperationReceiptLedgerRecord>()
                ).first
            )
            let ledgerRevision = try XCTUnwrap(
                context.fetch(FetchDescriptor<RecordRevision>())
                    .first {
                        $0.recordType
                            == "OperationReceiptLedgerRecord"
                    }
            )
            switch tamper {
            case .count:
                ledger.receiptCount += 1
                ledgerRevision.digestHex =
                    try RecordDigestV1.sha256Hex(
                        recordType:
                            "OperationReceiptLedgerRecord",
                        recordID:
                            TodayExecutionDigestV1.receiptLedgerID,
                        fields: TodayExecutionDigestV1
                            .operationReceiptLedger(ledger)
                    )
            case .setDigest:
                ledger.receiptSetDigest =
                    String(repeating: "b", count: 64)
                ledgerRevision.digestHex =
                    try RecordDigestV1.sha256Hex(
                        recordType:
                            "OperationReceiptLedgerRecord",
                        recordID:
                            TodayExecutionDigestV1.receiptLedgerID,
                        fields: TodayExecutionDigestV1
                            .operationReceiptLedger(ledger)
                    )
            case .revision:
                XCTAssertGreaterThan(ledgerRevision.localRevision, 1)
                ledgerRevision.localRevision -= 1
            }
            try context.save()

            do {
                let current = try await reader
                    .privacyControlSnapshot()
                _ = try await writer.setAppLock(
                    SetAppLockCommand(
                        operationID: UUID(),
                        expectedLocalRevision:
                            current.localRevision,
                        expectedDigestHex: current.digestHex,
                        isEnabled: false
                    )
                )
                XCTFail("\(tamper) ledger 篡改不得被新写入掩盖")
            } catch let error as AppDataFailure {
                XCTAssertEqual(error, .corruptionSuspected)
            }
        }
    }

    private func makePrivacyContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryPrivacyControlContainer()
        _ = try LegacyV1Backfill.run(in: container)
        return container
    }

    private func makeReadyPrivacyContainer() throws -> ModelContainer {
        let container = try makePrivacyContainer()
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        _ = try CountdownLifecycleBackfill.run(in: container)
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
        return container
    }
}
