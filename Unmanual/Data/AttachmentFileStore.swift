import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentFileStoreFailure: Error, Equatable, Sendable {
    case invalidInput
    case fileTooLarge
    case ownerLimitReached
    case unsafePath
    case inconsistentJournal
    case integrityMismatch
    case recoveryRequired
    case simulatedInterruption
}

enum AttachmentFileStoreCommitFailpoint: Equatable, Sendable {
    case afterFinalMoveBeforeJournal
}

enum AttachmentFileStoreFailureInjection: Equatable, Sendable {
    case discard
    case markMetadataCommitted
    case rollbackDeletion
    case finalizeDeletion
}

struct AttachmentDraft: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    let filename: String
    let typeIdentifier: String
}

struct BoundedAttachmentPayload: Equatable, Sendable {
    let data: Data
    let typeIdentifier: String
}

struct AttachmentFileImportItem: Sendable {
    let data: Data
    let filename: String
    let typeIdentifier: String
}

struct AttachmentFileImportResult: Sendable {
    let items: [AttachmentFileImportItem]
    let failureCount: Int
}

final class AttachmentFileImportWorker: @unchecked Sendable {
    static let shared = AttachmentFileImportWorker()

    private let queue = DispatchQueue(
        label: "com.mtfbook.unmanual.attachment-file-import",
        qos: .userInitiated
    )

    private init() {}

    func load(
        urls: [URL],
        existingByteCounts: [Int64]
    ) async -> AttachmentFileImportResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: Self.loadSynchronously(
                        urls: urls,
                        existingByteCounts: existingByteCounts
                    )
                )
            }
        }
    }

    private static func loadSynchronously(
        urls: [URL],
        existingByteCounts: [Int64]
    ) -> AttachmentFileImportResult {
        let remainingSlots = max(
            0,
            AttachmentFileStore.maximumOwnerFiles
                - existingByteCounts.count
        )
        var failureCount = max(0, urls.count - remainingSlots)
        var items: [AttachmentFileImportItem] = []
        for url in urls.prefix(remainingSlots) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let payload = try AttachmentImportFacts.loadBoundedFile(
                    at: url
                )
                guard AttachmentOwnerCapacity.canAppend(
                    byteCount: Int64(payload.data.count),
                    to: existingByteCounts
                        + items.map { Int64($0.data.count) }
                ) else {
                    failureCount += 1
                    continue
                }
                items.append(
                    AttachmentFileImportItem(
                        data: payload.data,
                        filename: url.lastPathComponent,
                        typeIdentifier: payload.typeIdentifier
                    )
                )
            } catch {
                failureCount += 1
            }
        }
        return AttachmentFileImportResult(
            items: items,
            failureCount: failureCount
        )
    }
}

enum AttachmentImportFacts {
    static func loadBoundedFile(at url: URL) throws -> BoundedAttachmentPayload {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let values = try url.resourceValues(
            forKeys: [.contentTypeKey, .isSymbolicLinkKey]
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              values.isSymbolicLink != true,
              let sizeNumber = attributes[.size] as? NSNumber else {
            throw AttachmentFileStoreFailure.invalidInput
        }
        let byteCount = sizeNumber.int64Value
        guard byteCount > 0 else {
            throw AttachmentFileStoreFailure.invalidInput
        }
        guard byteCount <= AttachmentFileStore.maximumFileBytes else {
            throw AttachmentFileStoreFailure.fileTooLarge
        }
        let contentType = values.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let contentType,
              contentType.conforms(to: .image)
                || contentType.conforms(to: .pdf) else {
            throw AttachmentFileStoreFailure.invalidInput
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximumReadCount = Int(
            AttachmentFileStore.maximumFileBytes + 1
        )
        let data = try handle.read(upToCount: maximumReadCount) ?? Data()
        guard Int64(data.count) == byteCount else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        return BoundedAttachmentPayload(
            data: data,
            typeIdentifier: contentType.identifier
        )
    }
}

struct AttachmentStagedFile: Equatable, Sendable {
    let operationID: UUID
    let attachmentID: UUID
    let originalFilename: String
    let typeIdentifier: String
    let byteCount: Int64
    let sha256Hex: String
    let relativePath: String
    let stagingURL: URL
}

struct AttachmentCommittedFile: Equatable, Sendable {
    let attachmentID: UUID
    let relativePath: String
    let fileURL: URL
}

struct AttachmentCommittedImport: Equatable, Sendable {
    let operationID: UUID
    let attachment: AttachmentSnapshot
}

struct AttachmentStagedDeletion: Equatable, Sendable {
    let operationID: UUID
    let attachment: AttachmentSnapshot
    let trashURL: URL
}

struct AttachmentCommittedDeletion: Equatable, Sendable {
    let operationID: UUID
    let attachment: AttachmentSnapshot
}

struct AttachmentRecoveryReport: Equatable, Sendable {
    let removedOrphanCount: Int
    let clearedCommittedJournalCount: Int
}

enum AttachmentPathFacts {
    static func relativePath(
        attachmentID: UUID,
        typeIdentifier: String
    ) -> String? {
        guard let leaf = payloadLeaf(typeIdentifier: typeIdentifier) else {
            return nil
        }
        return [
            "Attachments",
            attachmentID.uuidString.lowercased(),
            leaf
        ].joined(separator: "/")
    }

    static func isOpaquePath(
        _ relativePath: String,
        attachmentID: UUID
    ) -> Bool {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "Attachments",
              components[1] == Substring(attachmentID.uuidString.lowercased()) else {
            return false
        }
        let leaf = String(components[2])
        guard leaf.hasPrefix("payload."),
              leaf.count > "payload.".count else {
            return false
        }
        let fileExtension = String(leaf.dropFirst("payload.".count))
        guard fileExtension.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }),
        let contentType = UTType(filenameExtension: fileExtension),
        let expected = self.relativePath(
            attachmentID: attachmentID,
            typeIdentifier: contentType.identifier
        ) else {
            return false
        }
        return relativePath == expected
    }

