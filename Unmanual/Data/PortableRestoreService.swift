import CryptoKit
import Foundation
import SwiftData

private enum PortableRecordImportDispatcher {
    static func insert(
        _ document: PortableDataV2Document,
        into context: ModelContext,
        deviceObservationDate: Date
    ) throws -> PortableV12InsertionResult {
        switch document.payload.schemaVersion {
        case PortableDataSchemaContract.v12.schemaVersion:
            try PortableV12RecordAdapter.insert(
                document,
                into: context,
                deviceObservationDate: deviceObservationDate
            )
        case PortableDataSchemaContract.v13.schemaVersion:
            try PortableV13RecordAdapter.insert(
                document,
                into: context,
                deviceObservationDate: deviceObservationDate
            )
        default:
            throw PortableDataV2Error.unsupportedVersion
        }
    }
}

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

private actor PortableCleanupIntentBinding {
    private var value: PortablePackageCleanupIntent

    init(_ value: PortablePackageCleanupIntent) {
        self.value = value
    }

    func update(_ value: PortablePackageCleanupIntent) {
        self.value = value
    }

    func current() -> PortablePackageCleanupIntent {
        value
    }
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
        var cleanupIntentBinding:
            PortableCleanupIntentBinding?
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
            let intentBinding =
                PortableCleanupIntentBinding(intent)
            cleanupIntentBinding = intentBinding
            let staged = try await Self.stageDurably(
                auditedPackage,
                journal: journal,
                layout: layout,
                bindArtifact: {
                    anchorIdentity,
                    rootIdentity,
                    packageIdentity in
                    let bound = try await portablePackageCleanup
                        .bind(
                            intent,
                            anchorIdentity:
                                anchorIdentity,
                            rootIdentity: rootIdentity,
                            packageIdentity:
                                packageIdentity
                        )
                    await intentBinding.update(bound)
                },
                recordSanitization: {
                    anchorIdentity,
                    rootIdentity,
                    packageIdentity in
                    let current = await intentBinding.current()
                    let sanitized = try await
                        portablePackageCleanup
                        .recordLeaseSanitization(
                            current,
                            anchorIdentity:
                                anchorIdentity,
                            rootIdentity: rootIdentity,
                            packageIdentity:
                                packageIdentity
                        )
                    await intentBinding.update(sanitized)
                }
            )
            cleanupIntent = await intentBinding.current()
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
                let currentCleanupIntent =
                    if let cleanupIntentBinding {
                        await cleanupIntentBinding.current()
                    } else {
                        cleanupIntent
                    }
                if let currentCleanupIntent,
                   let portablePackageCleanup {
                    do {
                        try await portablePackageCleanup
                            .discard(currentCleanupIntent)
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
            .makeInMemoryContentFavoriteContainer()
        let context = ModelContext(container)
        let insertion = try PortableRecordImportDispatcher.insert(
            document,
            into: context,
            deviceObservationDate: deviceObservationDate
        )
        try context.save()
        let identity = try AppDataStoreBootstrapper(
            layout: layout
        ).validateV13DataInventoryFoundation(in: context)
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
            .MutationProbe = {},
        afterStagingFirstSensitiveWrite:
            PortableManagedPathSecurity
            .MutationProbe = {},
        bindArtifact:
            PortableManagedPathSecurity
            .ArtifactBinding = { _, _, _ in },
        recordSanitization:
            PortableManagedPathSecurity
            .ArtifactSanitization = { _, _, _ in }
    ) async throws -> AuditedPortableBackup {
        try await PortableManagedPathSecurity
            .buildRestoreStagingPackage(
                source: source,
                journal: journal,
                layout: layout,
                beforeCreate:
                    beforeStagingCreate,
                beforeWrite:
                    beforeStagingWrite,
                afterFirstSensitiveWrite:
                    afterStagingFirstSensitiveWrite,
                bindArtifact:
                    bindArtifact,
                recordSanitization:
                    recordSanitization
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
            PortableRestorePhase? = nil,
        afterTargetContentsRemoved:
            PortableManagedPathSecurity.MutationProbe = {},
        beforeMaterializeDatabase:
            PortableManagedPathSecurity.MutationProbe = {},
        afterDatabaseNamespaceShield:
            PortableManagedPathSecurity.MutationProbe = {}
    ) async throws -> PortableRestoreJournal {
        var journal = initial
        var targetLease:
            PortableManagedPathSecurity
            .GenerationTargetLease?
        var targetContainer: ModelContainer?
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
            let prior = journal
            let identity = try prepareFreshTarget(
                journal,
                layout: layout
            )
            journal.bindTargetRoot(identity)
            try journalStore.write(
                journal,
                replacing: prior
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
            if let priorAncestry =
                    journal.targetAncestry {
                let priorLease = try
                    PortableManagedPathSecurity
                    .GenerationTargetLease.acquire(
                        layout: layout,
                        generationName:
                            journal.targetGenerationID
                            .uuidString.lowercased(),
                        expectedTarget:
                            journal.targetRootIdentity,
                        expectedAncestry:
                            priorAncestry
                    )
                try priorLease
                    .restoreNamespacePermissions()
                let prior = journal
                journal.clearTargetAncestry()
                try journalStore.write(
                    journal,
                    replacing: prior
                )
            }
            // A crash may have left a partial database. The target is
            // inactive and exactly journal-bound. Preserve that durable root
            // inode while clearing and rebuilding its contents so there is no
            // delete/create identity gap for cold-launch replay.
            _ = try PortableManagedPathSecurity
                .resetGenerationRootContents(
                    generationsURL:
                        layout.generationsURL,
                    generationName:
                        journal.targetGenerationID
                        .uuidString.lowercased(),
                    expectedIdentity:
                        journal.targetRootIdentity,
                    afterContentsRemoved:
                        afterTargetContentsRemoved
                )
            try beforeMaterializeDatabase()
            let lease = try PortableManagedPathSecurity
                .GenerationTargetLease.acquire(
                    layout: layout,
                    generationName:
                        journal.targetGenerationID
                        .uuidString.lowercased(),
                    expectedTarget:
                        journal.targetRootIdentity
                )
            let ancestryPrior = journal
            journal.bindTargetAncestry(
                lease.ancestry
            )
            try journalStore.write(
                journal,
                replacing: ancestryPrior
            )
            targetLease = lease
            try lease.verifyPublished()
            let container = try AppModelContainerFactory
                .makeContentFavoriteContainer(
                    at: layout.storeURL(
                        for: journal.targetGenerationID
                    )
                )
            try lease.verifyPublished()
            try hardenTargetProtection(
                journal,
                layout: layout,
                verificationMode: verificationMode
            )
            try lease.verifyPublished()
            try lease.beginNamespaceShield()
            try afterDatabaseNamespaceShield()
            try lease.verifyPublished()
            targetContainer = container
            try await materializeDatabase(
                package.readableDocument,
                journal: journal,
                container: container
            )
            try lease.verifyDatabaseBundle()
            try lease.verifyPublished()
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
            let lease: PortableManagedPathSecurity
                .GenerationTargetLease
            if let existing = targetLease {
                lease = existing
            } else {
                guard let ancestry =
                        journal.targetAncestry else {
                    throw PortableRestoreServiceError
                        .unsafeTarget
                }
                let acquired = try
                    PortableManagedPathSecurity
                    .GenerationTargetLease.acquire(
                        layout: layout,
                        generationName:
                            journal.targetGenerationID
                            .uuidString.lowercased(),
                        expectedTarget:
                            journal.targetRootIdentity,
                        expectedAncestry: ancestry
                    )
                try acquired.beginNamespaceShield()
                targetLease = acquired
                lease = acquired
            }
            try installAttachments(
                package,
                journal: journal,
                lease: lease
            )
            try lease.sealFilesNamespace()
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
            let lease = try targetLease
                ?? acquireTargetLease(
                    journal,
                    layout: layout
            )
            targetLease = lease
            try lease.beginNamespaceShield()
            try lease.sealFilesNamespace()
            try lease.verifyPublished()
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
            let lease = try targetLease
                ?? acquireTargetLease(
                    journal,
                    layout: layout
            )
            targetLease = lease
            try lease.beginNamespaceShield()
            try lease.sealFilesNamespace()
            let container: ModelContainer
            if let existing = targetContainer {
                container = existing
            } else {
                container = try AppModelContainerFactory
                    .makeContentFavoriteContainer(
                        at: layout.storeURL(
                            for:
                                journal
                                .targetGenerationID
                        )
                    )
                try lease.verifyDatabaseBundle()
                try lease.verifyPublished()
                targetContainer = container
            }
            try await validateTarget(
                journal,
                package: package,
                layout: layout,
                lease: lease,
                container: container,
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
            let lease = try targetLease
                ?? acquireTargetLease(
                    journal,
                    layout: layout
                )
            try lease.beginNamespaceShield()
            try lease.sealFilesNamespace()
            try lease.verifyPublished()
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
        lease:
            PortableManagedPathSecurity
            .GenerationTargetLease,
        container: ModelContainer,
        verificationMode:
            StoreFileProtectionVerificationMode = .live
    ) async throws {
        try lease.verifyPublished()
        try lease.verifyDatabaseBundle()
        guard package.packageSHA256
                == journal.packageRootDigest,
              package.readableDocument.payload.datasetID
                == journal.targetDatasetID,
              try attachmentManifestDigest(
                package.readableDocument.payload.activeAttachments
              ) == journal.attachmentManifestDigest else {
            throw PortableRestoreServiceError.packageChanged
        }
        let capture = try await
            DataInventoryDatabaseCaptureActor(
                modelContainer: container
            ).capture(layout: layout)
        guard capture.datasetID
                == journal.targetDatasetID,
              capture.factCount == journal.factCount,
              capture.revisionCount
                == journal.revisionCount else {
            throw PortableRestoreServiceError.targetInvalid
        }
        let active = capture.attachments.filter {
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
        try lease.validateAttachments(
            active.map {
                let value = $0.attachment
                return PortableDataAttachment(
                    attachmentID: value.id,
                    ownerType: value.ownerType.rawValue,
                    ownerID: value.ownerID,
                    originalFilename:
                        value.originalFilename,
                    typeIdentifier:
                        value.typeIdentifier,
                    byteCount: value.byteCount,
                    sha256Hex: value.sha256Hex
                )
            }
        )
        guard capture.nextLocalRevision
                == journal.targetNextLocalRevision,
              capture.factCount == journal.factCount,
              capture.revisionCount
                == journal.revisionCount else {
            throw PortableRestoreServiceError.targetInvalid
        }
        let actualDocument = try DataInventoryProductionService
            .makePortableDocument(
                database: capture,
                generationID:
                    package.readableDocument.payload
                    .sourceGenerationID,
                capturedAt: Date(
                    timeIntervalSince1970: 0
                )
            )
        let expectedDocument = try await
            expectedTargetDocument(
                package.readableDocument,
                journal: journal,
                layout: layout
            )
        guard try PortableDataV2Codec
                .logicalStateDigest(actualDocument.payload)
                == PortableDataV2Codec.logicalStateDigest(
                    expectedDocument.payload
                ) else {
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
        ).inspect()
        guard report.isAcceptableForCurrentPlatform else {
            throw PortableRestoreServiceError.targetInvalid
        }
        try lease.verifyDatabaseBundle()
        try lease.verifyPublished()
    }

    private static func hardenTargetProtection(
        _ journal: PortableRestoreJournal,
        layout: AppDataStoreLayout,
        verificationMode:
            StoreFileProtectionVerificationMode
    ) throws {
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

    private static func expectedTargetDocument(
        _ source: PortableDataV2Document,
        journal: PortableRestoreJournal,
        layout: AppDataStoreLayout
    ) async throws -> PortableDataV2Document {
        let container = try AppModelContainerFactory
            .makeInMemoryContentFavoriteContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let committedAt = Date(
            timeIntervalSince1970:
                TimeInterval(
                    journal.devicePolicyCommittedAtMicroseconds
                ) / 1_000_000
        )
        _ = try PortableRecordImportDispatcher.insert(
            source,
            into: context,
            deviceObservationDate: committedAt
        )
        try context.save()
        if try sourceAppLockEnabled(source) {
            guard let privacy = source.payload.records
                .first(where: {
                    $0.modelType == "PrivacyControlRecord"
                }) else {
                throw PortableRestoreServiceError.targetInvalid
            }
            _ = try await AppWriteActor(
                modelContainer: container
            ).setAppLock(
                SetAppLockCommand(
                    operationID:
                        journal.devicePolicyOperationID,
                    expectedLocalRevision:
                        privacy.localRevision,
                    expectedDigestHex: privacy.digestHex,
                    isEnabled: false,
                    committedAt: committedAt
                )
            )
        }
        let capture = try await
            DataInventoryDatabaseCaptureActor(
                modelContainer: container
            ).capture(layout: layout)
        return try DataInventoryProductionService
            .makePortableDocument(
                database: capture,
                generationID:
                    source.payload.sourceGenerationID,
                capturedAt: Date(
                    timeIntervalSince1970: 0
                )
            )
    }

    static func verifyTargetRootIdentity(
        _ journal: PortableRestoreJournal,
        layout: AppDataStoreLayout
    ) throws {
        do {
            try PortableManagedPathSecurity
                .verifyDirectoryIdentity(
                    at: layout.generationDirectoryURL(
                        for: journal.targetGenerationID
                    ),
                    expectedIdentity:
                        journal.targetRootIdentity
                )
        } catch {
            throw PortableRestoreServiceError.unsafeTarget
        }
    }

    private static func materializeDatabase(
        _ document: PortableDataV2Document,
        journal: PortableRestoreJournal,
        container: ModelContainer
    ) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        _ = try PortableRecordImportDispatcher.insert(
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
        lease:
            PortableManagedPathSecurity
            .GenerationTargetLease
    ) throws {
        try lease.installAttachments(
            from: package,
            operationID: journal.operationID
        )
    }

    private static func acquireTargetLease(
        _ journal: PortableRestoreJournal,
        layout: AppDataStoreLayout
    ) throws -> PortableManagedPathSecurity
        .GenerationTargetLease {
        guard let ancestry = journal.targetAncestry
        else {
            throw PortableRestoreServiceError.unsafeTarget
        }
        return try PortableManagedPathSecurity
            .GenerationTargetLease.acquire(
                layout: layout,
                generationName:
                    journal.targetGenerationID
                    .uuidString.lowercased(),
                expectedTarget:
                    journal.targetRootIdentity,
                expectedAncestry: ancestry
            )
    }

    private static func prepareFreshTarget(
        _ journal: PortableRestoreJournal,
        layout: AppDataStoreLayout
    ) throws -> PortableArtifactIdentity {
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
        if let bound = journal.targetRootIdentity {
            try PortableManagedPathSecurity
                .verifyDirectoryIdentity(
                    at: target,
                    expectedIdentity: bound
                )
        }
        let identity = try PortableManagedPathSecurity
            .createOrResumeEmptyGenerationRoot(
                generationsURL: generations,
                generationName:
                    journal.targetGenerationID
                    .uuidString.lowercased()
            )
        guard journal.targetRootIdentity == nil
                || journal.targetRootIdentity == identity else {
            throw PortableRestoreServiceError.unsafeTarget
        }
        return identity
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
        next.advanceState(
            to: phase,
            updatedAt: Date()
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
    typealias MutationProbe =
        PortableManagedPathSecurity.MutationProbe

    private let layout: AppDataStoreLayout
    private let notificationClient:
        any DataResetNotificationClient
    private let verificationMode:
        StoreFileProtectionVerificationMode
    private let stagingDiscarder: StagingDiscarder?
    private let beforePointerWrite: MutationProbe
    private let portablePackageCleanup:
        PortablePackageCleanupCoordinator

    init(
        layout: AppDataStoreLayout,
        notificationClient:
            any DataResetNotificationClient =
                SystemDataResetNotificationClient(),
        verificationMode:
            StoreFileProtectionVerificationMode = .live,
        stagingDiscarder: StagingDiscarder? = nil,
        beforePointerWrite:
            @escaping MutationProbe = {}
    ) {
        self.layout = layout
        self.notificationClient = notificationClient
        self.verificationMode = verificationMode
        self.portablePackageCleanup =
            PortablePackageCleanupCoordinator(
                layout: layout
            )
        self.stagingDiscarder = stagingDiscarder
        self.beforePointerWrite = beforePointerWrite
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
            guard package.packageSHA256
                    == journal.packageRootDigest else {
                throw PortableRestoreServiceError.packageChanged
            }
            let lease: PortableManagedPathSecurity
                .GenerationTargetLease
            do {
                lease = try PortableManagedPathSecurity
                    .GenerationTargetLease.acquire(
                        layout: layout,
                        generationName:
                            journal.targetGenerationID
                            .uuidString.lowercased(),
                        expectedTarget:
                            journal.targetRootIdentity,
                        expectedAncestry:
                            journal.targetAncestry
                    )
            } catch {
                throw PortableRestoreServiceError.unsafeTarget
            }
            try lease.beginNamespaceShield()
            try lease.sealFilesNamespace()
            let targetContainer = try
                AppModelContainerFactory
                .makeContentFavoriteContainer(
                    at: layout.storeURL(
                        for: journal.targetGenerationID
                    )
                )
            try await PortableRestoreTargetBuilder
                .validateTarget(
                    journal,
                    package: package,
                    layout: layout,
                    lease: lease,
                    container: targetContainer,
                    verificationMode: verificationMode
                )
            try lease.sealActivationContents()
            let pointerStore = GenerationPointerStore(
                layout: layout
            )
            try PortableRestoreTargetBuilder
                .verifyTargetRootIdentity(
                    journal,
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
                try PortableRestoreTargetBuilder
                    .verifyTargetRootIdentity(
                        journal,
                        layout: layout
                )
                try beforePointerWrite()
                try lease.verifyPublished()
                try lease.verifyDatabaseBundle()
                try lease.verifyActivationContents()
                do {
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
                    try lease.verifyActivationContents()
                } catch {
                    do {
                        try pointerStore.write(current)
                        guard try pointerStore.read()
                                == current else {
                            throw PortableRestoreServiceError
                                .recoveryRequired
                        }
                    } catch {
                        throw PortableRestoreServiceError
                            .recoveryRequired
                    }
                    throw error
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
            try lease.restoreNamespacePermissions()
        }
        if journal.phase
            == .activationCleanupPending {
            try restoreTargetNamespacePermissions(
                journal
            )
            try await discardStaging(journal)
            journal = try advanceToActivated(
                journal,
                store: journalStore
            )
        } else if journal.phase == .activated {
            try restoreTargetNamespacePermissions(
                journal
            )
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

    private func restoreTargetNamespacePermissions(
        _ journal: PortableRestoreJournal
    ) throws {
        let lease: PortableManagedPathSecurity
            .GenerationTargetLease
        do {
            lease = try PortableManagedPathSecurity
                .GenerationTargetLease.acquire(
                    layout: layout,
                    generationName:
                        journal.targetGenerationID
                        .uuidString.lowercased(),
                    expectedTarget:
                        journal.targetRootIdentity,
                    expectedAncestry:
                        journal.targetAncestry
                )
            try lease.beginNamespaceShield()
            try lease.sealFilesNamespace()
            try lease.verifyPublished()
            try lease.verifyDatabaseBundle()
            try lease.restoreNamespacePermissions()
        } catch {
            throw PortableRestoreServiceError.unsafeTarget
        }
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
        let sourceContainer: ModelContainer
        switch pointer.schemaVersion {
        case PortableDataSchemaContract.v12.schemaVersion:
            sourceContainer = try AppModelContainerFactory
                .makeReadOnlyDataControlContainer(
                    at: sourceStoreURL
                )
        case PortableDataSchemaContract.v13.schemaVersion:
            sourceContainer = try AppModelContainerFactory
                .makeReadOnlyContentFavoriteContainer(
                    at: sourceStoreURL
                )
        default:
            throw PortableRestoreServiceError.recoveryRequired
        }
        let source = BootstrappedAppDataStore(
            container: sourceContainer,
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
            ).capture(
                layout: layout,
                schemaVersion: pointer.schemaVersion
            )
        let document = try DataInventoryProductionService
            .makePortableDocument(
                database: database,
                generationID:
                    journal.sourceGenerationID,
                capturedAt: Date(
                    timeIntervalSince1970: 0
                ),
                schemaVersion: pointer.schemaVersion
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
        next.advanceState(
            to: .activated,
            updatedAt: Date()
        )
        try store.write(next, replacing: old)
        return next
    }

    private func advanceToCleanupPending(
        _ old: PortableRestoreJournal,
        store: PortableRestoreJournalStore
    ) throws -> PortableRestoreJournal {
        var next = old
        next.advanceState(
            to: .activationCleanupPending,
            updatedAt: Date()
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
