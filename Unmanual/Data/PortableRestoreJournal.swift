import CryptoKit
import Darwin
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

struct PortableRestoreTargetAncestry:
    Codable, Equatable, Sendable {
    let containerParent: PortableArtifactIdentity
    let root: PortableArtifactIdentity
    let generations: PortableArtifactIdentity
    let target: PortableArtifactIdentity
    let store: PortableArtifactIdentity
    let files: PortableArtifactIdentity
    let containerParentMode: UInt32
    let rootMode: UInt32
    let generationsMode: UInt32
    let targetMode: UInt32
    let storeMode: UInt32
    let filesMode: UInt32

    var allIdentities: [PortableArtifactIdentity] {
        [
            containerParent, root, generations,
            target, store, files
        ]
    }

    var allModes: [UInt32] {
        [
            containerParentMode, rootMode,
            generationsMode, targetMode,
            storeMode, filesMode
        ]
    }
}

struct PortableRestoreJournal: Codable, Equatable, Sendable {
    static let formatVersion = 2

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
    var targetRootIdentity: PortableArtifactIdentity?
    var targetAncestry: PortableRestoreTargetAncestry?
    var phase: PortableRestorePhase
    var updatedAt: Date
    var stateSHA256: String

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
        targetRootIdentity:
            PortableArtifactIdentity? = nil,
        targetAncestry:
            PortableRestoreTargetAncestry? = nil,
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
        self.targetRootIdentity = targetRootIdentity
        self.targetAncestry = targetAncestry
        self.phase = phase
        let normalizedUpdatedAt = Date(
            timeIntervalSince1970: floor(
                updatedAt.timeIntervalSince1970
            )
        )
        self.updatedAt = normalizedUpdatedAt
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
        self.stateSHA256 = Self.stateDigest(
            contractSHA256: self.contractSHA256,
            targetRootIdentity: targetRootIdentity,
            targetAncestry: targetAncestry,
            phase: phase,
            updatedAt: normalizedUpdatedAt
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

    fileprivate static func stateDigest(
        contractSHA256: String,
        targetRootIdentity: PortableArtifactIdentity?,
        targetAncestry: PortableRestoreTargetAncestry?,
        phase: PortableRestorePhase,
        updatedAt: Date
    ) -> String {
        let seconds = Int64(
            exactly: updatedAt.timeIntervalSince1970
        ).map(String.init) ?? "invalid"
        var components = [
            contractSHA256,
            phase.rawValue,
            seconds
        ]
        if let targetRootIdentity {
            components += [
                String(targetRootIdentity.deviceID),
                String(targetRootIdentity.inode),
                String(targetRootIdentity.fileType)
            ]
        }
        if let targetAncestry {
            for identity in targetAncestry.allIdentities {
                components += [
                    String(identity.deviceID),
                    String(identity.inode),
                    String(identity.fileType)
                ]
            }
            components += targetAncestry.allModes
                .map(String.init)
        }
        let value = components.joined(separator: "\u{001f}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    mutating func advanceState(
        to phase: PortableRestorePhase,
        updatedAt: Date
    ) {
        let normalized = Date(
            timeIntervalSince1970: floor(
                updatedAt.timeIntervalSince1970
            )
        )
        self.phase = phase
        self.updatedAt = normalized
        self.stateSHA256 = Self.stateDigest(
            contractSHA256: contractSHA256,
            targetRootIdentity: targetRootIdentity,
            targetAncestry: targetAncestry,
            phase: phase,
            updatedAt: normalized
        )
    }

    mutating func bindTargetRoot(
        _ identity: PortableArtifactIdentity
    ) {
        targetRootIdentity = identity
        targetAncestry = nil
        stateSHA256 = Self.stateDigest(
            contractSHA256: contractSHA256,
            targetRootIdentity: identity,
            targetAncestry: nil,
            phase: phase,
            updatedAt: updatedAt
        )
    }

    mutating func bindTargetAncestry(
        _ ancestry: PortableRestoreTargetAncestry
    ) {
        targetRootIdentity = ancestry.target
        targetAncestry = ancestry
        stateSHA256 = Self.stateDigest(
            contractSHA256: contractSHA256,
            targetRootIdentity: ancestry.target,
            targetAncestry: ancestry,
            phase: phase,
            updatedAt: updatedAt
        )
    }

    mutating func clearTargetAncestry() {
        targetAncestry = nil
        stateSHA256 = Self.stateDigest(
            contractSHA256: contractSHA256,
            targetRootIdentity: targetRootIdentity,
            targetAncestry: nil,
            phase: phase,
            updatedAt: updatedAt
        )
    }
}

private struct LegacyPortableRestoreJournalV1:
    Codable, Equatable, Sendable {
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
    let phase: PortableRestorePhase
    let updatedAt: Date
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
    let afterPublish:
        PortableManagedPathSecurity.MutationProbe

    init(
        layout: AppDataStoreLayout,
        backupPolicy: SystemBackupPolicy = .production,
        beforeWrite:
            @escaping PortableManagedPathSecurity
            .MutationProbe = {},
        afterPublish:
            @escaping PortableManagedPathSecurity
            .MutationProbe = {}
    ) {
        self.layout = layout
        self.backupPolicy = backupPolicy
        self.beforeWrite = beforeWrite
        self.afterPublish = afterPublish
    }

    func read() throws -> PortableRestoreJournal {
        do {
            guard let data = try
                PortableManagedPathSecurity
                .readRecoveryRegularFileIfPresent(
                    layout: layout,
                    fileName:
                        "portable-restore-journal.json",
                    maximumBytes: 64 * 1_024,
                    validator: {
                        (try? decodeValidatedStoredValue($0))
                            != nil
                    }
                ) else {
                throw PortableRestoreJournalError.absent
            }
            switch try decodeValidatedStoredValue(data) {
            case let .legacy(legacy):
                let migrated = try migrate(legacy)
                try persistMigration(migrated)
                return migrated
            case let .current(value):
                return value
            }
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
                  oldValue.targetAncestry == nil
                    || oldValue.targetAncestry
                        == value.targetAncestry
                    || (
                        oldValue.phase
                            == .targetDirectoryPrepared
                            && value.phase
                                == .targetDirectoryPrepared
                            && value.targetAncestry == nil
                    ),
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
                    beforeWrite: beforeWrite,
                    afterPublish: afterPublish,
                    validator: {
                        (try? decodeValidatedStoredValue($0))
                            != nil
                    }
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

    private enum ValidatedStoredValue {
        case legacy(LegacyPortableRestoreJournalV1)
        case current(PortableRestoreJournal)
    }

    private func decodeValidatedStoredValue(
        _ data: Data
    ) throws -> ValidatedStoredValue {
        try StrictJSONDuplicateKeyScanner.validate(
            data,
            maximumDepth: 16,
            maximumStringBytes: 8 * 1_024
        )
        let object = try JSONSerialization.jsonObject(
            with: data
        )
        guard let dictionary =
                object as? [String: Any],
              let formatVersion =
                dictionary["formatVersion"] as? Int else {
            throw PortableRestoreJournalError.invalid
        }
        let legacyKeys: Set<String> = [
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
        ]
        if formatVersion
            == LegacyPortableRestoreJournalV1
                .formatVersion {
            guard Set(dictionary.keys)
                    == legacyKeys else {
                throw PortableRestoreJournalError
                    .invalid
            }
            let legacy = try JSONDecoder
                .unmanualFoundation.decode(
                    LegacyPortableRestoreJournalV1
                        .self,
                    from: data
                )
            try validate(legacy)
            return .legacy(legacy)
        }
        guard formatVersion
                == PortableRestoreJournal
                    .formatVersion else {
            throw PortableRestoreJournalError.invalid
        }
        let baseKeys = legacyKeys.union([
            "stateSHA256"
        ])
        let keys = Set(dictionary.keys)
        guard keys == baseKeys
                || keys == baseKeys.union([
                    "targetRootIdentity"
                ])
                || keys == baseKeys.union([
                    "targetRootIdentity",
                    "targetAncestry"
                ]) else {
            throw PortableRestoreJournalError.invalid
        }
        if keys.contains("targetRootIdentity") {
            guard let identity =
                    dictionary["targetRootIdentity"]
                    as? [String: Any],
                  Set(identity.keys) == [
                    "deviceID", "inode", "fileType"
                  ] else {
                throw PortableRestoreJournalError.invalid
            }
        }
        if keys.contains("targetAncestry") {
            guard let ancestry =
                    dictionary["targetAncestry"]
                    as? [String: Any],
                  Set(ancestry.keys) == [
                    "containerParent", "root",
                    "generations", "target",
                    "store", "files",
                    "containerParentMode", "rootMode",
                    "generationsMode", "targetMode",
                    "storeMode", "filesMode"
                  ],
                  [
                    "containerParent", "root",
                    "generations", "target",
                    "store", "files"
                  ].allSatisfy({
                      key in
                      guard let identity =
                        ancestry[key]
                            as? [String: Any] else {
                          return false
                      }
                      return Set(identity.keys) == [
                        "deviceID", "inode", "fileType"
                      ]
                  }) else {
                throw PortableRestoreJournalError.invalid
            }
        }
        let value = try JSONDecoder
            .unmanualFoundation.decode(
                PortableRestoreJournal.self,
                from: data
            )
        try validate(value)
        return .current(value)
    }

    private func migrate(
        _ legacy: LegacyPortableRestoreJournalV1
    ) throws -> PortableRestoreJournal {
        let pointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let sourceIsActive =
            pointer.generationID
                == legacy.sourceGenerationID
            && pointer.datasetID
                == legacy.sourceDatasetID
        let targetIsActive =
            pointer.generationID
                == legacy.targetGenerationID
            && pointer.datasetID
                == legacy.targetDatasetID
        guard sourceIsActive != targetIsActive else {
            throw PortableRestoreJournalError.invalid
        }

        let targetURL = layout.generationDirectoryURL(
            for: legacy.targetGenerationID
        )
        let targetIdentity = try legacyTargetIdentity(
            at: targetURL
        )
        let migratedPhase: PortableRestorePhase
        var ancestry: PortableRestoreTargetAncestry?

        if sourceIsActive {
            guard legacy.phase.ordinal
                    < PortableRestorePhase
                        .activationCleanupPending.ordinal else {
                throw PortableRestoreJournalError.invalid
            }
            if targetIdentity == nil {
                migratedPhase = .preparingTarget
            } else {
                // Any inactive v1 target is treated as rebuildable staging.
                // The v2 builder will reset only this captured inode before
                // recreating its contents.
                migratedPhase = .targetDirectoryPrepared
            }
            ancestry = nil
        } else {
            guard legacy.phase.ordinal
                    >= PortableRestorePhase
                        .restartRequired.ordinal,
                  let targetIdentity else {
                throw PortableRestoreJournalError.invalid
            }
            // An activated v1 target must already contain both managed
            // namespaces. Acquisition may not create missing active state.
            guard try legacyTargetIdentity(
                    at: targetURL.appending(
                        path: "Store",
                        directoryHint: .isDirectory
                    )
                  ) != nil,
                  try legacyTargetIdentity(
                    at: targetURL.appending(
                        path: "Files",
                        directoryHint: .isDirectory
                    )
                  ) != nil else {
                throw PortableRestoreJournalError.invalid
            }
            let lease = try PortableManagedPathSecurity
                .GenerationTargetLease.acquire(
                    layout: layout,
                    generationName:
                        legacy.targetGenerationID
                        .uuidString.lowercased(),
                    expectedTarget: targetIdentity
                )
            ancestry = lease.ancestry
            migratedPhase = legacy.phase
        }

        return PortableRestoreJournal(
            operationID: legacy.operationID,
            mode: legacy.mode,
            sourceGenerationID:
                legacy.sourceGenerationID,
            sourceDatasetID: legacy.sourceDatasetID,
            targetGenerationID:
                legacy.targetGenerationID,
            targetDatasetID: legacy.targetDatasetID,
            packageRootDigest: legacy.packageRootDigest,
            stagingRelativePath:
                legacy.stagingRelativePath,
            confirmedLocalStateDigest:
                legacy.confirmedLocalStateDigest,
            dryRunTokenSHA256:
                legacy.dryRunTokenSHA256,
            factCount: legacy.factCount,
            revisionCount: legacy.revisionCount,
            targetNextLocalRevision:
                legacy.targetNextLocalRevision,
            attachmentCount: legacy.attachmentCount,
            attachmentManifestDigest:
                legacy.attachmentManifestDigest,
            resetsAppLockForLocalConfirmation:
                legacy.resetsAppLockForLocalConfirmation,
            requiresNotificationReconciliation:
                legacy.requiresNotificationReconciliation,
            devicePolicyOperationID:
                legacy.devicePolicyOperationID,
            devicePolicyCommittedAtMicroseconds:
                legacy.devicePolicyCommittedAtMicroseconds,
            phase: migratedPhase,
            targetRootIdentity: targetIdentity,
            targetAncestry: ancestry,
            updatedAt: legacy.updatedAt
        )
    }

    private func legacyTargetIdentity(
        at url: URL
    ) throws -> PortableArtifactIdentity? {
        var value = stat()
        let result = url.path.withCString {
            Darwin.lstat($0, &value)
        }
        if result != 0 {
            guard errno == ENOENT else {
                throw PortableRestoreJournalError.invalid
            }
            return nil
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR else {
            throw PortableRestoreJournalError.invalid
        }
        do {
            return try PortableManagedPathSecurity
                .directoryIdentity(at: url)
        } catch {
            throw PortableRestoreJournalError.invalid
        }
    }

    private func persistMigration(
        _ value: PortableRestoreJournal
    ) throws {
        do {
            try write(value)
        } catch {
            throw PortableRestoreJournalError.invalid
        }
    }

    private func validate(
        _ value: LegacyPortableRestoreJournalV1
    ) throws {
        guard value.formatVersion
                == LegacyPortableRestoreJournalV1.formatVersion,
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
              value.updatedAt.timeIntervalSince1970
                == floor(value.updatedAt.timeIntervalSince1970),
              Int64(
                exactly: value.updatedAt
                    .timeIntervalSince1970
              ) != nil,
              value.stagingRelativePath
                == PortableRestoreJournal.stagingRelativePath(
                    operationID: value.operationID
                ),
              layout.recoveryURL.appending(
                    path: value.stagingRelativePath,
                    directoryHint: .isDirectory
              )
                .standardizedFileURL.path.hasPrefix(
                    layout.portableRestoreStagingRootURL
                        .standardizedFileURL.path + "/"
                ) else {
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
              value.updatedAt.timeIntervalSince1970
                == floor(value.updatedAt.timeIntervalSince1970),
              Int64(
                exactly:
                    value.updatedAt.timeIntervalSince1970
              ) != nil,
              value.stateSHA256 == PortableRestoreJournal
                .stateDigest(
                    contractSHA256: value.contractSHA256,
                    targetRootIdentity:
                        value.targetRootIdentity,
                    targetAncestry:
                        value.targetAncestry,
                    phase: value.phase,
                    updatedAt: value.updatedAt
                ),
              (value.targetRootIdentity.map {
                  $0.inode > 0
                      && $0.fileType == UInt32(S_IFDIR)
              } ?? true),
              (value.targetAncestry.map {
                  $0.target == value.targetRootIdentity
                      && $0.allIdentities.allSatisfy {
                          $0.inode > 0
                              && $0.fileType
                                == UInt32(S_IFDIR)
                      }
                      && $0.allModes.allSatisfy {
                          $0 > 0 && $0 <= 0o7777
                      }
              } ?? true),
              value.phase == .preparingTarget
                || value.targetRootIdentity != nil,
              value.phase.ordinal
                    < PortableRestorePhase
                        .databaseWritten.ordinal
                || value.targetAncestry != nil,
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