    static func isOpaquePath(
        _ relativePath: String,
        attachmentID: UUID,
        typeIdentifier: String
    ) -> Bool {
        guard let expected = self.relativePath(
            attachmentID: attachmentID,
            typeIdentifier: typeIdentifier
        ) else {
            return false
        }
        return relativePath == expected
    }

    private static func payloadLeaf(typeIdentifier: String) -> String? {
        let cleanType = typeIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let type = UTType(cleanType),
              type.conforms(to: .image) || type.conforms(to: .pdf),
              let fileExtension = type.preferredFilenameExtension?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !fileExtension.isEmpty,
              fileExtension.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber)
              }) else {
            return nil
        }
        return "payload." + fileExtension
    }
}

struct AttachmentFileStore: Sendable {
    static let maximumFileBytes: Int64 = 20 * 1_024 * 1_024
    static let maximumOwnerBytes: Int64 = 60 * 1_024 * 1_024
    static let maximumOwnerFiles = 6

    let rootURL: URL
    let failureInjection: AttachmentFileStoreFailureInjection?

    init(
        rootURL: URL,
        failureInjection: AttachmentFileStoreFailureInjection? = nil
    ) {
        self.rootURL = rootURL
        self.failureInjection = failureInjection
    }

    private var stagingRoot: URL {
        rootURL.appendingPathComponent(".staging", isDirectory: true)
    }

    private var attachmentRoot: URL {
        rootURL.appendingPathComponent("Attachments", isDirectory: true)
    }

    private var trashRoot: URL {
        rootURL.appendingPathComponent(".trash", isDirectory: true)
    }

