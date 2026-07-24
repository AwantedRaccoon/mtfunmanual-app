import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Unmanual

@MainActor
final class PersonalTimelineFeatureTests: XCTestCase {
    func testJourneyEntryAtomicallyCreatesAttachmentMetadata() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let entryID = UUID()
        let attachmentID = UUID()
        let attachmentOperationID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_735_732_860)

        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "带附件的普通记录",
                kind: .moment,
                occurredAt: occurredAt,
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC",
                committedAt: occurredAt,
                attachments: [
                    PreparedAttachmentMetadata(
                        operationID: attachmentOperationID,
                        attachmentID: attachmentID,
                        relativePath:
                            "Attachments/\(attachmentID.uuidString.lowercased())/payload.pdf",
                        originalFilename: "记录.pdf",
                        typeIdentifier: UTType.pdf.identifier,
                        byteCount: 3,
                        sha256Hex: String(repeating: "a", count: 64)
                    )
                ]
            )
        )

        let snapshot = try await reader.todaySnapshot()
        XCTAssertEqual(snapshot.entries.map(\.id), [entryID])
        let attachments = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertEqual(attachments.map(\.id), [attachmentID])
        XCTAssertEqual(attachments.first?.originalFilename, "记录.pdf")
    }

    func testAttachmentMutationServiceClosesJourneyFileAndDatabaseTransaction() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Journey-Attachment-Service-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = AttachmentFileStore(rootURL: root)
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            onRecoveryRequired: {}
        )
        let entryID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_735_732_860)

        try await service.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "带真实文件的普通记录",
                kind: .moment,
                occurredAt: occurredAt,
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC",
                committedAt: occurredAt
            ),
            attachmentDrafts: [
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46]),
                    filename: "记录.pdf",
                    typeIdentifier: UTType.pdf.identifier
                )
            ]
        )

        let attachments = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertEqual(attachments.count, 1)
        XCTAssertNoThrow(try fileStore.audit(attachments))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(".staging", isDirectory: true),
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testAttachmentMutationServiceSerializesAcrossActorReentrancy() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let gate = AttachmentMutationGate()
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: {
                await gate.block()
                return true
            },
            onProtectionFailure: {}
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Mutation-Lease-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: AttachmentFileStore(rootURL: root),
            onRecoveryRequired: {}
        )
        let first = Task {
            try await service.addJourneyEntry(
                AddJourneyEntryCommand(
                    text: "第一笔",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: [
                    AttachmentDraft(
                        data: Data([0x25, 0x50, 0x44, 0x46]),
                        filename: "第一笔.pdf",
                        typeIdentifier: UTType.pdf.identifier
                    )
                ]
            )
        }
        await gate.waitUntilBlocked()

        do {
            try await service.addJourneyEntry(
                AddJourneyEntryCommand(
                    text: "第二笔",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_861),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: [
                    AttachmentDraft(
                        data: Data([0x25, 0x50, 0x44, 0x46]),
                        filename: "第二笔.pdf",
                        typeIdentifier: UTType.pdf.identifier
                    )
                ]
            )
            XCTFail("A reentrant mutation must not overlap the active transaction")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .mutationInProgress
            )
        }

        await gate.release()
        try await first.value
    }

    func testAttachmentMutationServiceRequiresRecoveryWhenDatabaseRollbackCleanupFails() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Journey-Attachment-Recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = AttachmentFileStore(
            rootURL: root,
            failureInjection: .discard
        )
        let recovery = AttachmentRecoveryRecorder()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            onRecoveryRequired: {
                await recovery.record()
            }
        )

        do {
            try await service.addJourneyEntry(
                AddJourneyEntryCommand(
                    text: "   ",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: [
                    AttachmentDraft(
                        data: Data([0x25, 0x50, 0x44, 0x46]),
                        filename: "记录.pdf",
                        typeIdentifier: UTType.pdf.identifier
                    )
                ]
            )
            XCTFail("Cleanup failure must not return a retryable save error")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .recoveryRequired
            )
        }
        let recoveryCount = await recovery.callCount()
        XCTAssertEqual(recoveryCount, 1)
    }

    func testAttachmentMutationServiceRequiresRecoveryWhenPostCommitFinalizationFails() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Post-Commit-Recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = AttachmentFileStore(
            rootURL: root,
            failureInjection: .markMetadataCommitted
        )
        let recovery = AttachmentRecoveryRecorder()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            onRecoveryRequired: {
                await recovery.record()
            }
        )
        let entryID = UUID()

        do {
            try await service.addJourneyEntry(
                AddJourneyEntryCommand(
                    recordID: entryID,
                    text: "数据库已提交但 journal 收尾失败",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: [
                    AttachmentDraft(
                        data: Data([0x25, 0x50, 0x44, 0x46]),
                        filename: "报告.pdf",
                        typeIdentifier: UTType.pdf.identifier
                    )
                ]
            )
            XCTFail("Post-commit finalization failure must require Recovery")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .recoveryRequired
            )
        }

        let committed = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertEqual(committed.count, 1)
        let recoveryCount = await recovery.callCount()
        XCTAssertEqual(recoveryCount, 1)
    }

    func testAttachmentMutationServicePreviewLeaseBlocksDeletionUntilReleased() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Preview-Lease-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = AttachmentFileStore(rootURL: root)
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            onRecoveryRequired: {}
        )
        let entryID = UUID()
        try await service.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "预览期间不能删除",
                kind: .moment,
                occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC"
            ),
            attachmentDrafts: [
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46]),
                    filename: "记录.pdf",
                    typeIdentifier: UTType.pdf.identifier
                )
            ]
        )
        let savedAttachments = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        let attachment = try XCTUnwrap(savedAttachments.first)

        let previewURL = try await service.beginPreview(attachment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))
        do {
            try await service.deleteAttachment(attachment)
            XCTFail("An active preview lease must block deletion")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .previewInProgress
            )
        }

        await service.endPreview(attachmentID: attachment.id)
        try await service.deleteAttachment(attachment)
        let remaining = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
    }

    func testSequentialPreviewAdmissionReleasesBothLeasesBeforeDeletion() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Sequential-Preview-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: AttachmentFileStore(rootURL: root),
            onRecoveryRequired: {}
        )
        let entryID = UUID()
        try await service.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "两个附件依次预览",
                kind: .moment,
                occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC"
            ),
            attachmentDrafts: [
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46, 0x01]),
                    filename: "first.pdf",
                    typeIdentifier: UTType.pdf.identifier
                ),
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46, 0x02]),
                    filename: "second.pdf",
                    typeIdentifier: UTType.pdf.identifier
                ),
            ]
        )
        let attachments = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertEqual(attachments.count, 2)
        let first = attachments[0]
        let second = attachments[1]

        _ = try await service.beginPreview(first)
        XCTAssertFalse(
            AttachmentPreviewAdmission.canBegin(
                isRequestInFlight: false,
                presentedAttachmentID: first.id
            )
        )
        await service.endPreview(attachmentID: first.id)

        XCTAssertTrue(
            AttachmentPreviewAdmission.canBegin(
                isRequestInFlight: false,
                presentedAttachmentID: nil
            )
        )
        _ = try await service.beginPreview(second)
        await service.endPreview(attachmentID: second.id)

        try await service.deleteAttachment(first)
        try await service.deleteAttachment(second)
        let remaining = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testActivePreviewGloballyBlocksAnotherPreviewAndDeletionUntilReleased() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Global-Preview-Lease-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: AttachmentFileStore(rootURL: root),
            onRecoveryRequired: {}
        )
        let entryID = UUID()
        try await service.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "预览释放前全局阻塞",
                kind: .moment,
                occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC"
            ),
            attachmentDrafts: [
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46, 0x01]),
                    filename: "first.pdf",
                    typeIdentifier: UTType.pdf.identifier
                ),
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46, 0x02]),
                    filename: "second.pdf",
                    typeIdentifier: UTType.pdf.identifier
                ),
            ]
        )
        let attachments = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertEqual(attachments.count, 2)
        let first = attachments[0]
        let second = attachments[1]

        _ = try await service.beginPreview(first)

        do {
            _ = try await service.beginPreview(second)
            await service.endPreview(attachmentID: second.id)
            XCTFail("An active preview must block a different preview")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .mutationInProgress
            )
        }

        do {
            try await service.deleteAttachment(second)
            XCTFail("An active preview must block deletion of another attachment")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .previewInProgress
            )
        }

        await service.endPreview(attachmentID: first.id)
        _ = try await service.beginPreview(second)
        await service.endPreview(attachmentID: second.id)

        try await service.deleteAttachment(first)
        try await service.deleteAttachment(second)
        let remaining = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testExternallyInvalidatedAttachmentServiceRejectsMutationPreviewAndDelete() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-External-Recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryLatch = AttachmentMutationRecoveryLatch()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: AttachmentFileStore(rootURL: root),
            recoveryLatch: recoveryLatch,
            onRecoveryRequired: {}
        )
        let attachment = AttachmentSnapshot(
            id: UUID(),
            ownerType: .journeyEntry,
            ownerID: UUID(),
            relativePath: "Attachments/placeholder/file.pdf",
            originalFilename: "file.pdf",
            typeIdentifier: UTType.pdf.identifier,
            byteCount: 1,
            sha256Hex: String(repeating: "0", count: 64),
            createdAt: Date()
        )

        recoveryLatch.invalidate()

        do {
            try await service.addJourneyEntry(
                AddJourneyEntryCommand(
                    text: "不应写入",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: []
            )
            XCTFail("Mutation must be rejected after external Recovery")
        } catch {
            XCTAssertEqual(error as? AttachmentMutationFailure, .recoveryRequired)
        }
        do {
            _ = try await service.beginPreview(attachment)
            XCTFail("Preview must be rejected after external Recovery")
        } catch {
            XCTAssertEqual(error as? AttachmentMutationFailure, .recoveryRequired)
        }
        do {
            try await service.deleteAttachment(attachment)
            XCTFail("Delete must be rejected after external Recovery")
        } catch {
            XCTAssertEqual(error as? AttachmentMutationFailure, .recoveryRequired)
        }
    }

    func testExternalRecoveryDuringCommittedMutationFinalizesFilesButDoesNotReturnSuccess() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let gate = AttachmentMutationGate()
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: {
                await gate.block()
                return true
            },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Inflight-Recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryLatch = AttachmentMutationRecoveryLatch()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: AttachmentFileStore(rootURL: root),
            recoveryLatch: recoveryLatch,
            onRecoveryRequired: {}
        )
        let entryID = UUID()
        let mutation = Task {
            try await service.addJourneyEntry(
                AddJourneyEntryCommand(
                    recordID: entryID,
                    text: "提交后进入 Recovery",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: [
                    AttachmentDraft(
                        data: Data([0x25, 0x50, 0x44, 0x46]),
                        filename: "报告.pdf",
                        typeIdentifier: UTType.pdf.identifier
                    )
                ]
            )
        }
        await gate.waitUntilBlocked()

        recoveryLatch.invalidate()
        await gate.release()

        do {
            try await mutation.value
            XCTFail("An in-flight mutation must not report success after Recovery")
        } catch {
            XCTAssertEqual(error as? AttachmentMutationFailure, .recoveryRequired)
        }
        let attachments = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertEqual(attachments.count, 1)
        let journalDirectory = root.appendingPathComponent(
            ".staging",
            isDirectory: true
        )
        let journalEntries = try FileManager.default.contentsOfDirectory(
            atPath: journalDirectory.path
        )
        XCTAssertTrue(journalEntries.isEmpty)
    }

    func testAttachmentMutationServiceRequiresRecoveryWhenDeletionRollbackFails() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Delete-Recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = AttachmentFileStore(
            rootURL: root,
            failureInjection: .rollbackDeletion
        )
        let recovery = AttachmentRecoveryRecorder()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            onRecoveryRequired: {
                await recovery.record()
            }
        )
        let sampleID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        _ = try await service.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: timestamp,
                newDefinitions: [],
                results: []
            ),
            attachmentDrafts: [
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46]),
                    filename: "唯一报告.pdf",
                    typeIdentifier: UTType.pdf.identifier
                )
            ]
        )
        let saved = try await reader.attachments(
            ownerType: .labSample,
            ownerID: sampleID
        )
        let attachment = try XCTUnwrap(saved.first)

        do {
            try await service.deleteAttachment(attachment)
            XCTFail("A failed rollback must require Recovery")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .recoveryRequired
            )
        }
        let recoveryCount = await recovery.callCount()
        XCTAssertEqual(recoveryCount, 1)
    }

    func testAttachmentMutationServiceRequiresRecoveryWhenDeletionFinalizationFails() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Delete-Finalization-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = AttachmentFileStore(
            rootURL: root,
            failureInjection: .finalizeDeletion
        )
        let recovery = AttachmentRecoveryRecorder()
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: fileStore,
            onRecoveryRequired: {
                await recovery.record()
            }
        )
        let entryID = UUID()
        try await service.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "删除收尾失败",
                kind: .moment,
                occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC"
            ),
            attachmentDrafts: [
                AttachmentDraft(
                    data: Data([0x25, 0x50, 0x44, 0x46]),
                    filename: "报告.pdf",
                    typeIdentifier: UTType.pdf.identifier
                )
            ]
        )
        let saved = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        let attachment = try XCTUnwrap(saved.first)

        do {
            try await service.deleteAttachment(attachment)
            XCTFail("Deletion finalization failure must require Recovery")
        } catch {
            XCTAssertEqual(
                error as? AttachmentMutationFailure,
                .recoveryRequired
            )
        }
        let remaining = try await reader.attachments(
            ownerType: .journeyEntry,
            ownerID: entryID
        )
        XCTAssertTrue(remaining.isEmpty)
        let recoveryCount = await recovery.callCount()
        XCTAssertEqual(recoveryCount, 1)
    }

    func testStatusMetricsAreCappedAndObservationsUseNeutralFourLevelScale() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        var metricIDs: [UUID] = []
        for name in ["精力", "情绪", "睡眠", "皮肤", "专注"] {
            let metricID = UUID()
            metricIDs.append(metricID)
            _ = try await writer.createStatusMetric(
                CreateStatusMetricCommand(
                    operationID: UUID(),
                    metricID: metricID,
                    displayName: name
                )
            )
        }
        do {
            _ = try await writer.createStatusMetric(
                CreateStatusMetricCommand(
                    operationID: UUID(),
                    displayName: "第六项"
                )
            )
            XCTFail("Only five active status metrics are allowed")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .activeMetricLimitReached)
        }

        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "Asia/Shanghai",
            precision: .minute,
            provenance: .userEntered
        )
        let observationID = UUID()
        _ = try await writer.recordStatusObservation(
            RecordStatusObservationCommand(
                operationID: UUID(),
                observationID: observationID,
                metricDefinitionID: metricIDs[0],
                ordinalLevel: 3,
                note: "下午记录",
                timestamp: timestamp,
                committedAt: timestamp.instant
            )
        )
        let snapshot = try await reader.statusObservation(id: observationID)
        XCTAssertEqual(snapshot?.metricNameSnapshot, "精力")
        XCTAssertEqual(snapshot?.ordinalLevel, 3)
        XCTAssertEqual(snapshot?.levelDisplayText, "第 3 级，共 4 级")
        XCTAssertEqual(snapshot?.note, "下午记录")

        do {
            _ = try await writer.recordStatusObservation(
                RecordStatusObservationCommand(
                    operationID: UUID(),
                    metricDefinitionID: metricIDs[0],
                    ordinalLevel: 5,
                    timestamp: timestamp
                )
            )
            XCTFail("Status ordinal must remain in 1...4")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .invalidInput)
        }
    }

    func testStatusObservationAtomicallyCreatesMetricAndAttachmentMetadata() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let metricID = UUID()
        let metricOperationID = UUID()
        let observationID = UUID()
        let attachmentID = UUID()
        let attachmentOperationID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let command = RecordStatusObservationCommand(
            operationID: UUID(),
            observationID: observationID,
            metricDefinitionID: metricID,
            newMetric: NewStatusMetricInput(
                operationID: metricOperationID,
                metricID: metricID,
                displayName: "精力"
            ),
            ordinalLevel: 3,
            note: "下午",
            timestamp: timestamp,
            attachments: [
                PreparedAttachmentMetadata(
                    operationID: attachmentOperationID,
                    attachmentID: attachmentID,
                    relativePath: "Attachments/\(attachmentID.uuidString.lowercased())/payload.pdf",
                    originalFilename: "report.pdf",
                    typeIdentifier: "com.adobe.pdf",
                    byteCount: 3,
                    sha256Hex: String(repeating: "a", count: 64)
                )
            ],
            committedAt: timestamp.instant
        )

        let first = try await writer.recordStatusObservation(command)
        let replay = try await writer.recordStatusObservation(command)
        let metrics = try await reader.statusMetrics()
        let observation = try await reader.statusObservation(id: observationID)
        let savedAttachments = try await reader.attachments(
            ownerType: .statusObservation,
            ownerID: observationID
        )
        XCTAssertTrue(first.didCreate)
        XCTAssertFalse(replay.didCreate)
        XCTAssertEqual(metrics.map(\.id), [metricID])
        XCTAssertEqual(observation?.metricNameSnapshot, "精力")
        XCTAssertEqual(savedAttachments.map(\.id), [attachmentID])
    }

    func testStatusAtomicCommandRejectsBadAttachmentWithoutPartialMetricOrObservation() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let metricID = UUID()
        let observationID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )

        do {
            _ = try await writer.recordStatusObservation(
                RecordStatusObservationCommand(
                    operationID: UUID(),
                    observationID: observationID,
                    metricDefinitionID: metricID,
                    newMetric: NewStatusMetricInput(
                        operationID: UUID(),
                        metricID: metricID,
                        displayName: "精力"
                    ),
                    ordinalLevel: 2,
                    timestamp: timestamp,
                    attachments: [
                        PreparedAttachmentMetadata(
                            operationID: UUID(),
                            attachmentID: UUID(),
                            relativePath: "../escape.pdf",
                            originalFilename: "report.pdf",
                            typeIdentifier: "com.adobe.pdf",
                            byteCount: 3,
                            sha256Hex: String(repeating: "a", count: 64)
                        )
                    ]
                )
            )
            XCTFail("Invalid attachment metadata must reject the whole status intent")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .invalidInput)
        }
        let metrics = try await reader.statusMetrics()
        let observation = try await reader.statusObservation(id: observationID)
        XCTAssertTrue(metrics.isEmpty)
        XCTAssertNil(observation)
    }

    func testAttachmentMetadataRejectsNonOpaqueLeafAndTypeMismatch() throws {
        let attachmentID = UUID()
        let base = PreparedAttachmentMetadata(
            operationID: UUID(),
            attachmentID: attachmentID,
            relativePath: "Attachments/\(attachmentID.uuidString.lowercased())/report.pdf",
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 3,
            sha256Hex: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try AttachmentMetadataFacts.normalize(base)) { error in
            XCTAssertEqual(
                error as? PersonalTimelineWriteFailure,
                .invalidInput
            )
        }

        let wrongExtension = PreparedAttachmentMetadata(
            operationID: base.operationID,
            attachmentID: attachmentID,
            relativePath: "Attachments/\(attachmentID.uuidString.lowercased())/payload.png",
            originalFilename: base.originalFilename,
            typeIdentifier: base.typeIdentifier,
            byteCount: base.byteCount,
            sha256Hex: base.sha256Hex
        )
        XCTAssertThrowsError(
            try AttachmentMetadataFacts.normalize(wrongExtension)
        ) { error in
            XCTAssertEqual(
                error as? PersonalTimelineWriteFailure,
                .invalidInput
            )
        }

        let noncanonicalType = PreparedAttachmentMetadata(
            operationID: base.operationID,
            attachmentID: attachmentID,
            relativePath: "Attachments/\(attachmentID.uuidString.lowercased())/payload.pdf",
            originalFilename: base.originalFilename,
            typeIdentifier: "com.adobe.PDF",
            byteCount: base.byteCount,
            sha256Hex: base.sha256Hex
        )
        XCTAssertEqual(
            try AttachmentMetadataFacts.normalize(noncanonicalType).typeIdentifier,
            UTType.pdf.identifier
        )
    }

    func testArchivingStatusMetricReleasesActiveSlotWithoutChangingHistory() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        var metricIDs: [UUID] = []
        for index in 1...5 {
            let result = try await writer.createStatusMetric(
                CreateStatusMetricCommand(
                    operationID: UUID(),
                    displayName: "指标 \(index)"
                )
            )
            metricIDs.append(result.metricID)
        }
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let observationID = UUID()
        _ = try await writer.recordStatusObservation(
            RecordStatusObservationCommand(
                operationID: UUID(),
                observationID: observationID,
                metricDefinitionID: metricIDs[0],
                ordinalLevel: 2,
                timestamp: timestamp
            )
        )

        let archiveCommand = ArchiveStatusMetricCommand(
            operationID: UUID(),
            metricID: metricIDs[0]
        )
        let archived = try await writer.archiveStatusMetric(archiveCommand)
        let archiveReplay = try await writer.archiveStatusMetric(archiveCommand)
        XCTAssertTrue(archived.didArchive)
        XCTAssertFalse(archiveReplay.didArchive)
        _ = try await writer.createStatusMetric(
            CreateStatusMetricCommand(
                operationID: UUID(),
                displayName: "替代指标"
            )
        )

        let historicalObservation = try await reader.statusObservation(id: observationID)
        let activeMetrics = try await reader.statusMetrics().filter { !$0.isArchived }
        XCTAssertEqual(historicalObservation?.metricNameSnapshot, "指标 1")
        XCTAssertEqual(activeMetrics.count, 5)
    }

    func testAttachmentFileStorePreservesBytesAndRecoversOrphanedFinal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let attachmentID = UUID()
        let bytes = Data([0x00, 0xFF, 0x12, 0x34, 0x56])
        let staged = try store.stage(
            data: bytes,
            attachmentID: attachmentID,
            originalFilename: "../化验单.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        XCTAssertEqual(staged.byteCount, Int64(bytes.count))
        XCTAssertEqual(staged.originalFilename, "化验单.pdf")
        let committed = try store.commit(staged)
        XCTAssertEqual(try Data(contentsOf: committed.fileURL), bytes)
        XCTAssertEqual(committed.fileURL.lastPathComponent, "payload.pdf")

        let report = try store.recover(committedAttachments: [:])
        XCTAssertEqual(report.removedOrphanCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.fileURL.path))
    }

    func testAttachmentRecoveryRemovesFinalWhenCrashOccursBeforeJournalPhaseAdvance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01, 0x02, 0x03]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        XCTAssertThrowsError(
            try store.commit(staged, failpoint: .afterFinalMoveBeforeJournal)
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .simulatedInterruption
            )
        }
        let finalURL = try store.fileURL(forRelativePath: staged.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))

        let report = try store.recover(committedAttachments: [:])
        XCTAssertEqual(report.removedOrphanCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testAttachmentRecoveryRemovesUnjournaledPrivateStagingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        try store.discard(operationID: staged.operationID)
        let orphanDirectory = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: orphanDirectory,
            withIntermediateDirectories: false
        )
        try Data([0x02]).write(
            to: orphanDirectory.appendingPathComponent("payload")
        )

        let report = try store.recover(committedAttachments: [:])
        XCTAssertEqual(report.removedOrphanCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
    }

    func testAttachmentRecoveryRejectsJournalFilenameOperationMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Journal-ID-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        let journalURL = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                staged.operationID.uuidString.lowercased() + ".json"
            )
        let mismatchedURL = journalURL
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try FileManager.default.moveItem(at: journalURL, to: mismatchedURL)

        XCTAssertThrowsError(
            try store.recover(committedAttachments: [:])
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
    }

    func testAttachmentRecoveryRejectsFinalFileWithoutMetadataOrJournal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Final-Orphan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01, 0x02]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        let committed = try store.commit(staged)
        let journalURL = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                staged.operationID.uuidString.lowercased() + ".json"
            )
        try FileManager.default.removeItem(at: journalURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: committed.fileURL.path)
        )

        XCTAssertThrowsError(
            try store.recover(committedAttachments: [:])
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
    }

    func testAttachmentRecoveryRejectsJournalWhoseExtensionDisagreesWithType() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Journal-Type-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        let journalURL = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                staged.operationID.uuidString.lowercased() + ".json"
            )
        let original = try String(contentsOf: journalURL, encoding: .utf8)
        let tampered = original.replacingOccurrences(
            of: "payload.pdf",
            with: "payload.exe"
        )
        try Data(tampered.utf8).write(to: journalURL, options: .atomic)

        XCTAssertThrowsError(
            try store.recover(committedAttachments: [:])
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
    }

    func testAttachmentCommitRejectsTamperedStagingBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Tampered-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01, 0x02]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        try Data([0x03, 0x04]).write(
            to: staged.stagingURL,
            options: [.atomic, .completeFileProtection]
        )

        XCTAssertThrowsError(try store.commit(staged)) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .integrityMismatch
            )
        }
        let finalURL = try store.fileURL(
            forRelativePath: staged.relativePath
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testAttachmentCommitRejectsOversizedStagingBeforeHashing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Commit-Size-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        let handle = try FileHandle(forWritingTo: staged.stagingURL)
        try handle.truncate(
            atOffset: UInt64(AttachmentFileStore.maximumFileBytes + 1)
        )
        try handle.close()

        XCTAssertThrowsError(try store.commit(staged)) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .fileTooLarge
            )
        }
    }

    func testAttachmentRecoveryRejectsCommittedImportIdentityMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Recover-Identity-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01, 0x02]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        _ = try store.commit(staged)
        let snapshot = AttachmentSnapshot(
            id: staged.attachmentID,
            ownerType: .labSample,
            ownerID: UUID(),
            relativePath: staged.relativePath,
            originalFilename: staged.originalFilename,
            typeIdentifier: staged.typeIdentifier,
            byteCount: staged.byteCount,
            sha256Hex: staged.sha256Hex,
            createdAt: Date()
        )

        XCTAssertThrowsError(
            try store.recover(
                committedAttachments: [
                    staged.attachmentID: AttachmentCommittedImport(
                        operationID: UUID(),
                        attachment: snapshot
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
    }

    func testAttachmentAuditedPreviewRejectsTamperedBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Preview-Audit-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01, 0x02]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        let committed = try store.commit(staged)
        try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))
        try Data([0x03, 0x04]).write(
            to: committed.fileURL,
            options: [.atomic, .completeFileProtection]
        )
        let snapshot = AttachmentSnapshot(
            id: staged.attachmentID,
            ownerType: .labSample,
            ownerID: UUID(),
            relativePath: staged.relativePath,
            originalFilename: staged.originalFilename,
            typeIdentifier: staged.typeIdentifier,
            byteCount: staged.byteCount,
            sha256Hex: staged.sha256Hex,
            createdAt: Date()
        )

        XCTAssertThrowsError(try store.auditedFileURL(for: snapshot)) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .integrityMismatch
            )
        }
    }

    func testAttachmentStageRejectsExistingFinalWithoutDeletingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Duplicate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let attachmentID = UUID()
        let bytes = Data([0x01, 0x02])
        let staged = try store.stage(
            data: bytes,
            attachmentID: attachmentID,
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        let committed = try store.commit(staged)
        try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))

        XCTAssertThrowsError(
            try store.stage(
                data: Data([0x03]),
                attachmentID: attachmentID,
                originalFilename: "replacement.pdf",
                typeIdentifier: "com.adobe.pdf"
            )
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
        XCTAssertEqual(try Data(contentsOf: committed.fileURL), bytes)
    }

    func testAttachmentMetadataCannotCommitBeforeFinalFileIsReady() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Phase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )

        XCTAssertThrowsError(
            try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
        try store.discard(operationID: staged.operationID)
    }

    func testAttachmentMetadataFinalizationRevalidatesFinalBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Finalize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01, 0x02]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        let committed = try store.commit(staged)
        try Data([0x03, 0x04]).write(
            to: committed.fileURL,
            options: [.atomic, .completeFileProtection]
        )

        XCTAssertThrowsError(
            try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .integrityMismatch
            )
        }
        let journalURL = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                staged.operationID.uuidString.lowercased() + ".json"
            )
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testAttachmentAuditRejectsOversizedFinalBeforeHashing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Audit-Size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let attachmentID = UUID()
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: attachmentID,
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        let committed = try store.commit(staged)
        try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))
        let handle = try FileHandle(forWritingTo: committed.fileURL)
        try handle.truncate(
            atOffset: UInt64(AttachmentFileStore.maximumFileBytes + 1)
        )
        try handle.close()

        XCTAssertThrowsError(
            try store.audit([
                AttachmentSnapshot(
                    id: attachmentID,
                    ownerType: .labSample,
                    ownerID: UUID(),
                    relativePath: staged.relativePath,
                    originalFilename: staged.originalFilename,
                    typeIdentifier: staged.typeIdentifier,
                    byteCount: staged.byteCount,
                    sha256Hex: staged.sha256Hex,
                    createdAt: Date()
                )
            ])
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .fileTooLarge
            )
        }
    }

    func testAttachmentOwnerCapacityRejectsBatchBeforeCreatingStagingFiles() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Owner-Limit-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let service = AttachmentMutationService(
            writer: writer,
            fileStore: store,
            onRecoveryRequired: {}
        )
        let twentyMiB = Data(
            repeating: 0x01,
            count: Int(AttachmentFileStore.maximumFileBytes)
        )
        let drafts = [
            AttachmentDraft(
                data: twentyMiB,
                filename: "one.pdf",
                typeIdentifier: UTType.pdf.identifier
            ),
            AttachmentDraft(
                data: twentyMiB,
                filename: "two.pdf",
                typeIdentifier: UTType.pdf.identifier
            ),
            AttachmentDraft(
                data: twentyMiB,
                filename: "three.pdf",
                typeIdentifier: UTType.pdf.identifier
            ),
            AttachmentDraft(
                data: Data([0x02]),
                filename: "overflow.pdf",
                typeIdentifier: UTType.pdf.identifier
            )
        ]

        do {
            try await service.addJourneyEntry(
                AddJourneyEntryCommand(
                    text: "容量门禁",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC"
                ),
                attachmentDrafts: drafts
            )
            XCTFail("Owner capacity must be checked before staging")
        } catch {
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .ownerLimitReached
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAttachmentRecoveryRejectsUnjournaledDeletionTrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let attachmentID = UUID()
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: attachmentID,
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        _ = try store.commit(staged)
        try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))
        let deletion = try store.stageDeletion(
            attachment: AttachmentSnapshot(
                id: attachmentID,
                ownerType: .labSample,
                ownerID: UUID(),
                relativePath: staged.relativePath,
                originalFilename: staged.originalFilename,
                typeIdentifier: staged.typeIdentifier,
                byteCount: staged.byteCount,
                sha256Hex: staged.sha256Hex,
                createdAt: Date()
            ),
            operationID: UUID()
        )
        let journalURL = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                deletion.operationID.uuidString.lowercased() + ".json"
            )
        try FileManager.default.removeItem(at: journalURL)

        XCTAssertThrowsError(
            try store.recover(
                committedAttachments: [
                    attachmentID: AttachmentCommittedImport(
                        operationID: staged.operationID,
                        attachment: deletion.attachment
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
    }

    func testAttachmentDeletionCannotFinalizePreparedJournal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Delete-Phase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let attachmentID = UUID()
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: attachmentID,
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        _ = try store.commit(staged)
        try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))
        let deletion = try store.stageDeletion(
            attachment: AttachmentSnapshot(
                id: attachmentID,
                ownerType: .labSample,
                ownerID: UUID(),
                relativePath: staged.relativePath,
                originalFilename: staged.originalFilename,
                typeIdentifier: staged.typeIdentifier,
                byteCount: staged.byteCount,
                sha256Hex: staged.sha256Hex,
                createdAt: Date()
            ),
            operationID: UUID()
        )
        let journalURL = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                deletion.operationID.uuidString.lowercased() + ".json"
            )
        let current = try String(contentsOf: journalURL, encoding: .utf8)
        let prepared = current.replacingOccurrences(
            of: "deletionStaged",
            with: "deletionPrepared"
        )
        try Data(prepared.utf8).write(to: journalURL, options: .atomic)

        XCTAssertThrowsError(
            try store.finalizeDeletion(deletion)
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }

        XCTAssertThrowsError(
            try store.recover(committedAttachments: [:])
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
    }

    func testAttachmentFileImportChecksSizeBeforeBoundedReadAndUsesActualType() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let pdfURL = root.appendingPathComponent("report.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdfURL)
        let payload = try AttachmentImportFacts.loadBoundedFile(at: pdfURL)
        XCTAssertEqual(payload.data, Data([0x25, 0x50, 0x44, 0x46]))
        XCTAssertEqual(payload.typeIdentifier, UTType.pdf.identifier)

        let oversizedURL = root.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(
            atOffset: UInt64(AttachmentFileStore.maximumFileBytes + 1)
        )
        try handle.close()
        XCTAssertThrowsError(
            try AttachmentImportFacts.loadBoundedFile(at: oversizedURL)
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .fileTooLarge
            )
        }
    }

    func testAttachmentImportPreservesHEICBytesAndTypeBeforeStaging() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-HEIC-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let originalBytes = Data([
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x63, 0x00, 0x00, 0x00, 0x00,
        ])
        let sourceURL = root.appendingPathComponent("original.heic")
        try originalBytes.write(to: sourceURL)

        let payload = try AttachmentImportFacts.loadBoundedFile(at: sourceURL)

        XCTAssertEqual(payload.data, originalBytes)
        XCTAssertEqual(payload.typeIdentifier, UTType.heic.identifier)
    }

    func testAttachmentFileImportWorkerAppliesOwnerCapacityOffMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Unmanual-Attachment-Import-Worker-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let first = root.appendingPathComponent("first.pdf")
        let second = root.appendingPathComponent("second.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: first)
        try Data([0x25, 0x50, 0x44, 0x46, 0x01]).write(to: second)

        let result = await AttachmentFileImportWorker.shared.load(
            urls: [first, second],
            existingByteCounts: Array(repeating: 1, count: 5)
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.filename, "first.pdf")
        XCTAssertEqual(result.failureCount, 1)
    }

    func testAttachmentProtectionAndBackupPolicyReadBackAcrossTransactionFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Protection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let staged = try store.stage(
            data: Data([0x01]),
            attachmentID: UUID(),
            originalFilename: "report.pdf",
            typeIdentifier: UTType.pdf.identifier
        )
        let journalURL = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                staged.operationID.uuidString.lowercased() + ".json"
            )
        let operationDirectory = staged.stagingURL.deletingLastPathComponent()
        for url in [
            root,
            root.appendingPathComponent(".staging", isDirectory: true),
            root.appendingPathComponent("Attachments", isDirectory: true),
            root.appendingPathComponent(".trash", isDirectory: true),
            operationDirectory,
            journalURL,
            staged.stagingURL
        ] {
            XCTAssertEqual(
                try url.resourceValues(
                    forKeys: [.isExcludedFromBackupKey]
                ).isExcludedFromBackup,
                false,
                url.path
            )
        }
        let committed = try store.commit(staged)
        XCTAssertEqual(
            try committed.fileURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup,
            false
        )
        let ownerDirectory = committed.fileURL.deletingLastPathComponent()
        XCTAssertEqual(
            try ownerDirectory.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup,
            false
        )
        try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))
        let deletion = try store.stageDeletion(
            attachment: AttachmentSnapshot(
                id: staged.attachmentID,
                ownerType: .labSample,
                ownerID: UUID(),
                relativePath: staged.relativePath,
                originalFilename: staged.originalFilename,
                typeIdentifier: staged.typeIdentifier,
                byteCount: staged.byteCount,
                sha256Hex: staged.sha256Hex,
                createdAt: Date()
            ),
            operationID: UUID()
        )
        let deletionJournal = root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                deletion.operationID.uuidString.lowercased() + ".json"
            )
        for url in [
            deletion.trashURL.deletingLastPathComponent(),
            deletion.trashURL,
            deletionJournal
        ] {
            XCTAssertEqual(
                try url.resourceValues(
                    forKeys: [.isExcludedFromBackupKey]
                ).isExcludedFromBackup,
                false,
                url.path
            )
        }
        try store.rollbackDeletion(operationID: deletion.operationID)
    }

    func testAttachmentAuditAcceptsMoreThan4096LegalActiveFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Global-Cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        _ = try store.recover(committedAttachments: [:])
        let attachmentRoot = root.appendingPathComponent(
            "Attachments",
            isDirectory: true
        )
        let bytes = Data([0x01])
        let hash = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        var snapshots: [AttachmentSnapshot] = []
        snapshots.reserveCapacity(4_097)
        for _ in 0..<4_097 {
            let attachmentID = UUID()
            let ownerDirectory = attachmentRoot.appendingPathComponent(
                attachmentID.uuidString.lowercased(),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: ownerDirectory,
                withIntermediateDirectories: false
            )
            var protectedOwnerDirectory = ownerDirectory
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = false
            try protectedOwnerDirectory.setResourceValues(directoryValues)
            let fileURL = ownerDirectory.appendingPathComponent("payload.pdf")
            try bytes.write(to: fileURL)
            var protectedFileURL = fileURL
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = false
            try protectedFileURL.setResourceValues(fileValues)
            snapshots.append(
                AttachmentSnapshot(
                    id: attachmentID,
                    ownerType: .labSample,
                    ownerID: UUID(),
                    relativePath: "Attachments/\(attachmentID.uuidString.lowercased())/payload.pdf",
                    originalFilename: "report.pdf",
                    typeIdentifier: UTType.pdf.identifier,
                    byteCount: 1,
                    sha256Hex: hash,
                    createdAt: Date()
                )
            )
        }

        _ = try store.recover(
            committedAttachments: Dictionary(
                uniqueKeysWithValues: snapshots.map {
                    (
                        $0.id,
                        AttachmentCommittedImport(
                            operationID: UUID(),
                            attachment: $0
                        )
                    )
                }
            )
        )
        XCTAssertNoThrow(try store.audit(snapshots))
    }

    func testAttachmentCommitRejectsIntermediateSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Symlink-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = AttachmentFileStore(rootURL: root)
        let attachmentID = UUID()
        let staged = try store.stage(
            data: Data([0x01, 0x02, 0x03]),
            attachmentID: attachmentID,
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let ownerDirectory = root
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(attachmentID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: ownerDirectory,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try store.commit(staged)) { error in
            XCTAssertEqual(error as? AttachmentFileStoreFailure, .unsafePath)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("payload.pdf").path
            )
        )
    }

    func testAttachmentMetadataEnforcesPerOwnerLimitsAndSupportsSingleDeletion() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let sampleID = try await createSample(using: writer)

        var attachmentIDs: [UUID] = []
        for index in 0..<6 {
            let id = UUID()
            attachmentIDs.append(id)
            _ = try await writer.addAttachmentMetadata(
                AddAttachmentMetadataCommand(
                    operationID: UUID(),
                    attachmentID: id,
                    ownerType: .labSample,
                    ownerID: sampleID,
                    relativePath: "Attachments/\(id.uuidString.lowercased())/payload.pdf",
                    originalFilename: "report-\(index).pdf",
                    typeIdentifier: "com.adobe.pdf",
                    byteCount: 10,
                    sha256Hex: String(repeating: "a", count: 64)
                )
            )
        }
        let sixAttachments = try await reader.attachments(
            ownerType: .labSample,
            ownerID: sampleID
        )
        XCTAssertEqual(sixAttachments.count, 6)
        let overflowID = UUID()
        do {
            _ = try await writer.addAttachmentMetadata(
                AddAttachmentMetadataCommand(
                    operationID: UUID(),
                    attachmentID: overflowID,
                    ownerType: .labSample,
                    ownerID: sampleID,
                    relativePath: "Attachments/\(overflowID.uuidString.lowercased())/payload.pdf",
                    originalFilename: "overflow.pdf",
                    typeIdentifier: "com.adobe.pdf",
                    byteCount: 10,
                    sha256Hex: String(repeating: "b", count: 64)
                )
            )
            XCTFail("Only six attachments are allowed per owner")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .attachmentLimitReached)
        }

        let deleteOperationID = UUID()
        let deleteCommand = DeleteAttachmentCommand(
            operationID: deleteOperationID,
            attachmentID: attachmentIDs[2]
        )
        let deleted = try await writer.deleteAttachment(deleteCommand)
        XCTAssertEqual(deleted.attachment.id, attachmentIDs[2])
        XCTAssertTrue(deleted.didDelete)
        let replay = try await writer.deleteAttachment(deleteCommand)
        XCTAssertEqual(replay.attachment.id, attachmentIDs[2])
        XCTAssertFalse(replay.didDelete)
        let fiveAttachments = try await reader.attachments(
            ownerType: .labSample,
            ownerID: sampleID
        )
        XCTAssertEqual(fiveAttachments.count, 5)
    }

    func testAttachmentReaderFailsClosedWhenOwnerHasMoreThanSixActiveFiles() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let entryID = UUID()
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: entryID,
                text: "损坏夹具",
                kind: .moment,
                occurredAt: Date(timeIntervalSince1970: 1_735_732_860),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC"
            )
        )
        for index in 0..<7 {
            let attachmentID = UUID()
            container.mainContext.insert(
                AttachmentRecord(
                    id: attachmentID,
                    ownerType: .journeyEntry,
                    ownerID: entryID,
                    relativePath:
                        "Attachments/\(attachmentID.uuidString.lowercased())/payload.pdf",
                    originalFilename: "report-\(index).pdf",
                    typeIdentifier: UTType.pdf.identifier,
                    byteCount: 1,
                    sha256Hex: String(repeating: "a", count: 64),
                    operationID: UUID(),
                    createdAt: Date(timeIntervalSince1970: 1_735_732_860)
                )
            )
        }
        try container.mainContext.save()

        do {
            _ = try await reader.attachments(
                ownerType: .journeyEntry,
                ownerID: entryID
            )
            XCTFail("Corrupt owner capacity must fail closed")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }

        let extraID = UUID()
        do {
            _ = try await writer.addAttachmentMetadata(
                AddAttachmentMetadataCommand(
                    operationID: UUID(),
                    attachmentID: extraID,
                    ownerType: .journeyEntry,
                    ownerID: entryID,
                    relativePath:
                        "Attachments/\(extraID.uuidString.lowercased())/payload.pdf",
                    originalFilename: "extra.pdf",
                    typeIdentifier: UTType.pdf.identifier,
                    byteCount: 1,
                    sha256Hex: String(repeating: "b", count: 64)
                )
            )
            XCTFail("A write against corrupt owner capacity must fail closed")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testLabDefinitionReaderRejectsUnknownPersistedKind() async throws {
        let container = try preparedContainer()
        let definition = LabItemDefinitionRecord(
            displayName: "损坏定义",
            code: "BROKEN"
        )
        definition.kindRawValue = "future-unknown-kind"
        container.mainContext.insert(definition)
        try container.mainContext.save()
        let reader = AppReadActor(modelContainer: container)

        do {
            _ = try await reader.labItemDefinitions()
            XCTFail("Unknown persisted kinds must not be treated as custom")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testAttachmentOnlyLabRejectsDeletingItsLastReadyAttachment() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let sampleID = UUID()
        let attachmentID = UUID()
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: timestamp,
                newDefinitions: [],
                results: [],
                attachments: [
                    PreparedAttachmentMetadata(
                        operationID: UUID(),
                        attachmentID: attachmentID,
                        relativePath: "Attachments/\(attachmentID.uuidString.lowercased())/payload.pdf",
                        originalFilename: "report.pdf",
                        typeIdentifier: "com.adobe.pdf",
                        byteCount: 3,
                        sha256Hex: String(repeating: "a", count: 64)
                    )
                ]
            )
        )

        do {
            _ = try await writer.deleteAttachment(
                DeleteAttachmentCommand(
                    operationID: UUID(),
                    attachmentID: attachmentID
                )
            )
            XCTFail("An attachment-only lab must retain one ready attachment")
        } catch {
            XCTAssertEqual(
                error as? PersonalTimelineWriteFailure,
                .lastAttachmentRequired
            )
        }
        let attachments = try await reader.attachments(
            ownerType: .labSample,
            ownerID: sampleID
        )
        XCTAssertEqual(attachments.count, 1)
    }

    func testAttachmentDeletionJournalRestoresOrDestroysAccordingToMetadataState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unmanual-Attachment-Delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(rootURL: root)
        let attachmentID = UUID()
        let importOperationID = UUID()
        let staged = try store.stage(
            data: Data([0x01, 0x02, 0x03]),
            attachmentID: attachmentID,
            originalFilename: "report.pdf",
            typeIdentifier: "com.adobe.pdf",
            operationID: importOperationID
        )
        let committed = try store.commit(staged)
        try store.markMetadataCommitted(PreparedAttachmentMetadata(staged))

        let firstDelete = try store.stageDeletion(
            attachment: AttachmentSnapshot(
                id: attachmentID,
                ownerType: .labSample,
                ownerID: UUID(),
                relativePath: staged.relativePath,
                originalFilename: staged.originalFilename,
                typeIdentifier: staged.typeIdentifier,
                byteCount: staged.byteCount,
                sha256Hex: staged.sha256Hex,
                createdAt: Date()
            ),
            operationID: UUID()
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.fileURL.path))
        _ = try store.recover(
            committedAttachments: [
                attachmentID: AttachmentCommittedImport(
                    operationID: importOperationID,
                    attachment: firstDelete.attachment
                )
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.fileURL.path))

        let secondDelete = try store.stageDeletion(
            attachment: firstDelete.attachment,
            operationID: UUID()
        )
        XCTAssertThrowsError(
            try store.recover(
                committedAttachments: [:],
                committedDeletions: [
                    attachmentID: AttachmentCommittedDeletion(
                        operationID: UUID(),
                        attachment: secondDelete.attachment
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? AttachmentFileStoreFailure,
                .inconsistentJournal
            )
        }
        _ = try store.recover(
            committedAttachments: [:],
            committedDeletions: [
                attachmentID: AttachmentCommittedDeletion(
                    operationID: secondDelete.operationID,
                    attachment: secondDelete.attachment
                )
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDelete.trashURL.path))
    }

    func testUnifiedTimelineMergesFactsAndUsesStableCursor() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let base = Date(timeIntervalSince1970: 1_735_732_860)
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                text: "一条普通记录",
                kind: .moment,
                occurredAt: base.addingTimeInterval(-60),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC",
                committedAt: base
            )
        )
        let metric = try await writer.createStatusMetric(
            CreateStatusMetricCommand(
                operationID: UUID(),
                displayName: "精力",
                committedAt: base
            )
        )
        let statusTimestamp = try HistoricalTimestamp.captured(
            instant: base.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        _ = try await writer.recordStatusObservation(
            RecordStatusObservationCommand(
                operationID: UUID(),
                metricDefinitionID: metric.metricID,
                ordinalLevel: 2,
                timestamp: statusTimestamp,
                committedAt: base.addingTimeInterval(60)
            )
        )
        _ = try await createSample(using: writer, instant: base.addingTimeInterval(120))

        let first = try await reader.personalTimelinePage(limit: 2)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.items.map(\.kind), [.labSample, .statusObservation])
        XCTAssertNotNil(first.nextCursor)
        let second = try await reader.personalTimelinePage(
            after: first.nextCursor,
            limit: 2
        )
        XCTAssertEqual(second.items.map(\.kind), [.journeyEntry])
        XCTAssertNil(second.nextCursor)
        XCTAssertEqual(Set(first.items.map(\.id) + second.items.map(\.id)).count, 3)
    }

    func testUnifiedTimelinePaginatesSameInstantWithoutDuplicatesOrGaps() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let instant = Date(timeIntervalSince1970: 1_735_732_800)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ]
        for id in ids {
            try await writer.addJourneyEntry(
                AddJourneyEntryCommand(
                    recordID: id,
                    text: id.uuidString,
                    kind: .moment,
                    occurredAt: instant,
                    regimenVersionID: nil,
                    timeZoneIdentifier: "UTC",
                    committedAt: instant
                )
            )
        }

        var cursor: PersonalTimelineCursor?
        var collected: [UUID] = []
        repeat {
            let page = try await reader.personalTimelinePage(
                after: cursor,
                limit: 1
            )
            collected.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(collected, ids.sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(Set(collected).count, ids.count)
    }

    func testUnifiedTimelineFailsClosedWhenCursorInstantExceedsTieCapacity() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let instant = Date(timeIntervalSince1970: 1_735_732_800)
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .captured
        )
        for index in 0...PersonalTimelineCapacity.maximumSameInstantCursorTieCount {
            let id = UUID()
            context.insert(
                JourneyEntry(
                    id: id,
                    text: "同刻 \(index)",
                    kind: .moment,
                    occurredAt: instant
                )
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "JourneyEntry",
                    sourceRecordID: id,
                    timestamp: timestamp,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: nil,
                    associationState: .missing
                )
            )
        }
        for index in 1...2 {
            let id = UUID()
            let older = try HistoricalTimestamp.captured(
                instant: instant.addingTimeInterval(TimeInterval(-index * 60)),
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .captured
            )
            context.insert(
                JourneyEntry(
                    id: id,
                    text: "更早 \(index)",
                    kind: .moment,
                    occurredAt: older.instant
                )
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "JourneyEntry",
                    sourceRecordID: id,
                    timestamp: older,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: nil,
                    associationState: .missing
                )
            )
        }
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        let first = try await reader.personalTimelinePage(limit: 1)
        do {
            _ = try await reader.personalTimelinePage(
                after: first.nextCursor,
                limit: 50
            )
            XCTFail("A cursor instant above the tie cap must fail closed")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testAdministrationTimelineFailsClosedWhenCursorInstantExceedsTieCapacity() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let regimenVersionID = UUID()
        let regimenItemID = UUID()
        context.insert(
            RegimenItemRecord(
                id: regimenItemID,
                regimenVersionID: regimenVersionID,
                sortOrder: 0,
                displayName: "同刻预算测试"
            )
        )
        let instant = Date(timeIntervalSince1970: 1_735_732_800)
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .captured
        )
        for index in 0...PersonalTimelineCapacity.maximumSameInstantCursorTieCount {
            let eventID = UUID()
            context.insert(
                AdministrationEventRecord(
                    id: eventID,
                    occurrenceKey: "same-instant-\(index)",
                    scheduleRuleID: UUID(),
                    scheduleRevision: 1,
                    regimenVersionID: regimenVersionID,
                    regimenItemID: regimenItemID,
                    status: .taken,
                    plannedInstant: instant,
                    operationID: UUID(),
                    createdAt: instant
                )
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "AdministrationEventRecord",
                    sourceRecordID: eventID,
                    timestamp: timestamp,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: regimenVersionID,
                    associationState: .resolved
                )
            )
        }
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        let firstPage = try await reader.personalTimelinePage(limit: 1)
        XCTAssertNotNil(firstPage.nextCursor)
        do {
            _ = try await reader.personalTimelinePage(
                after: firstPage.nextCursor,
                limit: 1
            )
            XCTFail("Administration cursor tie overflow must fail closed")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testUnifiedTimelineOrdersTimedFactsByInstantAcrossTimeZones() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let olderInstant = Date(timeIntervalSince1970: 1_735_732_800)
        let newerInstant = olderInstant.addingTimeInterval(3_600)

        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                text: "较旧但当地日期较晚",
                kind: .moment,
                occurredAt: olderInstant,
                regimenVersionID: nil,
                timeZoneIdentifier: "Pacific/Kiritimati",
                committedAt: olderInstant
            )
        )
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                text: "较新但当地日期较早",
                kind: .moment,
                occurredAt: newerInstant,
                regimenVersionID: nil,
                timeZoneIdentifier: "Pacific/Honolulu",
                committedAt: newerInstant
            )
        )

        let page = try await reader.personalTimelinePage(limit: 10)
        XCTAssertEqual(
            page.items.filter { $0.kind == .journeyEntry }.map(\.detail),
            ["较新但当地日期较早", "较旧但当地日期较晚"]
        )
    }

    func testUnifiedTimelineScansPastLongAdministrationCorrectionChain() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let regimenVersionID = UUID()
        let regimenItemID = UUID()
        context.insert(
            RegimenItemRecord(
                id: regimenItemID,
                regimenVersionID: regimenVersionID,
                sortOrder: 0,
                displayName: "测试项目"
            )
        )
        let base = Date(timeIntervalSince1970: 1_735_732_800)
        let independentID = UUID()
        let independentTimestamp = try HistoricalTimestamp.captured(
            instant: base,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .captured
        )
        context.insert(
            AdministrationEventRecord(
                id: independentID,
                occurrenceKey: "independent",
                scheduleRuleID: UUID(),
                scheduleRevision: 1,
                regimenVersionID: regimenVersionID,
                regimenItemID: regimenItemID,
                status: .taken,
                plannedInstant: base,
                operationID: UUID(),
                createdAt: base
            )
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "AdministrationEventRecord",
                sourceRecordID: independentID,
                timestamp: independentTimestamp,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: regimenVersionID,
                associationState: .resolved
            )
        )

        var predecessorID: UUID?
        var effectiveLeafID: UUID?
        for index in 0..<101 {
            let eventID = UUID()
            let instant = base.addingTimeInterval(TimeInterval((index + 1) * 60))
            let timestamp = try HistoricalTimestamp.captured(
                instant: instant,
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .captured
            )
            context.insert(
                AdministrationEventRecord(
                    id: eventID,
                    occurrenceKey: "corrected",
                    scheduleRuleID: UUID(),
                    scheduleRevision: 1,
                    regimenVersionID: regimenVersionID,
                    regimenItemID: regimenItemID,
                    status: index.isMultiple(of: 2) ? .taken : .skipped,
                    plannedInstant: instant,
                    supersedesEventID: predecessorID,
                    operationID: UUID(),
                    createdAt: instant
                )
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "AdministrationEventRecord",
                    sourceRecordID: eventID,
                    timestamp: timestamp,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: regimenVersionID,
                    associationState: .resolved
                )
            )
            predecessorID = eventID
            effectiveLeafID = eventID
        }
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        let firstPage = try await reader.personalTimelinePage(limit: 1)
        let firstAdministrationIDs = firstPage.items
            .filter { $0.kind == .administration }
            .map(\.id)
        XCTAssertEqual(firstAdministrationIDs, [effectiveLeafID].compactMap { $0 })
        let secondPage = try await reader.personalTimelinePage(
            after: firstPage.nextCursor,
            limit: 1
        )
        let secondAdministrationIDs = secondPage.items
            .filter { $0.kind == .administration }
            .map(\.id)
        XCTAssertEqual(secondAdministrationIDs, [independentID])
        XCTAssertNil(secondPage.nextCursor)
    }

    func testUnifiedTimelineEnforcesCombinedAdministrationReadBudget() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let regimenVersionID = UUID()
        let regimenItemID = UUID()
        context.insert(
            RegimenItemRecord(
                id: regimenItemID,
                regimenVersionID: regimenVersionID,
                sortOrder: 0,
                displayName: "预算测试"
            )
        )
        let base = Date(timeIntervalSince1970: 1_735_732_800)
        let independentID = UUID()
        let independentTimestamp = try HistoricalTimestamp.captured(
            instant: base,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .captured
        )
        context.insert(
            AdministrationEventRecord(
                id: independentID,
                occurrenceKey: "budget-independent",
                scheduleRuleID: UUID(),
                scheduleRevision: 1,
                regimenVersionID: regimenVersionID,
                regimenItemID: regimenItemID,
                status: .taken,
                plannedInstant: base,
                operationID: UUID(),
                createdAt: base
            )
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "AdministrationEventRecord",
                sourceRecordID: independentID,
                timestamp: independentTimestamp,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: regimenVersionID,
                associationState: .resolved
            )
        )
        var predecessorID: UUID?
        for index in 0..<2_000 {
            let id = UUID()
            let instant = base.addingTimeInterval(TimeInterval((index + 1) * 60))
            let timestamp = try HistoricalTimestamp.captured(
                instant: instant,
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .captured
            )
            context.insert(
                AdministrationEventRecord(
                    id: id,
                    occurrenceKey: "budget-chain",
                    scheduleRuleID: UUID(),
                    scheduleRevision: 1,
                    regimenVersionID: regimenVersionID,
                    regimenItemID: regimenItemID,
                    status: .taken,
                    plannedInstant: instant,
                    supersedesEventID: predecessorID,
                    operationID: UUID(),
                    createdAt: instant
                )
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "AdministrationEventRecord",
                    sourceRecordID: id,
                    timestamp: timestamp,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: regimenVersionID,
                    associationState: .resolved
                )
            )
            predecessorID = id
        }
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        do {
            _ = try await reader.personalTimelinePage(limit: 1)
            XCTFail("Combined raw/event reads above the budget must fail closed")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testTimelineAcceptsLegalResultCapacityAcrossManySamples() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let definitionID = UUID()
        context.insert(
            LabItemDefinitionRecord(
                id: definitionID,
                displayName: "批量项目",
                code: "BULK",
                createdAt: Date(timeIntervalSince1970: 1_735_732_800)
            )
        )
        for sampleIndex in 0..<33 {
            let sampleID = UUID()
            let instant = Date(
                timeIntervalSince1970:
                    1_735_732_800 + TimeInterval(sampleIndex)
            )
            context.insert(
                LabSampleRecord(
                    id: sampleID,
                    operationID: UUID(),
                    createdAt: instant
                )
            )
            let timestamp = try HistoricalTimestamp.captured(
                instant: instant,
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .captured
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "LabSampleRecord",
                    sourceRecordID: sampleID,
                    timestamp: timestamp,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: nil,
                    associationState: .missing
                )
            )
            for resultIndex in 0..<PersonalTimelineCapacity.maximumLabResultsPerSample {
                context.insert(
                    LabResultRecord(
                        sampleID: sampleID,
                        sortOrder: resultIndex,
                        itemDefinitionID: definitionID,
                        itemNameSnapshot: "批量项目",
                        itemCodeSnapshot: "BULK",
                        rawValueOriginal: "\(resultIndex)",
                        comparator: nil,
                        canonicalDecimalString: "\(resultIndex)",
                        unitOriginal: "unit",
                        operationID: UUID(),
                        createdAt: instant
                    )
                )
            }
        }
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        let page = try await reader.personalTimelinePage(limit: 100)
        XCTAssertEqual(page.items.count, 33)
        XCTAssertTrue(page.items.allSatisfy { $0.kind == .labSample })
        XCTAssertNil(page.nextCursor)
    }

    func testTimelineRejectsPerSampleResultOverflowEvenWhenPageTotalFits() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let definitionID = UUID()
        context.insert(
            LabItemDefinitionRecord(
                id: definitionID,
                displayName: "损坏项目",
                code: "OVERFLOW"
            )
        )
        let instant = Date(timeIntervalSince1970: 1_735_732_800)
        for sampleIndex in 0..<2 {
            let sampleID = UUID()
            context.insert(
                LabSampleRecord(
                    id: sampleID,
                    operationID: UUID(),
                    createdAt: instant
                )
            )
            let timestamp = try HistoricalTimestamp.captured(
                instant: instant.addingTimeInterval(
                    TimeInterval(sampleIndex)
                ),
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .captured
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "LabSampleRecord",
                    sourceRecordID: sampleID,
                    timestamp: timestamp,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: nil,
                    associationState: .missing
                )
            )
            if sampleIndex == 0 {
                for resultIndex in 0...PersonalTimelineCapacity
                    .maximumLabResultsPerSample {
                    context.insert(
                        LabResultRecord(
                            sampleID: sampleID,
                            sortOrder: resultIndex,
                            itemDefinitionID: definitionID,
                            itemNameSnapshot: "损坏项目",
                            itemCodeSnapshot: "OVERFLOW",
                            rawValueOriginal: "\(resultIndex)",
                            comparator: nil,
                            canonicalDecimalString: "\(resultIndex)",
                            unitOriginal: "unit",
                            operationID: UUID(),
                            createdAt: instant
                        )
                    )
                }
            }
        }
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        do {
            _ = try await reader.personalTimelinePage(limit: 2)
            XCTFail("A per-sample overflow must fail closed")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testV5OrphanOperationReceiptsFailRelationshipValidation() throws {
        for recordType in [
            "LabSampleRecord",
            "StatusMetricDefinitionRecord",
            "StatusObservationRecord",
            "AttachmentRecord"
        ] {
            let container = try preparedContainer()
            let context = ModelContext(container)
            context.insert(
                OperationReceiptRecord(
                    operationID: UUID(),
                    commandDigest: String(repeating: "a", count: 64),
                    resultRecordType: recordType,
                    resultRecordID: UUID(),
                    committedAt: Date(timeIntervalSince1970: 1_735_732_800)
                )
            )
            try context.save()
            XCTAssertThrowsError(
                try PersonalTimelineRelationshipValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                ),
                recordType
            )
        }
    }

    func testSyntheticLegacyShapeWithoutSourceOrReceiptFailsValidation() throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let resultID = UUID(
            uuidString: "75757575-7575-4757-8757-757575757575"
        )!
        let sampleID = PersonalTimelineBackfill.legacySampleID(for: resultID)
        let definitionID = UUID(
            uuidString: "76767676-7676-4767-8767-767676767676"
        )!
        let operationID = UUID(
            uuidString: "77777777-7777-4777-8777-777777777777"
        )!
        let instant = Date(timeIntervalSince1970: 1_735_732_800)
        context.insert(
            LabItemDefinitionRecord(
                id: definitionID,
                displayName: "伪旧版项目",
                code: "FAKE",
                createdAt: instant
            )
        )
        context.insert(
            LabSampleRecord(
                id: sampleID,
                operationID: operationID,
                contextNote: "没有 legacy 来源",
                createdAt: instant
            )
        )
        context.insert(
            LabResultRecord(
                id: resultID,
                sampleID: sampleID,
                sortOrder: 0,
                itemDefinitionID: definitionID,
                itemNameSnapshot: "伪旧版项目",
                itemCodeSnapshot: "FAKE",
                rawValueOriginal: "1",
                comparator: nil,
                canonicalDecimalString: "1",
                unitOriginal: "unit",
                operationID: operationID,
                createdAt: instant
            )
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "LabSampleRecord",
                sourceRecordID: sampleID,
                timestamp: try HistoricalTimestamp.captured(
                    instant: instant,
                    timeZoneIdentifier: "UTC",
                    precision: .minute,
                    provenance: .userEntered
                ),
                legacyAssociationID: nil,
                resolvedRegimenVersionID: nil,
                associationState: .missing
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try PersonalTimelineRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testArchivedMetricBindsItsArchiveOperationReceipt() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let metricID = UUID()
        let archiveOperationID = UUID()
        _ = try await writer.createStatusMetric(
            CreateStatusMetricCommand(
                operationID: UUID(),
                metricID: metricID,
                displayName: "精力"
            )
        )
        _ = try await writer.archiveStatusMetric(
            ArchiveStatusMetricCommand(
                operationID: archiveOperationID,
                metricID: metricID
            )
        )
        let context = ModelContext(container)
        let metrics = try context.fetch(
            FetchDescriptor<StatusMetricDefinitionRecord>(
                predicate: #Predicate { $0.id == metricID }
            )
        )
        XCTAssertEqual(metrics.first?.archiveOperationID, archiveOperationID)
        XCTAssertNoThrow(
            try PersonalTimelineRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testDefinitionReadersFailClosedAtFrozenCapacity() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        for index in 0...PersonalTimelineCapacity.maximumLabItemDefinitions {
            context.insert(
                LabItemDefinitionRecord(
                    displayName: "Lab \(index)",
                    code: "\(index)",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        for index in 0...PersonalTimelineCapacity.maximumStatusMetricDefinitions {
            context.insert(
                StatusMetricDefinitionRecord(
                    displayName: "Status \(index)",
                    isArchived: true,
                    operationID: UUID(),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        try context.save()
        let reader = AppReadActor(modelContainer: container)

        do {
            _ = try await reader.labItemDefinitions()
            XCTFail("Lab definitions must use a fail-closed capacity")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
        do {
            _ = try await reader.statusMetrics()
            XCTFail("Status metrics must use a fail-closed capacity")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testDefinitionWritersRespectTheSameFrozenCapacityAsReaders() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        for index in 0..<PersonalTimelineCapacity.maximumLabItemDefinitions {
            context.insert(
                LabItemDefinitionRecord(
                    displayName: "Lab \(index)",
                    code: "\(index)",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        for index in 0..<PersonalTimelineCapacity.maximumStatusMetricDefinitions {
            context.insert(
                StatusMetricDefinitionRecord(
                    displayName: "Status \(index)",
                    isArchived: true,
                    operationID: UUID(),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        try context.save()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let definitionID = UUID()

        do {
            _ = try await writer.createLabSample(
                CreateLabSampleCommand(
                    operationID: UUID(),
                    timestamp: timestamp,
                    newDefinitions: [
                        LabItemDefinitionInput(
                            id: definitionID,
                            displayName: "overflow"
                        )
                    ],
                    results: [
                        LabResultInput(
                            itemDefinitionID: definitionID,
                            rawValueOriginal: "1",
                            unitOriginal: "unit"
                        )
                    ]
                )
            )
            XCTFail("Lab definition writer must stop at the frozen capacity")
        } catch {
            XCTAssertEqual(
                error as? PersonalTimelineWriteFailure,
                .invalidInput
            )
        }

        do {
            _ = try await writer.createStatusMetric(
                CreateStatusMetricCommand(
                    operationID: UUID(),
                    displayName: "overflow"
                )
            )
            XCTFail("Status definition writer must stop at the frozen capacity")
        } catch {
            XCTAssertEqual(
                error as? PersonalTimelineWriteFailure,
                .invalidInput
            )
        }
    }

    func testTodayLatestLabUsesCanonicalSampleIdentity() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let olderID = try await createSample(
            using: writer,
            instant: Date(timeIntervalSince1970: 1_735_732_800)
        )
        let newerID = try await createSample(
            using: writer,
            instant: Date(timeIntervalSince1970: 1_735_819_200)
        )

        let latest = try await reader.latestLabTimelineItem()
        XCTAssertNotEqual(latest?.id, olderID)
        XCTAssertEqual(latest?.id, newerID)
        XCTAssertEqual(latest?.kind, .labSample)
    }

    private func preparedContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory.makeInMemoryPersonalTimelineContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        return container
    }

    private func createSample(
        using writer: AppWriteActor,
        instant: Date = Date(timeIntervalSince1970: 1_735_732_860)
    ) async throws -> UUID {
        let definitionID = UUID()
        let sampleID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: timestamp,
                newDefinitions: [
                    LabItemDefinitionInput(id: definitionID, displayName: "自定义项目")
                ],
                results: [
                    LabResultInput(
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "10",
                        unitOriginal: "unit"
                    )
                ],
                committedAt: instant
            )
        )
        return sampleID
    }
}

private actor AttachmentRecoveryRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func callCount() -> Int {
        count
    }
}

private actor AttachmentMutationGate {
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func block() async {
        isBlocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while !isBlocked {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
