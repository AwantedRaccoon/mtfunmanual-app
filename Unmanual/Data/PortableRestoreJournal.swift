import CryptoKit
import Foundation

enum PortableRestorePhase: String, Codable, CaseIterable, Sendable {
    case preparingTarget
    case targetDirectoryPrepared
    case databaseWritten
    case attachmentsCopied
    case targetPrepared
    case targetValidated
    case restartRequired
    case activationCleanupPending
    case activated

    var ordinal: Int {
        switch self {
        case .preparingTarget: 0
        case .targetDirectoryPrepared: 1
        case .databaseWritten: 2
        case .attachmentsCopied: 3
        case .targetPrepared: 4
        case .targetValidated: 5
        case .restartRequired: 6
        case .activationCleanupPending: 7
        case .activated: 8
        }
    }
}

struct PortableRestoreJournal: Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let operationID: UUID
    let mode: PortableImportMode
    let sourceGenerationID: UUID
    let sourceDatasetID: UUID
    let targetGenerationID: UUID
    let targetDatasetID: UUID
    let packageRootDigest: String
    let stagingRelativePath: String
    let confirmedLocalStateDigest: String
    let dryRunTokenSHA256: String
    let factCount: Int
    let revisionCount: Int
    let targetNextLocalRevision: Int64
    let attachmentCount: Int
    let attachmentManifestDigest: String
    let resetsAppLockForLocalConfirmation: Bool
    let requiresNotificationReconciliation: Bool
    let devicePolicyOperationID: UUID
    let devicePolicyCommittedAtMicroseconds: Int64
    let contractSHA256: String
    var phase: PortableRestorePhase
    var updatedAt: Date

    init(
        operationID: UUID = UUID(),
        mode: PortableImportMode,
        sourceGenerationID: UUID,
        sourceDatasetID: UUID,
        targetGenerationID: UUID,
        targetDatasetID: UUID,
        packageRootDigest: String,
        stagingRelativePath: String? = nil,
        confirmedLocalStateDigest: String,
        dryRunTokenSHA256: String,
        factCount: Int,
        revisionCount: Int,
        targetNextLocalRevision: Int64,
        attachmentCount: Int,
        attachmentManifestDigest: String,
        resetsAppLockForLocalConfirmation: Bool = true,
        requiresNotificationReconciliation: Bool = true,
        devicePolicyOperationID: UUID = UUID(),
        devicePolicyCommittedAtMicroseconds: Int64,
        phase: PortableRestorePhase = .preparingTarget,
        updatedAt: Date = Date()
    ) {
        self.formatVersion = Self.formatVersion
        self.operationID = operationID
        self.mode = mode
        self.sourceGenerationID = sourceGenerationID
        self.sourceDatasetID = sourceDatasetID
        self.targetGenerationID = targetGenerationID
        self.targetDatasetID = targetDatasetID
        self.packageRootDigest = packageRootDigest
        self.stagingRelativePath = stagingRelativePath
            ?? Self.stagingRelativePath(
                operationID: operationID
            )
        self.confirmedLocalStateDigest =
            confirmedLocalStateDigest
        self.dryRunTokenSHA256 = dryRunTokenSHA256
        self.factCount = factCount
        self.revisionCount = revisionCount
        self.targetNextLocalRevision =
            targetNextLocalRevision
        self.attachmentCount = attachmentCount
        self.attachmentManifestDigest = attachmentManifestDigest
        self.resetsAppLockForLocalConfirmation =
            resetsAppLockForLocalConfirmation
        self.requiresNotificationReconciliation =
            requiresNotificationReconciliation
        self.devicePolicyOperationID =
            devicePolicyOperationID
        self.devicePolicyCommittedAtMicroseconds =
            devicePolicyCommittedAtMicroseconds
        self.phase = phase
        self.updatedAt = Date(
            timeIntervalSince1970: floor(
                updatedAt.timeIntervalSince1970
            )
        )
        self.contractSHA256 = Self.contractDigest(
            formatVersion: Self.formatVersion,
            operationID: operationID,
            mode: mode,
            sourceGenerationID: sourceGenerationID,
            sourceDatasetID: sourceDatasetID,
            targetGenerationID: targetGenerationID,
            targetDatasetID: targetDatasetID,
            packageRootDigest: packageRootDigest,
            stagingRelativePath:
                self.stagingRelativePath,
            confirmedLocalStateDigest:
                confirmedLocalStateDigest,
            dryRunTokenSHA256: dryRunTokenSHA256,
            factCount: factCount,
            revisionCount: revisionCount,
            targetNextLocalRevision:
                targetNextLocalRevision,
            attachmentCount: attachmentCount,
            attachmentManifestDigest:
                attachmentManifestDigest,
            resetsAppLockForLocalConfirmation:
                resetsAppLockForLocalConfirmation,
            requiresNotificationReconciliation:
                requiresNotificationReconciliation,
            devicePolicyOperationID:
                devicePolicyOperationID,
            devicePolicyCommittedAtMicroseconds:
                devicePolicyCommittedAtMicroseconds
        )
    }

    static func stagingRelativePath(
        operationID: UUID
    ) -> String {
        "PortableImports/"
            + operationID.uuidString.lowercased()
            + "/package.unmanualbackup"
    }

    func stagingURL(
        in layout: AppDataStoreLayout
    ) -> URL {
        layout.recoveryURL.appending(
            path: stagingRelativePath,
            directoryHint: .isDirectory
        )
    }

    fileprivate static func contractDigest(
        formatVersion: Int,
        operationID: UUID,
        mode: PortableImportMode,
        sourceGenerationID: UUID,
        sourceDatasetID: UUID,
        targetGenerationID: UUID,
        targetDatasetID: UUID,
        packageRootDigest: String,
        stagingRelativePath: String,
        confirmedLocalStateDigest: String,
        dryRunTokenSHA256: String,
        factCount: Int,
        revisionCount: Int,
        targetNextLocalRevision: Int64,
        attachmentCount: Int,
        attachmentManifestDigest: String,
        resetsAppLockForLocalConfirmation: Bool,
        requiresNotificationReconciliation: Bool,
        devicePolicyOperationID: UUID,
        devicePolicyCommittedAtMicroseconds: Int64
    ) -> String {
        let components = [
            String(formatVersion),
            operationID.uuidString.lowercased(),
            mode.rawValue,
            sourceGenerationID.uuidString.lowercased(),
            sourceDatasetID.uuidString.lowercased(),
            targetGenerationID.uuidString.lowercased(),
            targetDatasetID.uuidString.lowercased(),
            packageRootDigest,
            stagingRelativePath,
            confirmedLocalStateDigest,
            dryRunTokenSHA256,
            String(factCount),
            String(revisionCount),
            String(targetNextLocalRevision),
            String(attachmentCount),
            attachmentManifestDigest,
            resetsAppLockForLocalConfirmation ? "1" : "0",
            requiresNotificationReconciliation ? "1" : "0",
            devicePolicyOperationID.uuidString.lowercased(),
            String(devicePolicyCommittedAtMicroseconds)
        ]
        return SHA256.hash(
            data: Data(
                components.joined(
                    separator: "\u{001f}"
                ).utf8
            )
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }
}