    func stage(
        data: Data,
        attachmentID: UUID,
        originalFilename: String,
        typeIdentifier: String,
        operationID: UUID = UUID()
    ) throws -> AttachmentStagedFile {
        guard !data.isEmpty,
              Int64(data.count) <= Self.maximumFileBytes else {
            throw data.isEmpty
                ? AttachmentFileStoreFailure.invalidInput
                : AttachmentFileStoreFailure.fileTooLarge
        }
        let cleanType = typeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = URL(fileURLWithPath: originalFilename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let contentType = UTType(cleanType),
              contentType.conforms(to: .image) || contentType.conforms(to: .pdf) else {
            throw AttachmentFileStoreFailure.invalidInput
        }
        guard let relativePath = AttachmentPathFacts.relativePath(
            attachmentID: attachmentID,
            typeIdentifier: contentType.identifier
        ) else {
            throw AttachmentFileStoreFailure.invalidInput
        }
        try prepareDirectories()
        try ensureNewOperation(
            operationID: operationID,
            finalRelativePath: relativePath
        )
        try writeJournal(
            Journal(
                operationID: operationID,
                attachmentID: attachmentID,
                relativePath: relativePath,
                typeIdentifier: contentType.identifier,
                action: .importFile,
                phase: .staged
            )
        )
        let operationDirectory = stagingRoot.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        let stagingURL = operationDirectory.appendingPathComponent("payload")
        do {
            try FileManager.default.createDirectory(
                at: operationDirectory,
                withIntermediateDirectories: false
            )
            try hardenAndValidateDirectory(at: operationDirectory)
            try data.write(to: stagingURL, options: [.atomic, .completeFileProtection])
            try hardenAndValidateRegularFile(at: stagingURL)
        } catch {
            do {
                try removeOperationArtifacts(
                    operationID: operationID,
                    removeFinal: true
                )
            } catch {
                throw AttachmentFileStoreFailure.recoveryRequired
            }
            throw error
        }
        return AttachmentStagedFile(
            operationID: operationID,
            attachmentID: attachmentID,
            originalFilename: cleanName,
            typeIdentifier: contentType.identifier,
            byteCount: Int64(data.count),
            sha256Hex: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            relativePath: relativePath,
            stagingURL: stagingURL
        )
    }

    func commit(
        _ staged: AttachmentStagedFile,
        failpoint: AttachmentFileStoreCommitFailpoint? = nil
    ) throws -> AttachmentCommittedFile {
        guard let journal = try loadJournal(operationID: staged.operationID),
              journal.action == .importFile,
              journal.phase == .staged,
              journal.attachmentID == staged.attachmentID,
              journal.relativePath == staged.relativePath,
              journal.typeIdentifier == staged.typeIdentifier,
              AttachmentPathFacts.isOpaquePath(
                  staged.relativePath,
                  attachmentID: staged.attachmentID,
                  typeIdentifier: staged.typeIdentifier
              ),
              staged.stagingURL == stagingPayloadURL(
                  operationID: staged.operationID
              ) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        let destination = try fileURL(forRelativePath: staged.relativePath)
        guard FileManager.default.fileExists(atPath: staged.stagingURL.path),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        let stagedData = try boundedFinalData(
            at: staged.stagingURL,
            expectedByteCount: staged.byteCount
        )
        guard sha256Hex(stagedData) == staged.sha256Hex else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try hardenAndValidateDirectory(
            at: destination.deletingLastPathComponent()
        )
        try FileManager.default.moveItem(at: staged.stagingURL, to: destination)
        try hardenAndValidateRegularFile(at: destination)
        if failpoint == .afterFinalMoveBeforeJournal {
            throw AttachmentFileStoreFailure.simulatedInterruption
        }
        try writeJournal(
            Journal(
                operationID: staged.operationID,
                attachmentID: staged.attachmentID,
                relativePath: staged.relativePath,
                typeIdentifier: staged.typeIdentifier,
                action: .importFile,
                phase: .finalReady
            )
        )
        return AttachmentCommittedFile(
            attachmentID: staged.attachmentID,
            relativePath: staged.relativePath,
            fileURL: destination
        )
    }

    func markMetadataCommitted(
        _ metadata: PreparedAttachmentMetadata
    ) throws {
        if failureInjection == .markMetadataCommitted {
            throw AttachmentFileStoreFailure.simulatedInterruption
        }
        guard let journal = try loadJournal(operationID: metadata.operationID),
              journal.action == .importFile,
              journal.phase == .finalReady,
              journal.attachmentID == metadata.attachmentID,
              journal.relativePath == metadata.relativePath,
              journal.typeIdentifier == metadata.typeIdentifier,
              AttachmentPathFacts.isOpaquePath(
                metadata.relativePath,
                attachmentID: metadata.attachmentID,
                typeIdentifier: metadata.typeIdentifier
              ),
              metadata.byteCount > 0,
              metadata.byteCount <= Self.maximumFileBytes,
              metadata.sha256Hex.count == 64 else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        let finalURL = try fileURL(forRelativePath: metadata.relativePath)
        let data = try boundedFinalData(
            at: finalURL,
            expectedByteCount: metadata.byteCount
        )
        guard sha256Hex(data) == metadata.sha256Hex else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        try removeOperationArtifacts(
            operationID: metadata.operationID,
            removeFinal: false
        )
        guard !FileManager.default.fileExists(
            atPath: journalURL(operationID: metadata.operationID).path
        ),
        !FileManager.default.fileExists(
            atPath: stagingRoot
                .appendingPathComponent(
                    metadata.operationID.uuidString.lowercased(),
                    isDirectory: true
                )
                .path
        ) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
    }

    func discard(operationID: UUID) throws {
        if failureInjection == .discard {
            throw AttachmentFileStoreFailure.simulatedInterruption
        }
        guard let journal = try loadJournal(operationID: operationID) else { return }
        guard journal.action == .importFile else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        try removeOperationArtifacts(operationID: operationID, removeFinal: true)
    }

    func stageDeletion(
        attachment: AttachmentSnapshot,
        operationID: UUID
    ) throws -> AttachmentStagedDeletion {
        try prepareDirectories()
        guard AttachmentPathFacts.isOpaquePath(
            attachment.relativePath,
            attachmentID: attachment.id,
            typeIdentifier: attachment.typeIdentifier
        ) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        try ensureNewOperation(operationID: operationID)
        let source = try fileURL(forRelativePath: attachment.relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        try validateRegularProtectedFile(at: source)
        let operationDirectory = trashRoot.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: operationDirectory.path) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        try writeJournal(
            Journal(
                operationID: operationID,
                attachmentID: attachment.id,
                relativePath: attachment.relativePath,
                typeIdentifier: attachment.typeIdentifier,
                action: .deleteFile,
                phase: .deletionPrepared
            )
        )
        do {
            try FileManager.default.createDirectory(
                at: operationDirectory,
                withIntermediateDirectories: false
            )
            try hardenAndValidateDirectory(at: operationDirectory)
            let trashURL = operationDirectory.appendingPathComponent("payload")
            try FileManager.default.moveItem(at: source, to: trashURL)
            try hardenAndValidateRegularFile(at: trashURL)
            try writeJournal(
                Journal(
                    operationID: operationID,
                    attachmentID: attachment.id,
                    relativePath: attachment.relativePath,
                    typeIdentifier: attachment.typeIdentifier,
                    action: .deleteFile,
                    phase: .deletionStaged
                )
            )
            return AttachmentStagedDeletion(
                operationID: operationID,
                attachment: attachment,
                trashURL: trashURL
            )
        } catch {
            do {
                try rollbackDeletion(operationID: operationID)
            } catch {
                throw AttachmentFileStoreFailure.recoveryRequired
            }
            throw error
        }
    }

    func finalizeDeletion(
        _ deletion: AttachmentStagedDeletion
    ) throws {
        if failureInjection == .finalizeDeletion {
            throw AttachmentFileStoreFailure.simulatedInterruption
        }
        let operationID = deletion.operationID
        let attachment = deletion.attachment
        guard let journal = try loadJournal(operationID: operationID),
              journal.action == .deleteFile,
              journal.phase == .deletionStaged,
              journal.attachmentID == attachment.id,
              journal.relativePath == attachment.relativePath,
              journal.typeIdentifier == attachment.typeIdentifier,
              deletion.trashURL == deletionTrashURL(operationID: operationID) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        let finalURL = try fileURL(forRelativePath: attachment.relativePath)
        guard !FileManager.default.fileExists(atPath: finalURL.path),
              FileManager.default.fileExists(atPath: deletion.trashURL.path) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        let data = try boundedFinalData(
            at: deletion.trashURL,
            expectedByteCount: attachment.byteCount
        )
        guard sha256Hex(data) == attachment.sha256Hex else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        try removeDeletionArtifacts(operationID: operationID)
        try removeJournal(operationID: operationID)
        try removeEmptyAttachmentDirectory(
            relativePath: journal.relativePath
        )
        guard !FileManager.default.fileExists(atPath: deletion.trashURL.path),
              !FileManager.default.fileExists(
                atPath: journalURL(operationID: operationID).path
              ),
              !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
    }

    func rollbackDeletion(operationID: UUID) throws {
        if failureInjection == .rollbackDeletion {
            throw AttachmentFileStoreFailure.simulatedInterruption
        }
        guard let journal = try loadJournal(operationID: operationID) else { return }
        guard journal.action == .deleteFile else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        let destination = try fileURL(forRelativePath: journal.relativePath)
        let trashURL = deletionTrashURL(operationID: operationID)
        if FileManager.default.fileExists(atPath: trashURL.path) {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try hardenAndValidateDirectory(
                at: destination.deletingLastPathComponent()
            )
            try FileManager.default.moveItem(at: trashURL, to: destination)
            try hardenAndValidateRegularFile(at: destination)
        }
        try removeDeletionArtifacts(operationID: operationID)
        try removeJournal(operationID: operationID)
    }

    func recover(
        committedAttachments: [UUID: AttachmentCommittedImport],
        committedDeletions: [UUID: AttachmentCommittedDeletion] = [:]
    ) throws -> AttachmentRecoveryReport {
        try prepareDirectories()
        let journalURLs = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var removed = 0
        var cleared = 0
        var seenOperationIDs = Set<UUID>()
        var seenAttachmentIDs = Set<UUID>()
        for url in journalURLs {
            let journal = try decodedJournal(at: url)
            guard seenOperationIDs.insert(journal.operationID).inserted,
                  seenAttachmentIDs.insert(journal.attachmentID).inserted else {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
            switch journal.action {
            case .importFile:
                if let committed = committedAttachments[journal.attachmentID] {
                    guard committed.operationID == journal.operationID,
                          committed.attachment.relativePath
                            == journal.relativePath,
                          committed.attachment.typeIdentifier
                            == journal.typeIdentifier else {
                        throw AttachmentFileStoreFailure.inconsistentJournal
                    }
                    let finalURL = try fileURL(
                        forRelativePath: committed.attachment.relativePath
                    )
                    let data = try boundedFinalData(
                        at: finalURL,
                        expectedByteCount: committed.attachment.byteCount
                    )
                    guard sha256Hex(data)
                            == committed.attachment.sha256Hex else {
                        throw AttachmentFileStoreFailure.integrityMismatch
                    }
                    cleared += 1
                    try removeOperationArtifacts(
                        operationID: journal.operationID,
                        removeFinal: false
                    )
                } else {
                    let finalURL = try fileURL(forRelativePath: journal.relativePath)
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                        removed += 1
                    }
                    try removeEmptyAttachmentDirectory(
                        relativePath: journal.relativePath
                    )
                    try removeOperationArtifacts(
                        operationID: journal.operationID,
                        removeFinal: false
                    )
                }
            case .deleteFile:
                if let committed = committedAttachments[journal.attachmentID] {
                    guard committed.attachment.relativePath
                            == journal.relativePath,
                          committed.attachment.typeIdentifier
                            == journal.typeIdentifier else {
                        throw AttachmentFileStoreFailure.inconsistentJournal
                    }
                    try rollbackDeletion(operationID: journal.operationID)
                } else {
                    guard journal.phase == .deletionStaged,
                          let committed =
                            committedDeletions[journal.attachmentID],
                          committed.operationID == journal.operationID,
                          committed.attachment.relativePath
                            == journal.relativePath,
                          committed.attachment.typeIdentifier
                            == journal.typeIdentifier else {
                        throw AttachmentFileStoreFailure.inconsistentJournal
                    }
                    let finalURL = try fileURL(forRelativePath: journal.relativePath)
                    guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                        throw AttachmentFileStoreFailure.inconsistentJournal
                    }
                    let trashURL = deletionTrashURL(
                        operationID: journal.operationID
                    )
                    if FileManager.default.fileExists(atPath: trashURL.path) {
                        let data = try boundedFinalData(
                            at: trashURL,
                            expectedByteCount: committed.attachment.byteCount
                        )
                        guard sha256Hex(data)
                                == committed.attachment.sha256Hex else {
                            throw AttachmentFileStoreFailure.integrityMismatch
                        }
                    }
                    try removeDeletionArtifacts(operationID: journal.operationID)
                    try removeJournal(operationID: journal.operationID)
                    try removeEmptyAttachmentDirectory(
                        relativePath: journal.relativePath
                    )
                }
            }
        }
        let journalOperationNames = Set(
            journalURLs.map { $0.deletingPathExtension().lastPathComponent }
        )
        let stagingEntries = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in stagingEntries
        where (try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && !journalOperationNames.contains(entry.lastPathComponent) {
            try FileManager.default.removeItem(at: entry)
            removed += 1
        }
        guard try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty,
        try FileManager.default.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        try validateFinalAttachmentTree(
            committedAttachmentIDs: Set(committedAttachments.keys)
        )
        return AttachmentRecoveryReport(
            removedOrphanCount: removed,
            clearedCommittedJournalCount: cleared
        )
    }

    func audit(_ attachments: [AttachmentSnapshot]) throws {
        for attachment in attachments {
            guard AttachmentPathFacts.isOpaquePath(
                attachment.relativePath,
                attachmentID: attachment.id,
                typeIdentifier: attachment.typeIdentifier
            ) else {
                throw AttachmentFileStoreFailure.integrityMismatch
            }
            let url = try fileURL(forRelativePath: attachment.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AttachmentFileStoreFailure.integrityMismatch
            }
            let data = try boundedFinalData(
                at: url,
                expectedByteCount: attachment.byteCount
            )
            guard sha256Hex(data) == attachment.sha256Hex else {
                throw AttachmentFileStoreFailure.integrityMismatch
            }
        }
    }

    func auditedFileURL(for attachment: AttachmentSnapshot) throws -> URL {
        guard AttachmentPathFacts.isOpaquePath(
            attachment.relativePath,
            attachmentID: attachment.id,
            typeIdentifier: attachment.typeIdentifier
        ) else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        let url = try fileURL(forRelativePath: attachment.relativePath)
        let data = try boundedFinalData(
            at: url,
            expectedByteCount: attachment.byteCount
        )
        guard sha256Hex(data) == attachment.sha256Hex else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        return url
    }

    func fileURL(forRelativePath relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw AttachmentFileStoreFailure.unsafePath
        }
        let standardizedRoot = rootURL.standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let candidate = standardizedRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard candidate.path.hasPrefix(standardizedRoot.path + "/") else {
            throw AttachmentFileStoreFailure.unsafePath
        }
        try rejectSymbolicLinkComponents(
            between: standardizedRoot,
            and: candidate.deletingLastPathComponent()
        )
        let resolvedParent = candidate
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        guard resolvedParent.path == resolvedRoot.path
                || resolvedParent.path.hasPrefix(resolvedRoot.path + "/") else {
            throw AttachmentFileStoreFailure.unsafePath
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
                throw AttachmentFileStoreFailure.unsafePath
            }
        }
        return candidate
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        guard (try? FileManager.default.destinationOfSymbolicLink(
            atPath: rootURL.path
        )) == nil else {
            throw AttachmentFileStoreFailure.unsafePath
        }
        for directory in [stagingRoot, attachmentRoot, trashRoot] {
            guard (try? FileManager.default.destinationOfSymbolicLink(
                atPath: directory.path
            )) == nil else {
                throw AttachmentFileStoreFailure.unsafePath
            }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            }
            guard (try? FileManager.default.destinationOfSymbolicLink(
                atPath: directory.path
            )) == nil else {
                throw AttachmentFileStoreFailure.unsafePath
            }
        }
        for directory in [rootURL, stagingRoot, attachmentRoot, trashRoot] {
            try hardenAndValidateDirectory(at: directory)
        }
    }

    private func applyProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = false
        try protectedURL.setResourceValues(resourceValues)
    }

    private func hardenAndValidateDirectory(at url: URL) throws {
        try applyProtection(to: url)
        try validateProtectedDirectory(at: url)
    }

    private func hardenAndValidateRegularFile(at url: URL) throws {
        try applyProtection(to: url)
        try validateRegularProtectedFile(at: url)
    }

    private func validateProtectedDirectory(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let values = try url.resourceValues(
            forKeys: [
                .isSymbolicLinkKey,
                .isExcludedFromBackupKey,
                .fileProtectionKey
            ]
        )
#if targetEnvironment(simulator)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              values.isSymbolicLink != true,
              values.isExcludedFromBackup == false else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
#else
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              values.isSymbolicLink != true,
              values.isExcludedFromBackup == false,
              values.fileProtection == .complete else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
#endif
    }

    private func validateRegularProtectedFile(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let values = try url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isExcludedFromBackupKey, .fileProtectionKey]
        )
