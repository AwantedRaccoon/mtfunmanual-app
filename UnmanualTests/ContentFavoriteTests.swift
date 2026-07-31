import Foundation
import SwiftData
import XCTest
@testable import Unmanual

private enum ConcurrentFavoriteWriteOutcome: Equatable, Sendable {
    case applied(UUID)
    case rejected(ContentFavoriteWriteFailure)
    case unexpected
}

private func concurrentFavoriteWriteOutcome(
    _ command: SetContentFavoriteCommand,
    using writer: AppDataWriter
) async -> ConcurrentFavoriteWriteOutcome {
    do {
        let result = try await writer.setContentFavorite(command)
        return .applied(result.snapshot.id)
    } catch let error as ContentFavoriteWriteFailure {
        return .rejected(error)
    } catch {
        return .unexpected
    }
}

@MainActor
final class ContentFavoriteTests: XCTestCase {
    private let version = "offline-contextual-content-candidate.1"
    private let digest =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func testV13AddsOnlyContentFavoriteRecordAfterFrozenV12Models() {
        XCTAssertEqual(AppSchemaV12DataControl.models.count, 54)
        XCTAssertEqual(AppSchemaV13ContentFavorite.models.count, 55)
        XCTAssertEqual(
            AppSchemaV13ContentFavorite.models.dropLast().map {
                String(describing: $0)
            },
            AppSchemaV12DataControl.models.map {
                String(describing: $0)
            }
        )
        XCTAssertEqual(
            String(
                describing:
                    try XCTUnwrap(
                        AppSchemaV13ContentFavorite.models.last
                    )
            ),
            "ContentFavoriteRecord"
        )
    }

    func testFavoriteWriteCancelRefavoriteAndExactReplay() async throws {
        let container = try makeReadyContainer()
        let reader = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let recordID = UUID()
        let operationID = UUID()
        let first = SetContentFavoriteCommand(
            operationID: operationID,
            recordID: recordID,
            contentID: "card.alpha",
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: true,
            expectedLocalRevision: nil,
            expectedDigestHex: nil,
            committedAt: Date(timeIntervalSince1970: 1_800_200_010)
        )

        let applied = try await writer.setContentFavorite(first)
        let replay = try await writer.setContentFavorite(first)

        XCTAssertTrue(applied.didApply)
        XCTAssertFalse(replay.didApply)
        XCTAssertTrue(applied.snapshot.isFavorite)
        XCTAssertEqual(applied.snapshot.id, recordID)
        XCTAssertEqual(replay.snapshot, applied.snapshot)
        let activeAfterFavorite =
            try await reader.activeContentFavoriteIDs()
        XCTAssertEqual(activeAfterFavorite, ["card.alpha"])

        let cancel = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: recordID,
            contentID: "card.alpha",
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: false,
            expectedLocalRevision: applied.snapshot.localRevision,
            expectedDigestHex: applied.snapshot.digestHex,
            committedAt: Date(timeIntervalSince1970: 1_800_200_020)
        )
        let removed = try await writer.setContentFavorite(cancel).snapshot
        XCTAssertFalse(removed.isFavorite)
        XCTAssertNotNil(removed.removedAt)
        XCTAssertEqual(removed.createdAt, applied.snapshot.createdAt)
        XCTAssertEqual(removed.contentVersion, version)
        XCTAssertEqual(removed.cardDigest, digest)
        let activeAfterRemoval =
            try await reader.activeContentFavoriteIDs()
        XCTAssertEqual(activeAfterRemoval, [])