enum PortableRestoreJournalError: Error, Equatable {
    case absent
    case invalid
    case invalidTransition
}

struct PortableRestoreJournalStore: Sendable {
    let layout: AppDataStoreLayout
    let backupPolicy: SystemBackupPolicy
    let beforeWrite:
        PortableManagedPathSecurity.MutationProbe

    init(
        layout: AppDataStoreLayout,
        backupPolicy: SystemBackupPolicy = .production,
        beforeWrite:
            @escaping PortableManagedPathSecurity
            .MutationProbe = {}
    ) {
        self.layout = layout
        self.backupPolicy = backupPolicy
        self.beforeWrite = beforeWrite
    }

    func read() throws -> PortableRestoreJournal {
        do {
            guard let data = try
                PortableManagedPathSecurity
                .readRecoveryRegularFileIfPresent(
                    layout: layout,
                    fileName:
                        "portable-restore-journal.json",
                    maximumBytes: 64 * 1_024
                ) else {
                throw PortableRestoreJournalError.absent
            }
            try StrictJSONDuplicateKeyScanner.validate(
                data,
                maximumDepth: 16,
                maximumStringBytes: 8 * 1_024
            )
            let object = try JSONSerialization.jsonObject(
                with: data
            )
            guard let dictionary = object as? [String: Any],
                  Set(dictionary.keys) == [
                      "formatVersion", "operationID", "mode",
                      "sourceGenerationID", "sourceDatasetID",
                      "targetGenerationID", "targetDatasetID",
                      "packageRootDigest", "stagingRelativePath",
                      "confirmedLocalStateDigest",
                      "dryRunTokenSHA256",
                      "factCount", "revisionCount",
                      "targetNextLocalRevision",
                      "attachmentCount",
                      "attachmentManifestDigest",
                      "resetsAppLockForLocalConfirmation",
                      "requiresNotificationReconciliation",
                      "devicePolicyOperationID",
                      "devicePolicyCommittedAtMicroseconds",
                      "contractSHA256",
                      "phase", "updatedAt"
                  ] else {
                throw PortableRestoreJournalError.invalid
            }
            let value = try JSONDecoder.unmanualFoundation
                .decode(PortableRestoreJournal.self, from: data)
            try validate(value)
            return value
        } catch let error as PortableRestoreJournalError {
            throw error
        } catch {
            throw PortableRestoreJournalError.invalid
        }
    }

    func readIfPresent() throws -> PortableRestoreJournal? {
        do {
            return try read()
        } catch PortableRestoreJournalError.absent {
            return nil
        }
    }