#if targetEnvironment(simulator)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              values.isSymbolicLink != true,
              values.isExcludedFromBackup == false else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
#else
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              values.isSymbolicLink != true,
              values.isExcludedFromBackup == false,
              values.fileProtection == .complete else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
#endif
    }

    private func boundedFinalData(
        at url: URL,
        expectedByteCount: Int64
    ) throws -> Data {
        try validateRegularProtectedFile(at: url)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let sizeNumber = attributes[.size] as? NSNumber else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        let actualByteCount = sizeNumber.int64Value
        guard actualByteCount > 0 else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        guard actualByteCount <= Self.maximumFileBytes else {
            throw AttachmentFileStoreFailure.fileTooLarge
        }
        guard actualByteCount == expectedByteCount else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(
            upToCount: Int(Self.maximumFileBytes + 1)
        ) ?? Data()
        guard Int64(data.count) == actualByteCount else {
            throw AttachmentFileStoreFailure.integrityMismatch
        }
        return data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func rejectSymbolicLinkComponents(
        between root: URL,
        and directory: URL
    ) throws {
        let relative = directory.path.dropFirst(root.path.count)
        var current = root
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if (try? FileManager.default.destinationOfSymbolicLink(
                atPath: current.path
            )) != nil {
                throw AttachmentFileStoreFailure.unsafePath
            }
            guard FileManager.default.fileExists(atPath: current.path) else {
                break
            }
        }
    }

    private func writeJournal(_ journal: Journal) throws {
        try prepareDirectories()
        let url = journalURL(operationID: journal.operationID)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try hardenAndValidateRegularFile(at: url)
    }

    private func removeOperationArtifacts(
        operationID: UUID,
        removeFinal: Bool
    ) throws {
        let journalURL = journalURL(operationID: operationID)
        if removeFinal, FileManager.default.fileExists(atPath: journalURL.path) {
            let journal = try decodedJournal(at: journalURL)
            let finalURL = try fileURL(forRelativePath: journal.relativePath)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try removeEmptyAttachmentDirectory(
                relativePath: journal.relativePath
            )
        }
        let operationDirectory = stagingRoot.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: operationDirectory.path) {
            try FileManager.default.removeItem(at: operationDirectory)
        }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
    }

    private func loadJournal(operationID: UUID) throws -> Journal? {
        let url = journalURL(operationID: operationID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decodedJournal(at: url)
    }

    private func decodedJournal(at url: URL) throws -> Journal {
        try validateRegularProtectedFile(at: url)
        let journal = try JSONDecoder().decode(
            Journal.self,
            from: Data(contentsOf: url)
        )
        let filenameOperationID = url
            .deletingPathExtension()
            .lastPathComponent
        let validPhase: Bool
        switch journal.action {
        case .importFile:
            validPhase = journal.phase == .staged || journal.phase == .finalReady
        case .deleteFile:
            validPhase = journal.phase == .deletionPrepared
                || journal.phase == .deletionStaged
        }
        guard filenameOperationID == journal.operationID.uuidString.lowercased(),
              AttachmentPathFacts.isOpaquePath(
                  journal.relativePath,
                  attachmentID: journal.attachmentID,
                  typeIdentifier: journal.typeIdentifier
              ),
              validPhase else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        return journal
    }

    private func removeJournal(operationID: UUID) throws {
        let url = journalURL(operationID: operationID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func deletionTrashURL(operationID: UUID) -> URL {
        trashRoot
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("payload")
    }

    private func stagingPayloadURL(operationID: UUID) -> URL {
        stagingRoot
            .appendingPathComponent(
                operationID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("payload")
    }

    private func ensureNewOperation(
        operationID: UUID,
        finalRelativePath: String? = nil
    ) throws {
        let operationName = operationID.uuidString.lowercased()
        let stagingDirectory = stagingRoot.appendingPathComponent(
            operationName,
            isDirectory: true
        )
        let trashDirectory = trashRoot.appendingPathComponent(
            operationName,
            isDirectory: true
        )
        guard !FileManager.default.fileExists(
            atPath: journalURL(operationID: operationID).path
        ),
        !FileManager.default.fileExists(atPath: stagingDirectory.path),
        !FileManager.default.fileExists(atPath: trashDirectory.path) else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
        if let finalRelativePath {
            let finalURL = try fileURL(forRelativePath: finalRelativePath)
            guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
        }
    }

    private func removeEmptyAttachmentDirectory(
        relativePath: String
    ) throws {
        let finalURL = try fileURL(forRelativePath: relativePath)
        let ownerDirectory = finalURL.deletingLastPathComponent()
        guard ownerDirectory.deletingLastPathComponent().standardizedFileURL
                == attachmentRoot.standardizedFileURL,
              FileManager.default.fileExists(atPath: ownerDirectory.path),
              try FileManager.default.contentsOfDirectory(
                  at: ownerDirectory,
                  includingPropertiesForKeys: nil,
                  options: []
              ).isEmpty else {
            return
        }
        try FileManager.default.removeItem(at: ownerDirectory)
    }

    private func validateFinalAttachmentTree(
        committedAttachmentIDs: Set<UUID>
    ) throws {
        let ownerDirectories = try FileManager.default.contentsOfDirectory(
            at: attachmentRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var foundAttachmentIDs = Set<UUID>()
        for ownerDirectory in ownerDirectories {
            do {
                try validateProtectedDirectory(at: ownerDirectory)
            } catch {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
            guard
                  let attachmentID = UUID(
                      uuidString: ownerDirectory.lastPathComponent
                  ),
                  ownerDirectory.lastPathComponent
                      == attachmentID.uuidString.lowercased(),
                  committedAttachmentIDs.contains(attachmentID),
                  foundAttachmentIDs.insert(attachmentID).inserted else {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
            let payloads = try FileManager.default.contentsOfDirectory(
                at: ownerDirectory,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
            guard payloads.count == 1 else {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
            let payload = payloads[0]
            let relativePath = [
                "Attachments",
                ownerDirectory.lastPathComponent,
                payload.lastPathComponent
            ].joined(separator: "/")
            guard AttachmentPathFacts.isOpaquePath(
                relativePath,
                attachmentID: attachmentID
            ) else {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
            do {
                try validateRegularProtectedFile(at: payload)
            } catch {
                throw AttachmentFileStoreFailure.inconsistentJournal
            }
        }
        guard foundAttachmentIDs == committedAttachmentIDs else {
            throw AttachmentFileStoreFailure.inconsistentJournal
        }
    }

    private func removeDeletionArtifacts(operationID: UUID) throws {
        let operationDirectory = trashRoot.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: operationDirectory.path) {
            try FileManager.default.removeItem(at: operationDirectory)
        }
    }

    private func journalURL(operationID: UUID) -> URL {
        stagingRoot.appendingPathComponent(
            operationID.uuidString.lowercased() + ".json"
        )
    }

    private struct Journal: Codable {
        enum Action: String, Codable {
            case importFile
            case deleteFile
        }

        enum Phase: String, Codable {
            case staged
            case finalReady
            case deletionPrepared
            case deletionStaged
        }

        let operationID: UUID
        let attachmentID: UUID
        let relativePath: String
        let typeIdentifier: String
        let action: Action
        let phase: Phase
    }
}

enum AttachmentOwnerCapacity {
    static func validate(byteCounts: [Int64]) throws {
        guard byteCounts.count <= AttachmentFileStore.maximumOwnerFiles else {
            throw AttachmentFileStoreFailure.ownerLimitReached
        }
        var total: Int64 = 0
        for byteCount in byteCounts {
            guard byteCount > 0,
                  byteCount <= AttachmentFileStore.maximumFileBytes else {
                throw byteCount > AttachmentFileStore.maximumFileBytes
                    ? AttachmentFileStoreFailure.fileTooLarge
                    : AttachmentFileStoreFailure.invalidInput
            }
            let (next, overflow) = total.addingReportingOverflow(byteCount)
            guard !overflow,
                  next <= AttachmentFileStore.maximumOwnerBytes else {
                throw AttachmentFileStoreFailure.ownerLimitReached
            }
            total = next
        }
    }

    static func canAppend(
        byteCount: Int64,
        to existingByteCounts: [Int64]
    ) -> Bool {
        (try? validate(byteCounts: existingByteCounts + [byteCount])) != nil
    }
}

enum AttachmentMutationFailure: Error, Equatable, Sendable {
    case mutationInProgress
    case previewInProgress
    case recoveryRequired
}

final class AttachmentMutationRecoveryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }
}

actor AttachmentMutationService {
    private let writer: AppDataWriter
    private let fileStore: AttachmentFileStore
    private let ioQueue: AttachmentBlockingIOQueue
    private let recoveryLatch: AttachmentMutationRecoveryLatch
    private let onRecoveryRequired: @Sendable () async -> Void
    private var hasNotifiedRecovery = false
    private var mutationLeaseHeld = false
    private var deletingAttachmentIDs: Set<UUID> = []
    private var previewingAttachmentIDs: Set<UUID> = []

    init(
        writer: AppDataWriter,
        fileStore: AttachmentFileStore,
        recoveryLatch: AttachmentMutationRecoveryLatch =
            AttachmentMutationRecoveryLatch(),
        onRecoveryRequired: @escaping @Sendable () async -> Void
    ) {
        self.writer = writer
        self.fileStore = fileStore
        self.ioQueue = AttachmentBlockingIOQueue()
        self.recoveryLatch = recoveryLatch
        self.onRecoveryRequired = onRecoveryRequired
    }

    func addJourneyEntry(
        _ command: AddJourneyEntryCommand,
        attachmentDrafts: [AttachmentDraft]
    ) async throws {
        guard command.attachments.isEmpty else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        _ = try await commit(
            attachmentDrafts: attachmentDrafts
        ) { [writer] prepared in
            try await writer.addJourneyEntry(
                AddJourneyEntryCommand(
                    recordID: command.recordID,
                    text: command.text,
                    kind: command.kind,
                    occurredAt: command.occurredAt,
                    regimenVersionID: command.regimenVersionID,
                    timeZoneIdentifier: command.timeZoneIdentifier,
                    committedAt: command.committedAt,
                    attachments: prepared
                )
            )
        }
    }

    func createLabSample(
        _ command: CreateLabSampleCommand,
        attachmentDrafts: [AttachmentDraft]
    ) async throws -> LabSampleCommitResult {
        guard command.attachments.isEmpty else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        return try await commit(
            attachmentDrafts: attachmentDrafts
        ) { [writer] prepared in
            try await writer.createLabSample(
                CreateLabSampleCommand(
                    operationID: command.operationID,
                    sampleID: command.sampleID,
                    timestamp: command.timestamp,
                    specimenOriginal: command.specimenOriginal,
                    contextNote: command.contextNote,
                    newDefinitions: command.newDefinitions,
                    results: command.results,
                    attachments: prepared,
                    committedAt: command.committedAt
                )
            )
        }
    }

    func recordStatusObservation(
        _ command: RecordStatusObservationCommand,
        attachmentDrafts: [AttachmentDraft]
    ) async throws -> StatusObservationCommitResult {
        guard command.attachments.isEmpty else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        return try await commit(
            attachmentDrafts: attachmentDrafts
        ) { [writer] prepared in
            try await writer.recordStatusObservation(
                RecordStatusObservationCommand(
                    operationID: command.operationID,
                    observationID: command.observationID,
                    metricDefinitionID: command.metricDefinitionID,
                    newMetric: command.newMetric,
                    ordinalLevel: command.ordinalLevel,
                    note: command.note,
                    timestamp: command.timestamp,
                    attachments: prepared,
                    committedAt: command.committedAt
                )
            )
        }
    }

    func beginPreview(_ attachment: AttachmentSnapshot) async throws -> URL {
        guard !recoveryLatch.isInvalidated else {
            throw AttachmentMutationFailure.recoveryRequired
        }
        guard !deletingAttachmentIDs.contains(attachment.id),
              previewingAttachmentIDs.isEmpty else {
            throw AttachmentMutationFailure.mutationInProgress
        }
        guard acquireMutationLease() else {
            throw AttachmentMutationFailure.mutationInProgress
        }
        defer { releaseMutationLease() }
        previewingAttachmentIDs.insert(attachment.id)
        do {
            let url = try await ioQueue.perform { [fileStore] in
                try fileStore.auditedFileURL(for: attachment)
            }
            guard !recoveryLatch.isInvalidated else {
                previewingAttachmentIDs.remove(attachment.id)
                throw AttachmentMutationFailure.recoveryRequired
            }
            return url
        } catch {
            previewingAttachmentIDs.remove(attachment.id)
            if error as? AttachmentMutationFailure == .recoveryRequired {
                throw error
            }
            await requireRecovery()
            throw AttachmentMutationFailure.recoveryRequired
        }
    }

    func endPreview(attachmentID: UUID) {
        previewingAttachmentIDs.remove(attachmentID)
    }

    func deleteAttachment(_ attachment: AttachmentSnapshot) async throws {
        guard !recoveryLatch.isInvalidated else {
            throw AttachmentMutationFailure.recoveryRequired
        }
        guard previewingAttachmentIDs.isEmpty else {
            throw AttachmentMutationFailure.previewInProgress
        }
        guard acquireMutationLease() else {
            throw AttachmentMutationFailure.mutationInProgress
        }
        defer { releaseMutationLease() }
        guard deletingAttachmentIDs.insert(attachment.id).inserted else {
            throw AttachmentMutationFailure.mutationInProgress
        }
        defer {
            deletingAttachmentIDs.remove(attachment.id)
        }

        let operationID = UUID()
        let deletion: AttachmentStagedDeletion
        do {
            deletion = try await ioQueue.perform { [fileStore] in
                try fileStore.stageDeletion(
                    attachment: attachment,
                    operationID: operationID
                )
            }
        } catch {
            await requireRecovery()
            throw AttachmentMutationFailure.recoveryRequired
        }
        if recoveryLatch.isInvalidated {
            do {
                try await ioQueue.perform { [fileStore] in
                    try fileStore.rollbackDeletion(operationID: operationID)
                }
            } catch {
                await requireRecovery()
            }
            throw AttachmentMutationFailure.recoveryRequired
        }

        do {
            _ = try await writer.deleteAttachment(
                DeleteAttachmentCommand(
                    operationID: operationID,
                    attachmentID: attachment.id
                )
            )
        } catch {
            let recoveryWasRequired = recoveryLatch.isInvalidated
            do {
                try await ioQueue.perform { [fileStore] in
                    try fileStore.rollbackDeletion(operationID: operationID)
                }
            } catch {
                await requireRecovery()
                throw AttachmentMutationFailure.recoveryRequired
            }
            if recoveryWasRequired {
                throw AttachmentMutationFailure.recoveryRequired
            }
            throw error
        }

        do {
            try await ioQueue.perform { [fileStore] in
                try fileStore.finalizeDeletion(deletion)
            }
        } catch {
            await requireRecovery()
            throw AttachmentMutationFailure.recoveryRequired
        }
        guard !recoveryLatch.isInvalidated else {
            throw AttachmentMutationFailure.recoveryRequired
        }
    }

    private func commit<Output: Sendable>(
        attachmentDrafts: [AttachmentDraft],
        databaseWrite: @escaping @Sendable (
            [PreparedAttachmentMetadata]
        ) async throws -> Output
    ) async throws -> Output {
        guard !recoveryLatch.isInvalidated else {
            throw AttachmentMutationFailure.recoveryRequired
        }
        guard acquireMutationLease() else {
            throw AttachmentMutationFailure.mutationInProgress
        }
        defer { releaseMutationLease() }
        let prepared: [PreparedAttachmentMetadata]
        do {
            prepared = try await ioQueue.perform { [fileStore] in
                try Self.prepare(
                    attachmentDrafts,
                    fileStore: fileStore
                )
            }
        } catch {
            try await propagatePreparationFailure(error)
        }
        if recoveryLatch.isInvalidated {
            do {
                try await ioQueue.perform { [fileStore] in
                    try Self.discard(
                        prepared,
                        fileStore: fileStore
                    )
                }
            } catch {
                await requireRecovery()
            }
            throw AttachmentMutationFailure.recoveryRequired
        }

        let output: Output
        do {
            output = try await databaseWrite(prepared)
        } catch {
            let recoveryWasRequired = recoveryLatch.isInvalidated
            do {
                try await ioQueue.perform { [fileStore] in
                    try Self.discard(
                        prepared,
                        fileStore: fileStore
                    )
                }
            } catch {
                await requireRecovery()
                throw AttachmentMutationFailure.recoveryRequired
            }
            if recoveryWasRequired {
                throw AttachmentMutationFailure.recoveryRequired
            }
            throw error
        }

        do {
            try await ioQueue.perform { [fileStore] in
                for attachment in prepared {
                    try fileStore.markMetadataCommitted(attachment)
                }
            }
        } catch {
            await requireRecovery()
            throw AttachmentMutationFailure.recoveryRequired
        }
        guard !recoveryLatch.isInvalidated else {
            throw AttachmentMutationFailure.recoveryRequired
        }
        return output
    }

    private static func prepare(
        _ drafts: [AttachmentDraft],
        fileStore: AttachmentFileStore
    ) throws -> [PreparedAttachmentMetadata] {
        try AttachmentOwnerCapacity.validate(
            byteCounts: drafts.map { Int64($0.data.count) }
        )
        var prepared: [PreparedAttachmentMetadata] = []
        do {
            for draft in drafts {
                let staged = try fileStore.stage(
                    data: draft.data,
                    attachmentID: UUID(),
                    originalFilename: draft.filename,
                    typeIdentifier: draft.typeIdentifier,
                    operationID: UUID()
                )
                let metadata = PreparedAttachmentMetadata(staged)
                prepared.append(metadata)
                _ = try fileStore.commit(staged)
            }
            return prepared
        } catch {
            do {
                try discard(prepared, fileStore: fileStore)
            } catch {
                throw AttachmentMutationFailure.recoveryRequired
            }
            throw error
        }
    }

    private static func discard(
        _ attachments: [PreparedAttachmentMetadata],
        fileStore: AttachmentFileStore
    ) throws {
        var firstFailure: Error?
        for attachment in attachments {
            do {
                try fileStore.discard(operationID: attachment.operationID)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if firstFailure != nil {
            throw AttachmentMutationFailure.recoveryRequired
        }
    }

    private func propagatePreparationFailure(
        _ error: Error
    ) async throws -> Never {
        if Self.requiresRecovery(error) {
            await requireRecovery()
            throw AttachmentMutationFailure.recoveryRequired
        }
        throw error
    }

    private static func requiresRecovery(_ error: Error) -> Bool {
        if error as? AttachmentMutationFailure == .recoveryRequired {
            return true
        }
        switch error as? AttachmentFileStoreFailure {
        case .integrityMismatch, .inconsistentJournal, .unsafePath,
             .recoveryRequired:
            return true
        case .invalidInput, .fileTooLarge, .ownerLimitReached,
             .simulatedInterruption, .none:
            return false
        }
    }

    private func requireRecovery() async {
        recoveryLatch.invalidate()
        guard !hasNotifiedRecovery else { return }
        hasNotifiedRecovery = true
        await onRecoveryRequired()
    }

    private func acquireMutationLease() -> Bool {
        guard !mutationLeaseHeld else { return false }
        mutationLeaseHeld = true
        return true
    }

    private func releaseMutationLease() {
        mutationLeaseHeld = false
    }
}

private final class AttachmentBlockingIOQueue: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.mtfbook.unmanual.attachment-io",
        qos: .userInitiated
    )

    func perform<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct AttachmentMutationServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue: AttachmentMutationService? = nil
}

extension EnvironmentValues {
    var attachmentMutationService: AttachmentMutationService? {
        get { self[AttachmentMutationServiceEnvironmentKey.self] }
        set { self[AttachmentMutationServiceEnvironmentKey.self] = newValue }
    }
}

struct AttachmentIntegrityFailureHandler: Sendable {
    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    @MainActor
    func callAsFunction() {
        action()
    }
}

private struct AttachmentIntegrityFailureHandlerEnvironmentKey: EnvironmentKey {
    static let defaultValue: AttachmentIntegrityFailureHandler? = nil
}

extension EnvironmentValues {
    var attachmentIntegrityFailureHandler: AttachmentIntegrityFailureHandler? {
        get { self[AttachmentIntegrityFailureHandlerEnvironmentKey.self] }
        set { self[AttachmentIntegrityFailureHandlerEnvironmentKey.self] = newValue }
    }
}
