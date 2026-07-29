import CryptoKit
import Foundation
import SwiftData

enum PortableRestoreServiceError:
    Error, Equatable, Sendable {
    case unavailable
    case invalidPlan
    case impactChanged
    case unsafeTarget
    case packageChanged
    case targetInvalid
    case notificationObservationUnstable
    case notificationConvergenceFailed
    case recoveryRequired
}

struct PortableRestorePreparedOperation: Sendable {
    let journal: PortableRestoreJournal
    let coordinator: AppDataControlCoordinator
    let lease:
        AppDataControlCoordinator.ExclusiveResetLease
}

actor PortableRestorePreparationService {
    typealias TargetAdvancer = @Sendable (
        _ journal: PortableRestoreJournal,
        _ layout: AppDataStoreLayout,
        _ verificationMode: StoreFileProtectionVerificationMode
    ) async throws -> PortableRestoreJournal

    private let store: BootstrappedAppDataStore
    private let inventory:
        DataInventoryProductionService
    private let coordinator: AppDataControlCoordinator
    private let portablePackageCleanup:
        PortablePackageCleanupCoordinator?
    private let drainTimeout: Duration
    private let verificationMode:
        StoreFileProtectionVerificationMode
    private let targetAdvancer: TargetAdvancer

    init(
        store: BootstrappedAppDataStore,
        inventory: DataInventoryProductionService,
        coordinator: AppDataControlCoordinator,
        portablePackageCleanup:
            PortablePackageCleanupCoordinator? = nil,
        drainTimeout: Duration = .seconds(5),
        verificationMode:
            StoreFileProtectionVerificationMode = .live,
        targetAdvancer: @escaping TargetAdvancer = {
            journal, layout, verificationMode in
            try await PortableRestoreTargetBuilder.advance(
                journal,
                layout: layout,
                verificationMode: verificationMode
            )
        }
    ) {
        self.store = store
        self.inventory = inventory
        self.coordinator = coordinator
        self.portablePackageCleanup =
            portablePackageCleanup
            ?? store.layout.map {
                PortablePackageCleanupCoordinator(
                    layout: $0
                )
            }
        self.drainTimeout = drainTimeout
        self.verificationMode = verificationMode
        self.targetAdvancer = targetAdvancer
    }

    func makePlan(
        for auditedPackage: AuditedPortableBackup,
        mode: PortableImportMode
    ) async throws -> PortableImportPlan {
        guard let layout = store.layout,
              mode == .restore || mode == .replace else {
            throw PortableRestoreServiceError.invalidPlan
        }
        try Self.semanticPreflight(
            auditedPackage,
            layout: layout,
            deviceObservationDate: Date()
        )
        let (local, localStateDigest) =
            try await coordinator.withReadLease {
                let manifest = try await self.inventory
                    .manifest()
                let document = try await self.inventory
                    .readableJSONV2()
                guard manifest.generationID
                        == document.payload
                            .sourceGenerationID,
                      manifest.datasetID
                        == document.payload.datasetID,
                      manifest.completeness == .complete else {
                    throw PortableRestoreServiceError
                        .impactChanged
                }
                return (
                    document,
                    try PortableDataV2Codec
                        .logicalStateDigest(
                            document.payload
                        )
                )
            }
        let isRestoreEligible: Bool
        if mode == .restore {
            do {
                _ = try await DataResetFreshStoreVerifier(
                    modelContainer: store.container
                ).verify(
                    expectedDatasetID:
                        local.payload.datasetID
                )
                isRestoreEligible = true
            } catch {
                isRestoreEligible = false
            }
        } else {
            isRestoreEligible = false
        }
        return try PortableImportPlanner.makePlan(
            mode: mode,
            packageRootDigest:
                auditedPackage.packageSHA256,
            localStateDigest: localStateDigest,
            incoming:
                auditedPackage.readableDocument,
            local: local,
            localIsRestoreEligible:
                isRestoreEligible
        )
    }

    func prepare(
        auditedPackage: AuditedPortableBackup,
        plan: PortableImportPlan,
        now: Date = Date()
    ) async throws -> PortableRestorePreparedOperation {
        guard let layout = store.layout,
              plan.mode == .restore
                || plan.mode == .replace,
              plan.canConfirm,
              auditedPackage.packageSHA256
                == plan.packageRootDigest else {
            throw PortableRestoreServiceError.invalidPlan
        }
        let lease = try await beginExclusiveLease()
        var journalMayBeDurable = false
        var cleanupIntent:
            PortablePackageCleanupIntent?
        do {
            let operationID = UUID()
            let journal = try await coordinator
                .withExclusiveResetLease(lease) {
                    let currentManifest =
                        try await self.inventory.manifest()
                    let current = try await self.inventory
                        .readableJSONV2()
                    guard currentManifest.completeness
                            == .complete,
                          currentManifest.generationID
                            == current.payload
                                .sourceGenerationID,
                          currentManifest.datasetID
                            == current.payload.datasetID else {
                        throw PortableRestoreServiceError
                            .impactChanged
                    }
                    try PortableImportPlanner
                        .validateConfirmation(
                            plan,
                            packageRootDigest:
                                auditedPackage
                                .packageSHA256,
                            localStateDigest:
                                try PortableDataV2Codec
                                    .logicalStateDigest(
                                        current.payload
                                    )
                        )
                    guard try PortableDataV2Codec
                            .logicalStateDigest(
                                current.payload
                            ) == plan.localStateDigest,
                          current.payload.sourceGenerationID
                            == self.store.generationID,
                          current.payload.datasetID
                            == plan.localDatasetID else {
                        throw PortableRestoreServiceError
                            .impactChanged
                    }
                    if plan.mode == .restore {
                        _ = try await
                            DataResetFreshStoreVerifier(
                                modelContainer:
                                    self.store.container
                            ).verify(
                                expectedDatasetID:
                                    current.payload.datasetID
                            )
                    }
                    let currentPointer =
                        try GenerationPointerStore(
                            layout: layout
                        ).read()
                    guard currentPointer.generationID
                            == self.store.generationID,
                          currentPointer.datasetID
                            == current.payload.datasetID else {
                        throw PortableRestoreServiceError
                            .impactChanged
                    }
                    return try Self.makeJournal(
                        operationID: operationID,
                        plan: plan,
                        package: auditedPackage,
                        currentPointer: currentPointer,
                        now: now
                    )
                }
            guard let portablePackageCleanup else {
                throw PortableRestoreServiceError
                    .unavailable
            }
            let intent = try await portablePackageCleanup
                .register(
                    kind: .restoreStaging,
                    operationID: operationID
                )
            cleanupIntent = intent
            let staged = try Self.stageDurably(
                auditedPackage,
                journal: journal,
                layout: layout
            )
            guard staged.packageSHA256
                    == journal.packageRootDigest else {
                throw PortableRestoreServiceError
                    .packageChanged
            }
            try Self.semanticPreflight(
                staged,
                layout: layout,
                deviceObservationDate: now
            )
            let journalStore = PortableRestoreJournalStore(
                layout: layout
            )
            do {
                try journalStore.write(journal)
            } catch {
                if FileManager.default.fileExists(
                    atPath:
                        layout.portableRestoreJournalURL
                            .path
                ) {
                    journalMayBeDurable = true
                    await coordinator.invalidate()
                    throw PortableRestoreServiceError
                        .recoveryRequired
                } else {
                    throw error
                }
            }
            journalMayBeDurable = true
            // A durable restore journal is an irreversible process
            // boundary. The old in-memory generation must never accept
            // another read or write, even if target construction fails.
            await coordinator.invalidate()
            let advanced: PortableRestoreJournal
            do {
                advanced = try await targetAdvancer(
                    journal,
                    layout,
                    verificationMode
                )
            } catch {
                throw PortableRestoreServiceError
                    .recoveryRequired
            }
            guard advanced.phase == .restartRequired
            else {
                throw PortableRestoreServiceError
                    .recoveryRequired
            }
            return PortableRestorePreparedOperation(
                journal: advanced,
                coordinator: coordinator,
                lease: lease
            )
        } catch {
            let originalError = error
            if journalMayBeDurable
                || FileManager.default.fileExists(
                    atPath:
                        layout.portableRestoreJournalURL.path
                ) {
                await coordinator.invalidate()
            } else {
                if let cleanupIntent,
                   let portablePackageCleanup {
                    do {
                        try await portablePackageCleanup
                            .discard(cleanupIntent)
                    } catch {
                        await coordinator
                            .endExclusiveResetLease(
                                lease
                            )
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                }
                await coordinator.endExclusiveResetLease(
                    lease
                )
            }
            throw originalError
        }
    }

    private func beginExclusiveLease() async throws
        -> AppDataControlCoordinator.ExclusiveResetLease {
        let timeout = drainTimeout
        return try await withThrowingTaskGroup(
            of: AppDataControlCoordinator
                .ExclusiveResetLease.self
        ) { group in
            group.addTask {
                try await self.coordinator
                    .beginExclusiveResetLease()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PortableRestoreServiceError
                    .unavailable
            }
            guard let first = try await group.next() else {
                throw PortableRestoreServiceError.unavailable
            }
            group.cancelAll()
            return first
        }
    }

    static func semanticPreflight(
        _ package: AuditedPortableBackup,
        layout: AppDataStoreLayout,
        deviceObservationDate: Date
    ) throws {
        let audited = try PortableBackupPackageAuditor.audit(
            at: package.packageURL
        )
        guard audited.packageSHA256
                == package.packageSHA256,
              audited.manifest == package.manifest,
              audited.readableDocument
                == package.readableDocument else {
            throw PortableRestoreServiceError.packageChanged
        }

        let document = audited.readableDocument
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        let context = ModelContext(container)
        let insertion = try PortableV12RecordAdapter.insert(
            document,
            into: context,
            deviceObservationDate: deviceObservationDate
        )
        try context.save()
        let identity = try AppDataStoreBootstrapper(
            layout: layout
        ).validateV12DataInventoryFoundation(in: context)
        guard insertion.insertedRecordCount
                == document.payload.records.count,
              insertion.insertedRevisionCount
                == document.payload.records.count,
              insertion.insertedControlCount
                == document.payload.controls.count,
              identity.datasetID
                == document.payload.datasetID,
              identity.nextLocalRevision
                == document.payload.nextLocalRevision,
              identity.factCount
                == document.payload.records.count,
              identity.revisionCount
                == document.payload.records.count else {
            throw PortableRestoreServiceError.targetInvalid
        }

        let records = try context.fetch(
            FetchDescriptor<AttachmentRecord>()
        )
        let activeRecords = records.filter {
            $0.deletedAt == nil
                && $0.deleteOperationID == nil
        }
        guard activeRecords.count
                == document.payload.activeAttachments.count
        else {
            throw PortableRestoreServiceError.targetInvalid
        }
        let activeByID = Dictionary(
            uniqueKeysWithValues:
                document.payload.activeAttachments.map {
                    ($0.attachmentID, $0)
                }
        )
        for record in activeRecords {
            guard let attachment = activeByID[record.id],
                  record.ownerTypeRawValue
                    == attachment.ownerType,
                  record.ownerID == attachment.ownerID,
                  record.originalFilename
                    == attachment.originalFilename,
                  record.typeIdentifier
                    == attachment.typeIdentifier,
                  record.byteCount == attachment.byteCount,
                  record.sha256Hex == attachment.sha256Hex,
                  record.relativePath
                    == AttachmentPathFacts.relativePath(
                        attachmentID:
                            attachment.attachmentID,
                        typeIdentifier:
                            attachment.typeIdentifier
                    ) else {
                throw PortableRestoreServiceError.targetInvalid
            }
            let payloadURL = audited.packageURL.appending(
                path: attachment.packageRelativePath
            )
            let snapshot = try PortableBackupFileAudit.snapshot(
                payloadURL
            )
            guard snapshot.byteCount
                    == attachment.byteCount,
                  snapshot.sha256Hex
                    == attachment.sha256Hex else {
                throw PortableRestoreServiceError.packageChanged
            }
        }
    }

    static func makeJournal(
        operationID: UUID,
        plan: PortableImportPlan,
        package: AuditedPortableBackup,
        currentPointer: GenerationPointer,
        now: Date
    ) throws -> PortableRestoreJournal {
        let document = package.readableDocument
        let resetsLock = try sourceAppLockEnabled(document)
        let maximumCommittedAt =
            document.payload.records
                .map(\.committedAtMicroseconds)
                .max() ?? document.payload
                .capturedAtMicroseconds
        let nowMicroseconds =
            try RecordDigestV1.timestampMicroseconds(now)
        let policyCommittedAt = max(
            nowMicroseconds,
            maximumCommittedAt == Int64.max
                ? maximumCommittedAt
                : maximumCommittedAt + 1
        )
        guard policyCommittedAt != Int64.max else {
            throw PortableRestoreServiceError.invalidPlan
        }
        let additionalFactCount = resetsLock ? 1 : 0
        let finalFactCount =
            document.payload.records.count
            + additionalFactCount
        let (nextLocalRevision, overflow) =
            document.payload.nextLocalRevision
            .addingReportingOverflow(
                Int64(additionalFactCount)
            )
        guard !overflow,
              nextLocalRevision > 0 else {
            throw PortableRestoreServiceError.invalidPlan
        }
        return PortableRestoreJournal(
            operationID: operationID,
            mode: plan.mode,
            sourceGenerationID:
                currentPointer.generationID,
            sourceDatasetID: currentPointer.datasetID,
            targetGenerationID: UUID(),
            targetDatasetID:
                document.payload.datasetID,
            packageRootDigest: package.packageSHA256,
            confirmedLocalStateDigest:
                plan.localStateDigest,
            dryRunTokenSHA256: plan.tokenSHA256,
            factCount: finalFactCount,
            revisionCount: finalFactCount,
            targetNextLocalRevision:
                nextLocalRevision,
            attachmentCount:
                document.payload.activeAttachments.count,
            attachmentManifestDigest:
                try attachmentManifestDigest(
                    document.payload.activeAttachments
                ),
            devicePolicyOperationID: UUID(),
            devicePolicyCommittedAtMicroseconds:
                policyCommittedAt,
            updatedAt: now
        )
    }

    static func stageDurably(
        _ source: AuditedPortableBackup,
        journal: PortableRestoreJournal,
        layout: AppDataStoreLayout,
        beforeStagingCreate:
            PortableManagedPathSecurity
            .MutationProbe = {},
        beforeStagingWrite:
            PortableManagedPathSecurity
            .MutationProbe = {}
    ) throws -> AuditedPortableBackup {
        try PortableManagedPathSecurity
            .buildRestoreStagingPackage(
                source: source,
                journal: journal,
                layout: layout,
                beforeCreate:
                    beforeStagingCreate,
                beforeWrite:
                    beforeStagingWrite
            )
    }

    private static func sourceAppLockEnabled(
        _ document: PortableDataV2Document
    ) throws -> Bool {
        guard let record = document.payload.records.first(
            where: {
                $0.modelType == "PrivacyControlRecord"
            }
        ),
        let field = record.fields.first(
            where: { $0.name == "appLockEnabled" }
        ),
        case let .bool(value) =
            try field.value.recordDigestValue() else {
            throw PortableRestoreServiceError.invalidPlan
        }
        return value
    }

    private static func attachmentManifestDigest(
        _ attachments: [PortableDataAttachment]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            attachments.sorted {
                $0.attachmentID.uuidString
                    < $1.attachmentID.uuidString
            }
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

}

enum PortableRestoreTargetBuilder {
    static func advance(
        _ initial: PortableRestoreJournal,
        layout: AppDataStoreLayout,
        verificationMode:
            StoreFileProtectionVerificationMode = .live,
        stopAfterPhase:
            PortableRestorePhase? = nil
    ) async throws -> PortableRestoreJournal {
        var journal = initial
        let journalStore = PortableRestoreJournalStore(
            layout: layout
        )
        let package = try PortableBackupPackageAuditor
            .audit(at: journal.stagingURL(in: layout))
        guard package.packageSHA256
                == journal.packageRootDigest,
              package.readableDocument.payload.datasetID
                == journal.targetDatasetID,
              try attachmentManifestDigest(
                  package.readableDocument.payload
                      .activeAttachments
              ) == journal.attachmentManifestDigest else {
            throw PortableRestoreServiceError.packageChanged
        }
        try requireSourcePointer(
            journal,
            layout: layout
        )
        if journal.phase == stopAfterPhase {
            return journal
        }

        if journal.phase == .preparingTarget {
            try prepareFreshTarget(
                journal,
                layout: layout
            )
            journal = try advance(
                journal,
                to: .targetDirectoryPrepared,
                store: journalStore
            )
            if journal.phase == stopAfterPhase {
                return journal
            }
        }
        if journal.phase == .targetDirectoryPrepared {
            // A crash may have left a partial database. The target is
            // inactive and exactly journal-bound, so rebuild it from the
            // already audited durable package.
            try prepareFreshTarget(
                journal,
                layout: layout,
                replaceExisting: true
            )
            try await materializeDatabase(
                package.readableDocument,
                journal: journal,
                layout: layout
            )
            journal = try advance(
                journal,
                to: .databaseWritten,
                store: journalStore
            )
            if journal.phase == stopAfterPhase {
                return journal
            }
        }
        if journal.phase == .databaseWritten {
            try installAttachments(
                package,
                journal: journal,
                layout: layout
            )
            journal = try advance(
                journal,
                to: .attachmentsCopied,
                store: journalStore
            )
            if journal.phase == stopAfterPhase {
                return journal
            }
        }
        if journal.phase == .attachmentsCopied {
            journal = try advance(
                journal,
                to: .targetPrepared,
                store: journalStore
            )
            if journal.phase == stopAfterPhase {
                return journal
            }
        }
        if journal.phase == .targetPrepared {
            try await validateTarget(
                journal,
                package: package,
                layout: layout,
                verificationMode: verificationMode
            )
            journal = try advance(
                journal,
                to: .targetValidated,
                store: journalStore
            )
            if journal.phase == stopAfterPhase {
                return journal
            }
        }
        if journal.phase == .targetValidated {
            journal = try advance(
                journal,
                to: .restartRequired,
                store: journalStore
            )
        }
        return journal
    }

    static func validateTarget(
        _ journal: PortableRestoreJournal,
        package: AuditedPortableBackup,
        layout: AppDataStoreLayout,
        verificationMode:
            StoreFileProtectionVerificationMode = .live
    ) async throws {
        let provenance = try AppDataStoreBootstrapper(
            layout: layout,
            fileProtectionVerificationMode:
                verificationMode
        ).validateGenerationForDataInventory(
            generationID: journal.targetGenerationID,
            schemaVersion: "12.0.0",
            expectedDatasetID: journal.targetDatasetID
        )
        guard provenance.factCount == journal.factCount,
              provenance.revisionCount
                == journal.revisionCount else {
            throw PortableRestoreServiceError.targetInvalid
        }
        let active = provenance.attachments.filter {
            $0.deletedAt == nil
                && $0.deleteOperationID == nil
        }
        guard active.count == journal.attachmentCount,
              try attachmentManifestDigest(
                  active.map {
                      let value = $0.attachment
                      return PortableDataAttachment(
                          attachmentID: value.id,
                          ownerType:
                              value.ownerType.rawValue,
                          ownerID: value.ownerID,
                          originalFilename:
                              value.originalFilename,
                          typeIdentifier:
                              value.typeIdentifier,
                          byteCount: value.byteCount,
                          sha256Hex: value.sha256Hex
                      )
                  }
              ) == journal.attachmentManifestDigest else {
            throw PortableRestoreServiceError.targetInvalid
        }
        let attachmentStore = AttachmentFileStore(
            rootURL: layout.generationDirectoryURL(
                for: journal.targetGenerationID
            ).appending(
                path: "Files",
                directoryHint: .isDirectory
            )
        )
        _ = try attachmentStore
            .dataInventoryCategorySnapshots(
                observations: provenance.attachments
            )
        let readOnly = try AppModelContainerFactory
            .makeReadOnlyDataControlContainer(
                at: layout.storeURL(
                    for: journal.targetGenerationID
                )
            )
        let capture = try await
            DataInventoryDatabaseCaptureActor(
                modelContainer: readOnly
            ).capture(layout: layout)
        guard capture.datasetID
                == journal.targetDatasetID,
              capture.nextLocalRevision
                == journal.targetNextLocalRevision,
              capture.factCount == journal.factCount,
              capture.revisionCount
                == journal.revisionCount else {
            throw PortableRestoreServiceError.targetInvalid
        }
        let report = try StoreFileProtectionPlan(
            storeURL: layout.storeURL(
                for: journal.targetGenerationID
            ),
            resources: layout.protectionResources(
                for: journal.targetGenerationID
            ),
            backupPolicy: .systemManaged,
            verificationMode: verificationMode
        ).audit()
        guard report.isAcceptableForCurrentPlatform else {
            throw PortableRestoreServiceError.targetInvalid
        }
    }

    private static func materializeDatabase(
        _ document: PortableDataV2Document,
        journal: PortableRestoreJournal,
        layout: AppDataStoreLayout
    ) async throws {
        let container = try AppModelContainerFactory
            .makeDataControlContainer(
                at: layout.storeURL(
                    for: journal.targetGenerationID
                )
            )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        _ = try PortableV12RecordAdapter.insert(
            document,
            into: context,
            deviceObservationDate: Date(
                timeIntervalSince1970:
                    TimeInterval(
                        journal
                            .devicePolicyCommittedAtMicroseconds
                    ) / 1_000_000
            )
        )
        try context.save()
        if try sourceAppLockEnabled(document) {
            guard let privacy = document.payload.records
                    .first(where: {
                        $0.modelType
                            == "PrivacyControlRecord"
                    }) else {
                throw PortableRestoreServiceError
                    .targetInvalid
            }
            let writer = AppWriteActor(
                modelContainer: container
            )
            _ = try await writer.setAppLock(
                SetAppLockCommand(
                    operationID:
                        journal.devicePolicyOperationID,
                    expectedLocalRevision:
                        privacy.localRevision,
                    expectedDigestHex:
                        privacy.digestHex,
                    isEnabled: false,
                    committedAt: Date(
                        timeIntervalSince1970:
                            TimeInterval(
                                journal
                                    .devicePolicyCommittedAtMicroseconds
                            ) / 1_000_000
                    )
                )
            )
        }
    }

    private static func installAttachments(
        _ package: AuditedPortableBackup,
        journal: PortableRestoreJournal,
        layout: AppDataStoreLayout
    ) throws {
        let root = layout.generationDirectoryURL(
            for: journal.targetGenerationID
        ).appending(
            path: "Files",
            directoryHint: .isDirectory
        )
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let store = AttachmentFileStore(rootURL: root)
        _ = try store.recover(committedAttachments: [:])
        let attachmentRecords = Dictionary(
            uniqueKeysWithValues:
                package.readableDocument.payload.records
                .filter {
                    $0.modelType == "AttachmentRecord"
                }
                .map { ($0.recordID, $0) }
        )
        for attachment in package.readableDocument
            .payload.activeAttachments {
            guard let record =
                    attachmentRecords[
                        attachment.attachmentID
                    ],
                  let relativePathField =
                    record.fields.first(
                        where: {
                            $0.name == "relativePath"
                        }
                    ),
                  case let .string(relativePath) =
                    try relativePathField.value
                        .recordDigestValue(),
                  relativePath
                    == AttachmentPathFacts.relativePath(
                        attachmentID:
                            attachment.attachmentID,
                        typeIdentifier:
                            attachment.typeIdentifier
                    ) else {
                throw PortableRestoreServiceError
                    .targetInvalid
            }
            let payloadURL = package.packageURL
                .appending(
                    path: attachment.packageRelativePath
                )
            let data = try PortableBackupFileAudit
                .boundedData(
                    payloadURL,
                    maximumBytes: Int(
                        AttachmentFileStore
                            .maximumFileBytes
                    )
                )
            let operationID =
                CoreTimeRegimenBackfill.stableUUID(
                    for:
                        "portable-restore:"
                        + journal.operationID.uuidString
                        + ":"
                        + attachment.attachmentID
                            .uuidString
                )
            let staged = try store.stage(
                data: data,
                attachmentID: attachment.attachmentID,
                originalFilename:
                    attachment.originalFilename,
                typeIdentifier:
                    attachment.typeIdentifier,
                operationID: operationID
            )
            guard staged.byteCount == attachment.byteCount,
                  staged.sha256Hex
                    == attachment.sha256Hex,
                  staged.relativePath == relativePath else {
                throw PortableRestoreServiceError
                    .targetInvalid
            }
            _ = try store.commit(staged)
            try store.markMetadataCommitted(
                PreparedAttachmentMetadata(staged)
            )
        }
    }

    private static func prepareFreshTarget(
        _ journal: PortableRestoreJournal,
        layout: AppDataStoreLayout,
        replaceExisting: Bool = false
    ) throws {
        let pointer = try GenerationPointerStore(
            layout: layout
        ).read()
        guard pointer.generationID
                == journal.sourceGenerationID,
              pointer.datasetID
                == journal.sourceDatasetID,
              journal.targetGenerationID
                != pointer.generationID else {
            throw PortableRestoreServiceError.unsafeTarget
        }
        let target = layout.generationDirectoryURL(
            for: journal.targetGenerationID
        ).standardizedFileURL
        let generations = layout.generationsURL
            .standardizedFileURL
        guard target.path.hasPrefix(
            generations.path + "/"
        ),
        target.lastPathComponent
            == journal.targetGenerationID
                .uuidString.lowercased() else {
            throw PortableRestoreServiceError.unsafeTarget
        }
        if FileManager.default.fileExists(
            atPath: target.path
        ) {
            guard replaceExisting else {
                throw PortableRestoreServiceError
                    .unsafeTarget
            }
            try FileManager.default.removeItem(at: target)
        }
        for directory in [
            target,
            layout.storeDirectoryURL(
                for: journal.targetGenerationID
            )
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [
                    .protectionKey:
                        FileProtectionType.complete
                ]
            )
            var mutable = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try mutable.setResourceValues(values)
        }
    }

    private static func requireSourcePointer(
        _ journal: PortableRestoreJournal,
        layout: AppDataStoreLayout
    ) throws {
        let pointer = try GenerationPointerStore(
            layout: layout
        ).read()
        guard (
            pointer.generationID
                == journal.sourceGenerationID
                && pointer.datasetID
                    == journal.sourceDatasetID
        ) || (
            pointer.generationID
                == journal.targetGenerationID
                && pointer.datasetID
                    == journal.targetDatasetID
        ) else {
            throw PortableRestoreServiceError
                .recoveryRequired
        }
    }

    private static func advance(
        _ old: PortableRestoreJournal,
        to phase: PortableRestorePhase,
        store: PortableRestoreJournalStore
    ) throws -> PortableRestoreJournal {
        var next = old
        next.phase = phase
        next.updatedAt = Date(
            timeIntervalSince1970: floor(
                Date().timeIntervalSince1970
            )
        )
        try store.write(next, replacing: old)
        return next
    }

    private static func sourceAppLockEnabled(
        _ document: PortableDataV2Document
    ) throws -> Bool {
        guard let record = document.payload.records.first(
            where: {
                $0.modelType == "PrivacyControlRecord"
            }
        ),
        let field = record.fields.first(
            where: { $0.name == "appLockEnabled" }
        ),
        case let .bool(value) =
            try field.value.recordDigestValue() else {
            throw PortableRestoreServiceError.targetInvalid
        }
        return value
    }

    private static func attachmentManifestDigest(
        _ attachments: [PortableDataAttachment]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            attachments.sorted {
                $0.attachmentID.uuidString
                    < $1.attachmentID.uuidString
            }
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

actor PortableRestoreColdLaunchCoordinator {
    typealias StagingDiscarder = @Sendable (
        _ journal: PortableRestoreJournal,
        _ layout: AppDataStoreLayout
    ) throws -> Void

    private let layout: AppDataStoreLayout
    private let notificationClient:
        any DataResetNotificationClient
    private let verificationMode:
        StoreFileProtectionVerificationMode
    private let stagingDiscarder: StagingDiscarder?
    private let portablePackageCleanup:
        PortablePackageCleanupCoordinator

    init(
        layout: AppDataStoreLayout,
        notificationClient:
            any DataResetNotificationClient =
                SystemDataResetNotificationClient(),
        verificationMode:
            StoreFileProtectionVerificationMode = .live,
        stagingDiscarder: StagingDiscarder? = nil
    ) {
        self.layout = layout
        self.notificationClient = notificationClient
        self.verificationMode = verificationMode
        self.portablePackageCleanup =
            PortablePackageCleanupCoordinator(
                layout: layout
            )
        self.stagingDiscarder = stagingDiscarder
    }

    func open() async throws -> BootstrappedAppDataStore {
        let journalStore = PortableRestoreJournalStore(
            layout: layout
        )
        guard var journal = try journalStore
            .readIfPresent() else {
            return try AppDataStoreBootstrapper(
                layout: layout,
                fileProtectionVerificationMode:
                    verificationMode
            ).open()
        }
        try await validateSourceUnchangedIfActive(
            journal
        )
        if journal.phase != .restartRequired,
           journal.phase != .activationCleanupPending,
           journal.phase != .activated {
            journal = try await
                PortableRestoreTargetBuilder.advance(
                    journal,
                    layout: layout,
                    verificationMode: verificationMode
                )
        }
        if journal.phase == .restartRequired {
            let package = try PortableBackupPackageAuditor
                .audit(at: journal.stagingURL(in: layout))
            try await PortableRestoreTargetBuilder
                .validateTarget(
                    journal,
                    package: package,
                    layout: layout,
                    verificationMode: verificationMode
                )
            let pointerStore = GenerationPointerStore(
                layout: layout
            )
            let current = try pointerStore.read()
            if current.generationID
                    == journal.sourceGenerationID,
               current.datasetID
                    == journal.sourceDatasetID {
                let target = GenerationPointer(
                    generationID:
                        journal.targetGenerationID,
                    origin: .existingGeneration,
                    datasetID: journal.targetDatasetID,
                    minimumFactCount: journal.factCount,
                    minimumRevisionCount:
                        journal.revisionCount
                )
                try pointerStore.write(target)
                let readback = try pointerStore.read()
                guard readback.generationID
                            == target.generationID,
                      readback.datasetID
                            == target.datasetID,
                      readback.minimumFactCount
                            == target.minimumFactCount,
                      readback.minimumRevisionCount
                            == target.minimumRevisionCount else {
                    throw PortableRestoreServiceError
                        .recoveryRequired
                }
            } else if current.generationID
                        != journal.targetGenerationID
                    || current.datasetID
                        != journal.targetDatasetID {
                throw PortableRestoreServiceError
                    .recoveryRequired
            }
            try await convergeOwnedNotifications()
            journal = try advanceToCleanupPending(
                journal,
                store: journalStore
            )
        }
        if journal.phase
            == .activationCleanupPending {
            try await discardStaging(journal)
            journal = try advanceToActivated(
                journal,
                store: journalStore
            )
        } else if journal.phase == .activated {
            // Older interrupted builds may already have committed the
            // activated phase before staging cleanup. Retry the exact,
            // journal-bound cleanup on every launch until it succeeds.
            try await discardStaging(journal)
        }
        guard journal.phase == .activated else {
            throw PortableRestoreServiceError
                .recoveryRequired
        }
        return try AppDataStoreBootstrapper(
            layout: layout,
            fileProtectionVerificationMode:
                verificationMode
        ).open()
    }

    private func validateSourceUnchangedIfActive(
        _ journal: PortableRestoreJournal
    ) async throws {
        let pointer = try GenerationPointerStore(
            layout: layout
        ).read()
        guard pointer.generationID
                    == journal.sourceGenerationID,
              pointer.datasetID
                    == journal.sourceDatasetID else {
            guard pointer.generationID
                        == journal.targetGenerationID,
                  pointer.datasetID
                        == journal.targetDatasetID else {
                throw PortableRestoreServiceError
                    .recoveryRequired
            }
            return
        }
        let sourceStoreURL = layout.storeURL(
            for: journal.sourceGenerationID
        )
        let protectionPlan = StoreFileProtectionPlan(
            storeURL: sourceStoreURL,
            resources: layout.protectionResources(
                for: journal.sourceGenerationID
            ),
            backupPolicy: .systemManaged,
            verificationMode: verificationMode
        )
        let source = BootstrappedAppDataStore(
            container:
                try AppModelContainerFactory
                .makeReadOnlyDataControlContainer(
                    at: sourceStoreURL
                ),
            generationID:
                journal.sourceGenerationID,
            storeURL: sourceStoreURL,
            origin: .existingGeneration,
            protectionReport:
                try protectionPlan.audit(),
            protectionPlan: protectionPlan,
            attachmentRootURL:
                layout.generationDirectoryURL(
                    for: journal.sourceGenerationID
                ).appending(
                    path: "Files",
                    directoryHint: .isDirectory
                ),
            layout: layout
        )
        let database = try await
            DataInventoryDatabaseCaptureActor(
                modelContainer: source.container
            ).capture(layout: layout)
        let document = try DataInventoryProductionService
            .makePortableDocument(
                database: database,
                generationID:
                    journal.sourceGenerationID,
                capturedAt: Date(
                    timeIntervalSince1970: 0
                )
            )
        guard document.payload.datasetID
                    == journal.sourceDatasetID,
              try PortableDataV2Codec
                .logicalStateDigest(
                    document.payload
                ) == journal.confirmedLocalStateDigest else {
            throw PortableRestoreServiceError
                .impactChanged
        }
    }

    private func convergeOwnedNotifications()
        async throws {
        for _ in 0..<3 {
            let before = try await stableOwnedNotifications()
            if before.isEmpty { return }
            try await notificationClient
                .removePendingIdentifiers(
                    before.filter {
                        $0.deliveryState == .pending
                    }.map(\.identifier)
                )
            try await notificationClient
                .removeDeliveredIdentifiers(
                    before.filter {
                        $0.deliveryState == .delivered
                    }.map(\.identifier)
                )
            if try await stableOwnedNotifications().isEmpty {
                return
            }
        }
        throw PortableRestoreServiceError
            .notificationConvergenceFailed
    }

    private func stableOwnedNotifications()
        async throws -> [DataResetNotificationV1] {
        let firstPending = try await notificationClient
            .pendingIdentifiers()
        let firstDelivered = try await notificationClient
            .deliveredIdentifiers()
        let secondPending = try await notificationClient
            .pendingIdentifiers()
        let secondDelivered = try await notificationClient
            .deliveredIdentifiers()
        guard Set(firstPending) == Set(secondPending),
              Set(firstDelivered)
                == Set(secondDelivered) else {
            throw PortableRestoreServiceError
                .notificationObservationUnstable
        }
        do {
            return try DataResetPreparationService
                .ownedNotifications(
                    pending: secondPending,
                    delivered: secondDelivered
                )
        } catch {
            throw PortableRestoreServiceError
                .notificationObservationUnstable
        }
    }

    private func advanceToActivated(
        _ old: PortableRestoreJournal,
        store: PortableRestoreJournalStore
    ) throws -> PortableRestoreJournal {
        var next = old
        next.phase = .activated
        next.updatedAt = Date(
            timeIntervalSince1970: floor(
                Date().timeIntervalSince1970
            )
        )
        try store.write(next, replacing: old)
        return next
    }

    private func advanceToCleanupPending(
        _ old: PortableRestoreJournal,
        store: PortableRestoreJournalStore
    ) throws -> PortableRestoreJournal {
        var next = old
        next.phase = .activationCleanupPending
        next.updatedAt = Date(
            timeIntervalSince1970: floor(
                Date().timeIntervalSince1970
            )
        )
        try store.write(next, replacing: old)
        return next
    }

    private func discardStaging(
        _ journal: PortableRestoreJournal
    ) async throws {
        if let stagingDiscarder {
            try stagingDiscarder(journal, layout)
            try await portablePackageCleanup
                .releaseRestoreIntent(
                    operationID: journal.operationID
                )
        } else {
            try await portablePackageCleanup
                .discardRestoreStaging(
                    operationID: journal.operationID
                )
        }
    }
}