    func write(
        _ value: PortableRestoreJournal,
        replacing oldValue: PortableRestoreJournal? = nil
    ) throws {
        try validate(value)
        if let oldValue {
            guard oldValue.operationID == value.operationID,
                  oldValue.sourceGenerationID
                    == value.sourceGenerationID,
                  oldValue.targetGenerationID
                    == value.targetGenerationID,
                  oldValue.sourceDatasetID
                    == value.sourceDatasetID,
                  oldValue.targetDatasetID
                    == value.targetDatasetID,
                  oldValue.packageRootDigest
                    == value.packageRootDigest,
                  oldValue.mode == value.mode,
                  oldValue.stagingRelativePath
                    == value.stagingRelativePath,
                  oldValue.confirmedLocalStateDigest
                    == value.confirmedLocalStateDigest,
                  oldValue.dryRunTokenSHA256
                    == value.dryRunTokenSHA256,
                  oldValue.factCount == value.factCount,
                  oldValue.revisionCount
                    == value.revisionCount,
                  oldValue.targetNextLocalRevision
                    == value.targetNextLocalRevision,
                  oldValue.attachmentCount
                    == value.attachmentCount,
                  oldValue.attachmentManifestDigest
                    == value.attachmentManifestDigest,
                  oldValue.resetsAppLockForLocalConfirmation
                    == value.resetsAppLockForLocalConfirmation,
                  oldValue.requiresNotificationReconciliation
                    == value.requiresNotificationReconciliation,
                  oldValue.devicePolicyOperationID
                    == value.devicePolicyOperationID,
                  oldValue.devicePolicyCommittedAtMicroseconds
                    == value.devicePolicyCommittedAtMicroseconds,
                  oldValue.contractSHA256
                    == value.contractSHA256,
                  value.phase.ordinal
                    == oldValue.phase.ordinal
                    || value.phase.ordinal
                        == oldValue.phase.ordinal + 1 else {
                throw PortableRestoreJournalError
                    .invalidTransition
            }
        }
        let data = try JSONEncoder
            .unmanualFoundation.encode(value)
        let readback: Data
        do {
            readback = try PortableManagedPathSecurity
                .writeRecoveryRegularFile(
                    layout: layout,
                    fileName:
                        "portable-restore-journal.json",
                    data: data,
                    maximumBytes: 64 * 1_024,
                    backupPolicy: backupPolicy,
                    beforeWrite: beforeWrite
                )
        } catch {
            throw PortableRestoreJournalError.invalid
        }
        guard readback == data else {
            throw PortableRestoreJournalError.invalid
        }
        guard try read() == value else {
            throw PortableRestoreJournalError.invalid
        }
    }

    private func validate(
        _ value: PortableRestoreJournal
    ) throws {
        guard value.formatVersion
                == PortableRestoreJournal.formatVersion,
              value.mode == .restore || value.mode == .replace,
              value.sourceGenerationID
                != value.targetGenerationID,
              value.factCount >= 0,
              value.factCount == value.revisionCount,
              value.targetNextLocalRevision > 0,
              value.attachmentCount >= 0,
              value.packageRootDigest.isLowercaseSHA256,
              value.confirmedLocalStateDigest
                .isLowercaseSHA256,
              value.dryRunTokenSHA256.isLowercaseSHA256,
              value.attachmentManifestDigest
                .isLowercaseSHA256,
              value.resetsAppLockForLocalConfirmation,
              value.requiresNotificationReconciliation,
              value.devicePolicyCommittedAtMicroseconds
                != Int64.min,
              value.contractSHA256 == PortableRestoreJournal
                .contractDigest(
                    formatVersion: value.formatVersion,
                    operationID: value.operationID,
                    mode: value.mode,
                    sourceGenerationID:
                        value.sourceGenerationID,
                    sourceDatasetID:
                        value.sourceDatasetID,
                    targetGenerationID:
                        value.targetGenerationID,
                    targetDatasetID:
                        value.targetDatasetID,
                    packageRootDigest:
                        value.packageRootDigest,
                    stagingRelativePath:
                        value.stagingRelativePath,
                    confirmedLocalStateDigest:
                        value.confirmedLocalStateDigest,
                    dryRunTokenSHA256:
                        value.dryRunTokenSHA256,
                    factCount: value.factCount,
                    revisionCount: value.revisionCount,
                    targetNextLocalRevision:
                        value.targetNextLocalRevision,
                    attachmentCount:
                        value.attachmentCount,
                    attachmentManifestDigest:
                        value.attachmentManifestDigest,
                    resetsAppLockForLocalConfirmation:
                        value.resetsAppLockForLocalConfirmation,
                    requiresNotificationReconciliation:
                        value.requiresNotificationReconciliation,
                    devicePolicyOperationID:
                        value.devicePolicyOperationID,
                    devicePolicyCommittedAtMicroseconds:
                        value.devicePolicyCommittedAtMicroseconds
                ),
              value.updatedAt.timeIntervalSince1970.isFinite,
              value.stagingRelativePath
                == PortableRestoreJournal.stagingRelativePath(
                    operationID: value.operationID
                ),
              value.stagingURL(in: layout)
                .standardizedFileURL.path.hasPrefix(
                    layout.portableRestoreStagingRootURL
                        .standardizedFileURL.path + "/"
                ) else {
            throw PortableRestoreJournalError.invalid
        }
    }
}

private extension String {
    var isLowercaseSHA256: Bool {
        count == 64
            && utf8.allSatisfy {
                (48...57).contains($0)
                    || (97...102).contains($0)
            }
    }
}