        let nextDigest =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let restore = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: recordID,
            contentID: "card.alpha",
            contentVersion: "offline-contextual-content-candidate.2",
            cardDigest: nextDigest,
            desiredFavorite: true,
            expectedLocalRevision: removed.localRevision,
            expectedDigestHex: removed.digestHex,
            committedAt: Date(timeIntervalSince1970: 1_800_200_030)
        )
        let restored = try await writer
            .setContentFavorite(restore).snapshot
        XCTAssertTrue(restored.isFavorite)
        XCTAssertNil(restored.removedAt)
        XCTAssertEqual(restored.contentVersion, restore.contentVersion)
        XCTAssertEqual(restored.cardDigest, nextDigest)
        XCTAssertEqual(restored.createdAt, applied.snapshot.createdAt)
    }

    func testFavoriteWriteRejectsConflictStaleAndNonMonotonicTime()
        async throws {
        let container = try makeReadyContainer()
        let writer = AppWriteActor(modelContainer: container)
        let first = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: UUID(),
            contentID: "card.alpha",
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: true,
            expectedLocalRevision: nil,
            expectedDigestHex: nil,
            committedAt: Date(timeIntervalSince1970: 1_800_200_100)
        )
        let applied = try await writer.setContentFavorite(first).snapshot

        await assertWriteFailure(
            .operationConflict,
            command: SetContentFavoriteCommand(
                operationID: UUID(),
                recordID: UUID(),
                contentID: first.contentID,
                contentVersion: version,
                cardDigest: digest,
                desiredFavorite: true,
                expectedLocalRevision: nil,
                expectedDigestHex: nil,
                committedAt: Date(timeIntervalSince1970: 1_800_200_110)
            ),
            writer: writer
        )
        await assertWriteFailure(
            .staleRecord,
            command: SetContentFavoriteCommand(
                operationID: UUID(),
                recordID: first.recordID,
                contentID: first.contentID,
                contentVersion: version,
                cardDigest: digest,
                desiredFavorite: false,
                expectedLocalRevision:
                    applied.localRevision + 1,
                expectedDigestHex: applied.digestHex,
                committedAt: Date(timeIntervalSince1970: 1_800_200_120)
            ),
            writer: writer
        )
        await assertWriteFailure(
            .invalidInput,
            command: SetContentFavoriteCommand(
                operationID: UUID(),
                recordID: first.recordID,
                contentID: first.contentID,
                contentVersion: version,
                cardDigest: digest,
                desiredFavorite: false,
                expectedLocalRevision: applied.localRevision,
                expectedDigestHex: nil,
                committedAt: Date(timeIntervalSince1970: 1_800_200_120)
            ),
            writer: writer
        )
        await assertWriteFailure(
            .invalidInput,
            command: SetContentFavoriteCommand(
                operationID: UUID(),
                recordID: first.recordID,
                contentID: first.contentID,
                contentVersion: version,
                cardDigest: digest,
                desiredFavorite: false,
                expectedLocalRevision: applied.localRevision,
                expectedDigestHex: applied.digestHex,
                committedAt: Date(timeIntervalSince1970: 1_800_200_090)
            ),
            writer: writer
        )
    }

    func testInjectedFailureRollsBackFactRevisionReceiptAndMetadata()
        async throws {
        let container = try makeReadyContainer()
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let beforeRevision = metadata.nextLocalRevision
        let beforeReceiptCount = try context.fetchCount(
            FetchDescriptor<OperationReceiptRecord>()
        )
        let writer = AppWriteActor(modelContainer: container)

        do {
            _ = try await writer.setContentFavorite(
                SetContentFavoriteCommand(
                    operationID: UUID(),
                    recordID: UUID(),
                    contentID: "card.alpha",
                    contentVersion: version,
                    cardDigest: digest,
                    desiredFavorite: true,
                    expectedLocalRevision: nil,
                    expectedDigestHex: nil,
                    committedAt:
                        Date(timeIntervalSince1970: 1_800_200_200)
                ),
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("注入故障必须回滚整个事务")
        } catch let error as AppWriteFailure {
            XCTAssertEqual(error, .injected)
        }

        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<ContentFavoriteRecord>()
            ),
            0
        )
        XCTAssertEqual(metadata.nextLocalRevision, beforeRevision)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<OperationReceiptRecord>()
            ),
            beforeReceiptCount
        )
    }

    func testRelationshipValidatorRejectsDigestAndReceiptTampering()
        async throws {
        for tamperReceipt in [false, true] {
            let container = try makeReadyContainer()
            let writer = AppWriteActor(modelContainer: container)
            let command = SetContentFavoriteCommand(
                operationID: UUID(),
                recordID: UUID(),
                contentID: "card.alpha",
                contentVersion: version,
                cardDigest: digest,
                desiredFavorite: true,
                expectedLocalRevision: nil,
                expectedDigestHex: nil,
                committedAt: Date(timeIntervalSince1970: 1_800_200_300)
            )
            _ = try await writer.setContentFavorite(command)
            let context = ModelContext(container)
            if tamperReceipt {
                let receipt = try XCTUnwrap(
                    context.fetch(
                        FetchDescriptor<OperationReceiptRecord>()
                    ).first {
                        $0.operationID == command.operationID
                    }
                )
                receipt.resultRecordID = UUID()
            } else {
                let revision = try XCTUnwrap(
                    context.fetch(
                        FetchDescriptor<RecordRevision>()
                    ).first {
                        $0.recordType == "ContentFavoriteRecord"
                    }
                )
                revision.digestHex = String(repeating: "c", count: 64)
            }
            try context.save()

            XCTAssertThrowsError(
                try ContentFavoriteRelationshipValidator.validate(
                    in: context
                )
            ) {
                XCTAssertEqual(
                    $0 as? AppDataFailure,
                    .corruptionSuspected
                )
            }
        }
    }

    func testNonNFCContentVersionIsRejectedByContractAndWriter()
        async throws {
        let nonNFC = "candidate-e\u{301}"
        XCTAssertFalse(
            nonNFC.utf8.elementsEqual(
                nonNFC.precomposedStringWithCanonicalMapping.utf8
            )
        )
        XCTAssertFalse(
            ContentFavoriteContract.isValidContentVersion(nonNFC)
        )

        let writer = AppWriteActor(
            modelContainer: try makeReadyContainer()
        )
        await assertWriteFailure(
            .invalidInput,
            command: SetContentFavoriteCommand(
                operationID: UUID(),
                recordID: UUID(),
                contentID: "card.non-nfc",
                contentVersion: nonNFC,
                cardDigest: digest,
                desiredFavorite: true,
                expectedLocalRevision: nil,
                expectedDigestHex: nil,
                committedAt: Date(
                    timeIntervalSince1970: 1_800_200_400
                )
            ),
            writer: writer
        )
    }

    func testTwoWritersRacingSameContentCreateOneFact()
        async throws {
        let container = try makeReadyContainer()
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let firstWriter = AppDataWriter(
            storage: AppWriteActor(modelContainer: container),
            dataControlCoordinator: coordinator,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let secondWriter = AppDataWriter(
            storage: AppWriteActor(modelContainer: container),
            dataControlCoordinator: coordinator,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let first = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: UUID(),
            contentID: "card.concurrent",
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: true,
            expectedLocalRevision: nil,
            expectedDigestHex: nil,
            committedAt: Date(
                timeIntervalSince1970: 1_800_200_500
            )
        )
        let second = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: UUID(),
            contentID: first.contentID,
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: true,
            expectedLocalRevision: nil,
            expectedDigestHex: nil,
            committedAt: first.committedAt
        )

        async let firstOutcome = concurrentFavoriteWriteOutcome(
            first,
            using: firstWriter
        )
        async let secondOutcome = concurrentFavoriteWriteOutcome(
            second,
            using: secondWriter
        )
        let outcomes = await [firstOutcome, secondOutcome]

        XCTAssertEqual(
            outcomes.filter {
                if case .applied = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            outcomes.filter {
                $0 == .rejected(.operationConflict)
            }.count,
            1
        )
        let snapshots = try await AppReadActor(
            modelContainer: container
        ).contentFavoriteSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.contentID, first.contentID)
        XCTAssertTrue(snapshots.first?.isFavorite == true)

        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<ContentFavoriteRecord>()
            ),
            1
        )
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            ).filter {
                $0.operationID == first.operationID
                    || $0.operationID == second.operationID
            }.count,
            1
        )
    }

    func testFileBackedFavoriteSurvivesV13Reopen()
        async throws {
        let layout = try makeFileBackedLayout()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        let opened = try bootstrapper.open()
        let command = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: UUID(),
            contentID: "card.reopen",
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: true,
            expectedLocalRevision: nil,
            expectedDigestHex: nil,
            committedAt: Date(
                timeIntervalSince1970: 1_800_200_600
            )
        )
        let applied = try await AppWriteActor(
            modelContainer: opened.container
        ).setContentFavorite(command).snapshot

        let reopened = try bootstrapper.open()
        XCTAssertEqual(reopened.generationID, opened.generationID)
        XCTAssertEqual(
            try GenerationPointerStore(layout: layout)
                .read().schemaVersion,
            PortableDataSchemaContract.v13.schemaVersion
        )
        let snapshots = try await AppReadActor(
            modelContainer: reopened.container
        ).contentFavoriteSnapshots()
        XCTAssertEqual(snapshots, [applied])
        XCTAssertNoThrow(
            try AppDataStoreBootstrapper(
                layout: layout
            ).validateV13DataInventoryFoundation(
                in: ModelContext(reopened.container)
            )
        )
    }

    private func makeReadyContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryContentFavoriteContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        _ = try CountdownLifecycleBackfill.run(in: container)
        _ = try CountdownIntegrityBackfill.run(in: container)
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

    private func makeFileBackedLayout() throws
        -> AppDataStoreLayout {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let fixtureRoot = applicationSupport.appending(
            path:
                "UnmanualContentFavoriteTests-"
                + UUID().uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        return AppDataStoreLayout(
            rootURL: fixtureRoot.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            ),
            legacyStoreURL:
                fixtureRoot.appending(path: "default.store")
        )
    }

    private func assertWriteFailure(
        _ expected: ContentFavoriteWriteFailure,
        command: SetContentFavoriteCommand,
        writer: AppWriteActor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await writer.setContentFavorite(command)
            XCTFail(
                "命令应被拒绝为 \(expected)",
                file: file,
                line: line
            )
        } catch let error as ContentFavoriteWriteFailure {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail(
                "错误类型不符：\(error)",
                file: file,
                line: line
            )
        }
    }
}
