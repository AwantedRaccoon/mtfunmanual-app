import Foundation

enum StorePhysicalFileRole: String, Equatable, Sendable {
    case rootDirectory
    case generationsDirectory
    case pointerDirectory
    case recoveryDirectory
    case store
    case wal
    case shm
    case generationDirectory
    case storeDirectory
    case pointer
    case journal
    case auxiliary
}

struct StoreFileProtectionResource: Equatable, Sendable {
    let role: StorePhysicalFileRole
    let url: URL
}

struct StoreFileAuditEntry: Equatable, Sendable {
    let role: StorePhysicalFileRole
    let exists: Bool
    let usesCompleteProtection: Bool?
    let isExcludedFromBackup: Bool?
    let hardeningError: Bool
    let inspectionError: Bool

    init(
        role: StorePhysicalFileRole,
        exists: Bool,
        usesCompleteProtection: Bool?,
        isExcludedFromBackup: Bool?,
        hardeningError: Bool,
        inspectionError: Bool = false
    ) {
        self.role = role
        self.exists = exists
        self.usesCompleteProtection = usesCompleteProtection
        self.isExcludedFromBackup = isExcludedFromBackup
        self.hardeningError = hardeningError
        self.inspectionError = inspectionError
    }
}

struct StoreFileProtectionReport: Equatable, Sendable {
    let entries: [StoreFileAuditEntry]
    let requiresPhysicalDeviceValidation: Bool
    let backupPolicy: SystemBackupPolicy

    init(
        entries: [StoreFileAuditEntry],
        requiresPhysicalDeviceValidation: Bool,
        backupPolicy: SystemBackupPolicy = .systemManaged
    ) {
        self.entries = entries
        self.requiresPhysicalDeviceValidation = requiresPhysicalDeviceValidation
        self.backupPolicy = backupPolicy
    }

    var existingFilesUseCompleteProtection: Bool {
        entries
            .filter(\.exists)
            .allSatisfy { $0.usesCompleteProtection == true }
    }

    var isAcceptableForCurrentPlatform: Bool {
        let requiredRoles: Set<StorePhysicalFileRole> = [
            .rootDirectory,
            .generationsDirectory,
            .pointerDirectory,
            .recoveryDirectory,
            .store,
            .wal,
            .shm,
            .generationDirectory,
            .storeDirectory,
            .pointer,
            .journal
        ]
        let existingEntries = entries.filter(\.exists)
        let presentRequiredRoles = Set(
            existingEntries
                .filter { requiredRoles.contains($0.role) }
                .map(\.role)
        )
        guard presentRequiredRoles == requiredRoles,
              existingEntries.allSatisfy({ !$0.hardeningError }),
              existingEntries.allSatisfy({ !$0.inspectionError }),
              existingEntries.allSatisfy({ $0.usesCompleteProtection != false }),
              existingEntries.allSatisfy({
                  $0.isExcludedFromBackup == (backupPolicy == .excluded)
              }) else {
            return false
        }
#if targetEnvironment(simulator)
        return true
#else
        return existingEntries.allSatisfy { $0.usesCompleteProtection == true }
#endif
    }
}

struct StoreFileProtectionPlan: Equatable, Sendable {
    let storeURL: URL
    let resources: [StoreFileProtectionResource]
    let backupPolicy: SystemBackupPolicy
    let verificationMode: StoreFileProtectionVerificationMode

    init(
        storeURL: URL,
        resources: [StoreFileProtectionResource],
        backupPolicy: SystemBackupPolicy,
        verificationMode: StoreFileProtectionVerificationMode = .live
    ) {
        self.storeURL = storeURL
        self.resources = resources
        self.backupPolicy = backupPolicy
        self.verificationMode = verificationMode
    }

    func audit() throws -> StoreFileProtectionReport {
        try StoreFileProtectionAuditor(
            backupPolicy: backupPolicy,
            verificationMode: verificationMode
        )
            .hardenAndInspect(storeURL: storeURL, resources: resources)
    }
}

enum StoreFileProtectionVerificationMode: Equatable, Sendable {
    case live
#if targetEnvironment(simulator)
    /// Test-only harness for Simulator builds whose ad-hoc signature does not
    /// expose a usable data-protection entitlement. Backup metadata is still
    /// written and read back; physical file protection remains unverified.
    case simulatorTestHarness
#endif

    var skipsUnavailableSimulatorFileProtection: Bool {
#if targetEnvironment(simulator)
        self == .simulatorTestHarness
#else
        false
#endif
    }
}

struct StoreFileProtectionAuditor: Sendable {
    let backupPolicy: SystemBackupPolicy
    let verificationMode: StoreFileProtectionVerificationMode

    init(
        backupPolicy: SystemBackupPolicy,
        verificationMode: StoreFileProtectionVerificationMode = .live
    ) {
        self.backupPolicy = backupPolicy
        self.verificationMode = verificationMode
    }

    func hardenAndInspect(
        storeURL: URL,
        resources: [StoreFileProtectionResource] = []
    ) throws -> StoreFileProtectionReport {
        let physicalFiles: [(StorePhysicalFileRole, URL)] = [
            (.store, storeURL),
            (.wal, URL(fileURLWithPath: storeURL.path + "-wal")),
            (.shm, URL(fileURLWithPath: storeURL.path + "-shm"))
        ] + resources.map { ($0.role, $0.url) }

        let entries = physicalFiles.map { role, url in
            inspectAndHarden(role: role, url: url)
        }

#if targetEnvironment(simulator)
        let requiresPhysicalDeviceValidation = true
#else
        let requiresPhysicalDeviceValidation = false
#endif
        return StoreFileProtectionReport(
            entries: entries,
            requiresPhysicalDeviceValidation: requiresPhysicalDeviceValidation,
            backupPolicy: backupPolicy
        )
    }

    private func inspectAndHarden(
        role: StorePhysicalFileRole,
        url: URL
    ) -> StoreFileAuditEntry {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StoreFileAuditEntry(
                role: role,
                exists: false,
                usesCompleteProtection: nil,
                isExcludedFromBackup: nil,
                hardeningError: false
            )
        }

        var hardeningError = false
        if !verificationMode.skipsUnavailableSimulatorFileProtection {
            do {
                try (url as NSURL).setResourceValue(
                    URLFileProtection.complete,
                    forKey: .fileProtectionKey
                )
            } catch {
                hardeningError = true
            }
        }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = backupPolicy == .excluded
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            hardeningError = true
        }

        let values: URLResourceValues?
        var inspectionError = false
        do {
            values = try url.resourceValues(
                forKeys: [.fileProtectionKey, .isExcludedFromBackupKey]
            )
        } catch {
            values = nil
            inspectionError = true
        }
        return StoreFileAuditEntry(
            role: role,
            exists: true,
            usesCompleteProtection: verificationMode.skipsUnavailableSimulatorFileProtection
                ? nil
                : values?.fileProtection.map { $0 == .complete },
            isExcludedFromBackup: values?.isExcludedFromBackup,
            hardeningError: hardeningError,
            inspectionError: inspectionError
        )
    }
}
