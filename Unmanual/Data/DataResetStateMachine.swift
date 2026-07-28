import Foundation

enum DataResetPhaseV1: String, Codable, CaseIterable, Sendable {
    case quiesced
    case quarantinePrepared
    case managedRootQuarantined
    case legacyPartsQuarantined
    case restartRequired
    case quarantinePurged
    case freshStorePrepared
    case freshStoreOpened
    case ownedNotificationsConvergedToZero
    case verifiedEmpty
    case complete

    var ordinal: Int {
        Self.allCases.firstIndex(of: self)!
    }
}

enum DataResetOldManagedRootStateV1: String, Codable, Sendable {
    case sourceExpected
    case quarantined
    case purged
}

enum DataResetQuarantineStateV1: String, Codable, Sendable {
    case absent
    case created
    case purged
}

enum DataResetLegacyRoleV1: String, Codable, CaseIterable, Sendable {
    case main
    case wal
    case shm
}

enum DataResetLegacyStateV1: String, Codable, Sendable {
    case sourceExpected
    case absentConfirmed
    case quarantined
    case purged
}

enum DataResetNotificationNamespaceV1: String, Codable, Sendable {
    case execution
    case countdown

    fileprivate var identifierPrefix: String {
        switch self {
        case .execution:
            "unmanual.exec.v1."
        case .countdown:
            "unmanual.countdown.v1."
        }
    }
}

enum DataResetNotificationDeliveryStateV1: String, Codable, Sendable {
    case pending
    case delivered
}

struct DataResetLegacyPartV1: Codable, Equatable, Sendable {
    var roleRawValue: String
    var sourcePath: String
    var quarantinePath: String
    var wasPresent: Bool
    var stateRawValue: String

    var role: DataResetLegacyRoleV1? {
        DataResetLegacyRoleV1(rawValue: roleRawValue)
    }

    var state: DataResetLegacyStateV1? {
        DataResetLegacyStateV1(rawValue: stateRawValue)
    }
}

struct DataResetNotificationV1: Codable, Equatable, Hashable, Sendable {
    var namespaceRawValue: String
    var deliveryStateRawValue: String
    var identifier: String

    init(
        namespace: DataResetNotificationNamespaceV1,
        deliveryState: DataResetNotificationDeliveryStateV1,
        identifier: String
    ) {
        namespaceRawValue = namespace.rawValue
        deliveryStateRawValue = deliveryState.rawValue
        self.identifier = identifier
    }

    var namespace: DataResetNotificationNamespaceV1? {
        DataResetNotificationNamespaceV1(rawValue: namespaceRawValue)
    }

    var deliveryState: DataResetNotificationDeliveryStateV1? {
        DataResetNotificationDeliveryStateV1(rawValue: deliveryStateRawValue)
    }
}

struct DataResetJournalV1: Codable, Equatable, Sendable {
    var formatVersion: Int
    var operationID: UUID
    var phaseRawValue: String
    var confirmedStateDigest: String
    var exclusiveManifestDigest: String
    var createdAt: Date
    var updatedAt: Date
    var managedRootSourcePath: String
    var managedRootQuarantinePath: String
    var oldManagedRootStateRawValue: String
    var quarantineRootPath: String
    var quarantineStateRawValue: String
    var legacyParts: [DataResetLegacyPartV1]
    var ownedNotifications: [DataResetNotificationV1]
    var notificationClearEpoch: Int64
    var notificationClearRound: Int
    var freshGenerationID: UUID
    var freshDatasetID: UUID
    var freshNextLocalRevision: Int64?
    var journalDigest: String

    var phase: DataResetPhaseV1? {
        DataResetPhaseV1(rawValue: phaseRawValue)
    }

    var oldManagedRootState: DataResetOldManagedRootStateV1? {
        DataResetOldManagedRootStateV1(
            rawValue: oldManagedRootStateRawValue
        )
    }

    var quarantineState: DataResetQuarantineStateV1? {
        DataResetQuarantineStateV1(rawValue: quarantineStateRawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case operationID
        case phaseRawValue
        case confirmedStateDigest
        case exclusiveManifestDigest
        case createdAt
        case updatedAt
        case managedRootSourcePath
        case managedRootQuarantinePath
        case oldManagedRootStateRawValue
        case quarantineRootPath
        case quarantineStateRawValue
        case legacyParts
        case ownedNotifications
        case notificationClearEpoch
        case notificationClearRound
        case freshGenerationID
        case freshDatasetID
        case freshNextLocalRevision
        case journalDigest
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(phaseRawValue, forKey: .phaseRawValue)
        try container.encode(
            confirmedStateDigest,
            forKey: .confirmedStateDigest
        )
        try container.encode(
            exclusiveManifestDigest,
            forKey: .exclusiveManifestDigest
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(
            managedRootSourcePath,
            forKey: .managedRootSourcePath
        )
        try container.encode(
            managedRootQuarantinePath,
            forKey: .managedRootQuarantinePath
        )
        try container.encode(
            oldManagedRootStateRawValue,
            forKey: .oldManagedRootStateRawValue
        )
        try container.encode(
            quarantineRootPath,
            forKey: .quarantineRootPath
        )
        try container.encode(
            quarantineStateRawValue,
            forKey: .quarantineStateRawValue
        )
        try container.encode(legacyParts, forKey: .legacyParts)
        try container.encode(
            ownedNotifications,
            forKey: .ownedNotifications
        )
        try container.encode(
            notificationClearEpoch,
            forKey: .notificationClearEpoch
        )
        try container.encode(
            notificationClearRound,
            forKey: .notificationClearRound
        )
        try container.encode(
            freshGenerationID,
            forKey: .freshGenerationID
        )
        try container.encode(freshDatasetID, forKey: .freshDatasetID)
        if let freshNextLocalRevision {
            try container.encode(
                freshNextLocalRevision,
                forKey: .freshNextLocalRevision
            )
        } else {
            try container.encodeNil(forKey: .freshNextLocalRevision)
        }
        try container.encode(journalDigest, forKey: .journalDigest)
    }
}

struct DataResetPathLayout: Equatable, Sendable {
    let applicationSupportURL: URL
    let managedRootURL: URL
    let legacyStoreURL: URL
    let controlDirectoryURL: URL
    let journalURL: URL

    init(
        applicationSupportURL: URL,
        managedRootURL: URL,
        legacyStoreURL: URL
    ) {
        let support = Self.frozen(applicationSupportURL)
        self.applicationSupportURL = support
        self.managedRootURL = Self.frozen(managedRootURL)
        self.legacyStoreURL = Self.frozen(legacyStoreURL)
        controlDirectoryURL = support.appending(
            path: "UnmanualResetControl",
            directoryHint: .isDirectory
        )
        journalURL = controlDirectoryURL.appending(
            path: "reset-journal.json"
        )
    }

    init(
        applicationSupportURL: URL,
        storeLayout: AppDataStoreLayout
    ) {
        self.init(
            applicationSupportURL: applicationSupportURL,
            managedRootURL: storeLayout.rootURL,
            legacyStoreURL: storeLayout.legacyStoreURL
        )
    }

    func quarantineRootURL(operationID: UUID) -> URL {
        applicationSupportURL.appending(
            path: "Unmanual.reset-\(operationID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
    }

    func managedRootQuarantineURL(operationID: UUID) -> URL {
        quarantineRootURL(operationID: operationID).appending(
            path: "managed-root",
            directoryHint: .isDirectory
        )
    }

    func legacySourceURL(role: DataResetLegacyRoleV1) -> URL {
        switch role {
        case .main:
            legacyStoreURL
        case .wal:
            URL(fileURLWithPath: legacyStoreURL.path + "-wal")
        case .shm:
            URL(fileURLWithPath: legacyStoreURL.path + "-shm")
        }
    }

    func legacyQuarantineURL(
        operationID: UUID,
        role: DataResetLegacyRoleV1
    ) -> URL {
        quarantineRootURL(operationID: operationID)
            .appending(path: "legacy", directoryHint: .isDirectory)
            .appending(path: role.rawValue)
    }

    fileprivate static func frozen(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

enum DataResetStateMachineError: Error, Equatable {
    case invalidJournal(String)
    case invalidTransition(String)
    case pathMismatch(String)
    case unsafeFileSystemState(String)
    case journalReadFailed
    case journalWriteFailed
    case journalReadbackMismatch
    case restartRequired
    case coldLaunchRequired
}

enum DataResetItemKind: Equatable, Sendable {
    case missing
    case regularFile
    case directory
    case symbolicLink
    case other
}

protocol DataResetFileSystem: Sendable {
    func kind(at url: URL) throws -> DataResetItemKind
    func children(of url: URL) throws -> [URL]
    func createDirectory(at url: URL) throws
    func moveItem(at sourceURL: URL, to targetURL: URL) throws
    func removeItem(at url: URL) throws
    func readData(at url: URL) throws -> Data
    func writeProtectedAtomicData(_ data: Data, to url: URL) throws
    func verifyProtectedSystemManagedFile(at url: URL) throws
    func verifyProtectedSystemManagedDirectory(at url: URL) throws
}

struct DataResetFoundationFileSystem: DataResetFileSystem {
    private var fileManager: FileManager {
        .default
    }

    func kind(at url: URL) throws -> DataResetItemKind {
        if (try? fileManager.destinationOfSymbolicLink(
            atPath: url.path
        )) != nil {
            return .symbolicLink
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            return .missing
        }
        let values = try url.resourceValues(
            forKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .isDirectoryKey
            ]
        )
        if values.isSymbolicLink == true {
            return .symbolicLink
        }
        if values.isRegularFile == true {
            return .regularFile
        }
        if values.isDirectory == true || isDirectory.boolValue {
            return .directory
        }
        return .other
    }

    func children(of url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .isDirectoryKey
            ],
            options: []
        )
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = false
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
        try verifyProtectedSystemManagedDirectory(at: url)
    }

    func moveItem(at sourceURL: URL, to targetURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: targetURL)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func writeProtectedAtomicData(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if try kind(at: parent) == .missing {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: false,
                attributes: [
                    .protectionKey: FileProtectionType.complete
                ]
            )
            var parentValues = URLResourceValues()
            parentValues.isExcludedFromBackup = false
            var mutableParent = parent
            try mutableParent.setResourceValues(parentValues)
            try verifyProtectedSystemManagedDirectory(
                at: parent
            )
        }
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = false
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    func verifyProtectedSystemManagedFile(at url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isExcludedFromBackupKey,
                .fileProtectionKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isExcludedFromBackup != true else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(url.path)
        }
#if !targetEnvironment(simulator)
        guard values.fileProtection == .complete else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(url.path)
        }
#endif
    }

    func verifyProtectedSystemManagedDirectory(
        at url: URL
    ) throws {
        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isExcludedFromBackupKey,
                .fileProtectionKey
            ]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isExcludedFromBackup != true else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(url.path)
        }
#if !targetEnvironment(simulator)
        guard values.fileProtection == .complete else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(url.path)
        }
#endif
    }
}

enum DataResetJournalFactory {
    static func makeQuiesced(
        operationID: UUID,
        confirmedStateDigest: String,
        exclusiveManifestDigest: String,
        now: Date,
        layout: DataResetPathLayout,
        legacyPresence: [DataResetLegacyRoleV1: Bool],
        ownedNotifications: [DataResetNotificationV1],
        freshGenerationID: UUID,
        freshDatasetID: UUID
    ) throws -> DataResetJournalV1 {
        let timestamp = try DataResetJournalValidator.wholeSecond(now)
        let notifications = try normalizedNotifications(
            ownedNotifications
        )
        var journal = DataResetJournalV1(
            formatVersion: 1,
            operationID: operationID,
            phaseRawValue: DataResetPhaseV1.quiesced.rawValue,
            confirmedStateDigest: confirmedStateDigest,
            exclusiveManifestDigest: exclusiveManifestDigest,
            createdAt: timestamp,
            updatedAt: timestamp,
            managedRootSourcePath: layout.managedRootURL.path,
            managedRootQuarantinePath: layout
                .managedRootQuarantineURL(operationID: operationID)
                .path,
            oldManagedRootStateRawValue:
                DataResetOldManagedRootStateV1.sourceExpected.rawValue,
            quarantineRootPath: layout
                .quarantineRootURL(operationID: operationID)
                .path,
            quarantineStateRawValue:
                DataResetQuarantineStateV1.absent.rawValue,
            legacyParts: DataResetLegacyRoleV1.allCases.map { role in
                let wasPresent = legacyPresence[role] ?? false
                return DataResetLegacyPartV1(
                    roleRawValue: role.rawValue,
                    sourcePath: layout.legacySourceURL(role: role).path,
                    quarantinePath: layout.legacyQuarantineURL(
                        operationID: operationID,
                        role: role
                    ).path,
                    wasPresent: wasPresent,
                    stateRawValue: wasPresent
                        ? DataResetLegacyStateV1.sourceExpected.rawValue
                        : DataResetLegacyStateV1.absentConfirmed.rawValue
                )
            },
            ownedNotifications: notifications,
            notificationClearEpoch: 0,
            notificationClearRound: 0,
            freshGenerationID: freshGenerationID,
            freshDatasetID: freshDatasetID,
            freshNextLocalRevision: nil,
            journalDigest: ""
        )
        journal.journalDigest = try DataResetJournalDigest.digest(journal)
        try DataResetJournalValidator.validate(journal, layout: layout)
        return journal
    }

    static func normalizedNotifications(
        _ notifications: [DataResetNotificationV1]
    ) throws -> [DataResetNotificationV1] {
        let unique = Set(notifications)
        let sorted = unique.sorted(by: DataResetJournalValidator.notificationPrecedes)
        guard sorted.count == notifications.count else {
            throw DataResetStateMachineError
                .invalidJournal("duplicate owned notification")
        }
        return sorted
    }
}

enum DataResetJournalDigest {
    static func digest(_ journal: DataResetJournalV1) throws -> String {
        var fields: [RecordDigestV1.Field] = [
            .init("formatVersion", .integer(Int64(journal.formatVersion))),
            .init("operationID", .uuid(journal.operationID)),
            .init("phaseRawValue", .string(journal.phaseRawValue)),
            .init(
                "confirmedStateDigest",
                .string(journal.confirmedStateDigest)
            ),
            .init(
                "exclusiveManifestDigest",
                .string(journal.exclusiveManifestDigest)
            ),
            .init(
                "createdAt",
                try RecordDigestV1.timestampValue(journal.createdAt)
            ),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(journal.updatedAt)
            ),
            .init(
                "managedRootSourcePath",
                .string(journal.managedRootSourcePath)
            ),
            .init(
                "managedRootQuarantinePath",
                .string(journal.managedRootQuarantinePath)
            ),
            .init(
                "oldManagedRootStateRawValue",
                .string(journal.oldManagedRootStateRawValue)
            ),
            .init(
                "quarantineRootPath",
                .string(journal.quarantineRootPath)
            ),
            .init(
                "quarantineStateRawValue",
                .string(journal.quarantineStateRawValue)
            ),
            .init(
                "legacyPartCount",
                .integer(Int64(journal.legacyParts.count))
            )
        ]
        for (index, part) in journal.legacyParts.enumerated() {
            let prefix = "legacy.\(index)."
            fields.append(.init(
                prefix + "roleRawValue",
                .string(part.roleRawValue)
            ))
            fields.append(.init(
                prefix + "sourcePath",
                .string(part.sourcePath)
            ))
            fields.append(.init(
                prefix + "quarantinePath",
                .string(part.quarantinePath)
            ))
            fields.append(.init(
                prefix + "stateRawValue",
                .string(part.stateRawValue)
            ))
            fields.append(.init(
                prefix + "wasPresent",
                .bool(part.wasPresent)
            ))
        }
        fields.append(.init(
            "ownedNotificationCount",
            .integer(Int64(journal.ownedNotifications.count))
        ))
        for (index, notification) in
            journal.ownedNotifications.enumerated()
        {
            let prefix = "notification.\(index)."
            fields.append(.init(
                prefix + "namespaceRawValue",
                .string(notification.namespaceRawValue)
            ))
            fields.append(.init(
                prefix + "deliveryStateRawValue",
                .string(notification.deliveryStateRawValue)
            ))
            fields.append(.init(
                prefix + "identifier",
                .string(notification.identifier)
            ))
        }
        fields.append(.init(
            "notificationClearEpoch",
            .integer(journal.notificationClearEpoch)
        ))
        fields.append(.init(
            "notificationClearRound",
            .integer(Int64(journal.notificationClearRound))
        ))
        fields.append(.init(
            "freshGenerationID",
            .uuid(journal.freshGenerationID)
        ))
        fields.append(.init(
            "freshDatasetID",
            .uuid(journal.freshDatasetID)
        ))
        fields.append(.init(
            "freshNextLocalRevision",
            journal.freshNextLocalRevision.map(
                RecordDigestV1.Value.integer
            ) ?? .null
        ))
        return try RecordDigestV1.sha256Hex(
            recordType: "DataResetJournalV1",
            recordID: journal.operationID,
            fields: fields
        )
    }
}

enum DataResetJournalValidator {
    private static let digestCharacters = CharacterSet(
        charactersIn: "0123456789abcdef"
    )

    static func wholeSecond(_ date: Date) throws -> Date {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else {
            throw DataResetStateMachineError
                .invalidJournal("timestamp out of range")
        }
        return Date(timeIntervalSince1970: value.rounded(.down))
    }

    static func validate(
        _ journal: DataResetJournalV1,
        layout: DataResetPathLayout
    ) throws {
        guard journal.formatVersion == 1,
              let phase = journal.phase,
              journal.oldManagedRootState != nil,
              journal.quarantineState != nil else {
            throw DataResetStateMachineError
                .invalidJournal("unknown format or enum")
        }
        try requireDigest(
            journal.confirmedStateDigest,
            label: "confirmedStateDigest"
        )
        try requireDigest(
            journal.exclusiveManifestDigest,
            label: "exclusiveManifestDigest"
        )
        let created = try wholeSecond(journal.createdAt)
        let updated = try wholeSecond(journal.updatedAt)
        guard created == journal.createdAt,
              updated == journal.updatedAt,
              updated >= created else {
            throw DataResetStateMachineError
                .invalidJournal("timestamps must be ordered whole seconds")
        }

        try validatePaths(journal, layout: layout)
        try validateLegacyParts(journal, layout: layout)
        try validateNotifications(journal.ownedNotifications)
        try validateShape(journal, phase: phase)

        let expectedDigest = try DataResetJournalDigest.digest(journal)
        guard journal.journalDigest == expectedDigest else {
            throw DataResetStateMachineError
                .invalidJournal("journal digest mismatch")
        }
    }

    static func validateTransition(
        from old: DataResetJournalV1,
        to new: DataResetJournalV1,
        layout: DataResetPathLayout
    ) throws {
        try validate(old, layout: layout)
        try validate(new, layout: layout)
        guard let oldPhase = old.phase,
              let newPhase = new.phase else {
            throw DataResetStateMachineError
                .invalidTransition("unknown phase")
        }
        try requireFrozenIdentity(from: old, to: new)
        guard new.updatedAt >= old.updatedAt else {
            throw DataResetStateMachineError
                .invalidTransition("updatedAt moved backwards")
        }

        if newPhase == oldPhase {
            switch oldPhase {
            case .managedRootQuarantined:
                try validateSamePhaseLegacyProgress(from: old, to: new)
            case .freshStoreOpened:
                try validateSamePhaseNotificationProgress(
                    from: old,
                    to: new
                )
            default:
                throw DataResetStateMachineError
                    .invalidTransition("same-phase update not allowed")
            }
            return
        }

        guard newPhase.ordinal == oldPhase.ordinal + 1 else {
            throw DataResetStateMachineError
                .invalidTransition("phase must advance exactly one step")
        }
        guard old.notificationClearEpoch
                == new.notificationClearEpoch,
              old.notificationClearRound
                == new.notificationClearRound else {
            throw DataResetStateMachineError
                .invalidTransition(
                    "notification progress changed across phase"
                )
        }
        guard old.legacyParts == new.legacyParts
                || (
                    oldPhase == .restartRequired
                        && newPhase == .quarantinePurged
                ),
              old.ownedNotifications == new.ownedNotifications
                || (
                    oldPhase == .freshStoreOpened
                        && newPhase
                            == .ownedNotificationsConvergedToZero
                ) else {
            throw DataResetStateMachineError
                .invalidTransition("payload changed across phase boundary")
        }
        if oldPhase == .freshStorePrepared {
            guard old.freshNextLocalRevision == nil,
                  new.freshNextLocalRevision != nil else {
                throw DataResetStateMachineError
                    .invalidTransition("fresh allocator was not frozen")
            }
        } else {
            guard old.freshNextLocalRevision
                    == new.freshNextLocalRevision else {
                throw DataResetStateMachineError
                    .invalidTransition("fresh allocator changed")
            }
        }
        if oldPhase == .freshStoreOpened {
            guard new.ownedNotifications.isEmpty else {
                throw DataResetStateMachineError
                    .invalidTransition("owned notifications remain")
            }
        }
    }

    fileprivate static func notificationPrecedes(
        _ lhs: DataResetNotificationV1,
        _ rhs: DataResetNotificationV1
    ) -> Bool {
        let left = [
            lhs.namespaceRawValue,
            lhs.deliveryStateRawValue,
            lhs.identifier
        ]
        let right = [
            rhs.namespaceRawValue,
            rhs.deliveryStateRawValue,
            rhs.identifier
        ]
        for (leftValue, rightValue) in zip(left, right) {
            if leftValue == rightValue {
                continue
            }
            return leftValue.utf8.lexicographicallyPrecedes(
                rightValue.utf8
            )
        }
        return false
    }

    private static func validatePaths(
        _ journal: DataResetJournalV1,
        layout: DataResetPathLayout
    ) throws {
        let operationID = journal.operationID
        let exact: [(String, String)] = [
            (
                journal.managedRootSourcePath,
                layout.managedRootURL.path
            ),
            (
                journal.managedRootQuarantinePath,
                layout.managedRootQuarantineURL(
                    operationID: operationID
                ).path
            ),
            (
                journal.quarantineRootPath,
                layout.quarantineRootURL(operationID: operationID).path
            )
        ]
        for (actual, expected) in exact {
            guard actual == expected,
                  URL(fileURLWithPath: actual).standardizedFileURL.path
                    == actual else {
                throw DataResetStateMachineError.pathMismatch(actual)
            }
        }
        guard layout.managedRootURL.deletingLastPathComponent()
                == layout.applicationSupportURL,
              layout.controlDirectoryURL.deletingLastPathComponent()
                == layout.applicationSupportURL,
              layout.quarantineRootURL(operationID: operationID)
                .deletingLastPathComponent()
                == layout.applicationSupportURL,
              layout.managedRootQuarantineURL(operationID: operationID)
                .deletingLastPathComponent()
                == layout.quarantineRootURL(operationID: operationID)
        else {
            throw DataResetStateMachineError
                .pathMismatch("not an exact App Support child")
        }
        guard layout.legacyStoreURL.deletingLastPathComponent()
                == layout.applicationSupportURL else {
            throw DataResetStateMachineError
                .pathMismatch("legacy store is not an App Support child")
        }
    }

    private static func validateLegacyParts(
        _ journal: DataResetJournalV1,
        layout: DataResetPathLayout
    ) throws {
        guard journal.legacyParts.count == 3 else {
            throw DataResetStateMachineError
                .invalidJournal("legacy part count")
        }
        for (index, role) in
            DataResetLegacyRoleV1.allCases.enumerated()
        {
            let part = journal.legacyParts[index]
            guard part.role == role,
                  let state = part.state else {
                throw DataResetStateMachineError
                    .invalidJournal("legacy role order or state")
            }
            let expectedSource = layout.legacySourceURL(role: role)
            let expectedQuarantine = layout.legacyQuarantineURL(
                operationID: journal.operationID,
                role: role
            )
            let exactPaths = [
                (part.sourcePath, expectedSource.path),
                (part.quarantinePath, expectedQuarantine.path)
            ]
            for (actual, expected) in exactPaths {
                guard actual == expected,
                      URL(fileURLWithPath: actual)
                        .standardizedFileURL.path == actual else {
                    throw DataResetStateMachineError
                        .pathMismatch(actual)
                }
            }
            guard expectedSource.deletingLastPathComponent()
                    == layout.applicationSupportURL,
                  expectedQuarantine.deletingLastPathComponent()
                    == layout.quarantineRootURL(
                        operationID: journal.operationID
                    ).appending(
                        path: "legacy",
                        directoryHint: .isDirectory
                    ) else {
                throw DataResetStateMachineError
                    .pathMismatch("legacy path parent mismatch")
            }
            if part.wasPresent {
                guard state != .absentConfirmed else {
                    throw DataResetStateMachineError
                        .invalidJournal("present legacy marked absent")
                }
            } else {
                guard state == .absentConfirmed else {
                    throw DataResetStateMachineError
                        .invalidJournal("absent legacy state changed")
                }
            }
        }
    }

    private static func validateNotifications(
        _ notifications: [DataResetNotificationV1]
    ) throws {
        guard notifications.count
                <= DataInventoryTaxonomy.maximumRowsPerModel else {
            throw DataResetStateMachineError
                .invalidJournal("notification count")
        }
        for notification in notifications {
            guard let namespace = notification.namespace,
                  notification.deliveryState != nil,
                  !notification.identifier.isEmpty,
                  notification.identifier
                    .hasPrefix(namespace.identifierPrefix),
                  notification.identifier
                    == notification.identifier
                    .precomposedStringWithCanonicalMapping else {
                throw DataResetStateMachineError
                    .invalidJournal("invalid owned notification")
            }
        }
        for pair in zip(notifications, notifications.dropFirst()) {
            guard notificationPrecedes(pair.0, pair.1) else {
                throw DataResetStateMachineError
                    .invalidJournal("notification order or duplicate")
            }
        }
    }

    private static func validateShape(
        _ journal: DataResetJournalV1,
        phase: DataResetPhaseV1
    ) throws {
        let root = journal.oldManagedRootState!
        let quarantine = journal.quarantineState!
        switch phase {
        case .quiesced:
            guard root == .sourceExpected,
                  quarantine == .absent else {
                throw DataResetStateMachineError
                    .invalidJournal("quiesced shape")
            }
            try requireInitialLegacy(journal.legacyParts)
        case .quarantinePrepared:
            guard root == .sourceExpected,
                  quarantine == .created else {
                throw DataResetStateMachineError
                    .invalidJournal("prepared shape")
            }
            try requireInitialLegacy(journal.legacyParts)
        case .managedRootQuarantined:
            guard root == .quarantined,
                  quarantine == .created else {
                throw DataResetStateMachineError
                    .invalidJournal("managed quarantine shape")
            }
            try requireOrderedLegacyProgress(journal.legacyParts)
        case .legacyPartsQuarantined, .restartRequired:
            guard root == .quarantined,
                  quarantine == .created,
                  journal.legacyParts.allSatisfy({
                      !$0.wasPresent || $0.state == .quarantined
                  }) else {
                throw DataResetStateMachineError
                    .invalidJournal("legacy quarantine shape")
            }
        case .quarantinePurged, .freshStorePrepared,
                .freshStoreOpened,
                .ownedNotificationsConvergedToZero,
                .verifiedEmpty, .complete:
            guard root == .purged,
                  quarantine == .purged,
                  journal.legacyParts.allSatisfy({
                      !$0.wasPresent || $0.state == .purged
                  }) else {
                throw DataResetStateMachineError
                    .invalidJournal("purged shape")
            }
        }

        if phase.ordinal <= DataResetPhaseV1.freshStorePrepared.ordinal {
            guard journal.notificationClearEpoch == 0,
                  journal.notificationClearRound == 0 else {
                throw DataResetStateMachineError
                    .invalidJournal("early notification progress")
            }
        } else {
            guard journal.notificationClearEpoch >= 0,
                  (0...3).contains(journal.notificationClearRound)
            else {
                throw DataResetStateMachineError
                    .invalidJournal("notification progress range")
            }
        }
        if phase.ordinal < DataResetPhaseV1.freshStoreOpened.ordinal {
            guard journal.freshNextLocalRevision == nil else {
                throw DataResetStateMachineError
                    .invalidJournal("early fresh allocator")
            }
        } else {
            guard let revision = journal.freshNextLocalRevision,
                  revision > 0 else {
                throw DataResetStateMachineError
                    .invalidJournal("missing fresh allocator")
            }
        }
        if phase.ordinal
            >= DataResetPhaseV1
                .ownedNotificationsConvergedToZero.ordinal
        {
            guard journal.ownedNotifications.isEmpty else {
                throw DataResetStateMachineError
                    .invalidJournal("notifications not converged")
            }
        }
    }

    private static func requireInitialLegacy(
        _ parts: [DataResetLegacyPartV1]
    ) throws {
        guard parts.allSatisfy({
            $0.wasPresent
                ? $0.state == .sourceExpected
                : $0.state == .absentConfirmed
        }) else {
            throw DataResetStateMachineError
                .invalidJournal("legacy moved too early")
        }
    }

    private static func requireOrderedLegacyProgress(
        _ parts: [DataResetLegacyPartV1]
    ) throws {
        var sawUnmovedPresent = false
        for part in parts where part.wasPresent {
            if part.state == .sourceExpected {
                sawUnmovedPresent = true
            } else if part.state == .quarantined {
                guard !sawUnmovedPresent else {
                    throw DataResetStateMachineError
                        .invalidJournal("legacy move order")
                }
            } else {
                throw DataResetStateMachineError
                    .invalidJournal("legacy progress state")
            }
        }
    }

    private static func requireFrozenIdentity(
        from old: DataResetJournalV1,
        to new: DataResetJournalV1
    ) throws {
        guard old.formatVersion == new.formatVersion,
              old.operationID == new.operationID,
              old.confirmedStateDigest == new.confirmedStateDigest,
              old.exclusiveManifestDigest
                == new.exclusiveManifestDigest,
              old.createdAt == new.createdAt,
              old.managedRootSourcePath
                == new.managedRootSourcePath,
              old.managedRootQuarantinePath
                == new.managedRootQuarantinePath,
              old.quarantineRootPath == new.quarantineRootPath,
              old.freshGenerationID == new.freshGenerationID,
              old.freshDatasetID == new.freshDatasetID,
              zip(old.legacyParts, new.legacyParts).allSatisfy({
                  $0.roleRawValue == $1.roleRawValue
                      && $0.sourcePath == $1.sourcePath
                      && $0.quarantinePath == $1.quarantinePath
                      && $0.wasPresent == $1.wasPresent
              })
        else {
            throw DataResetStateMachineError
                .invalidTransition("frozen identity changed")
        }
    }

    private static func validateSamePhaseLegacyProgress(
        from old: DataResetJournalV1,
        to new: DataResetJournalV1
    ) throws {
        guard old.oldManagedRootStateRawValue
                == new.oldManagedRootStateRawValue,
              old.quarantineStateRawValue
                == new.quarantineStateRawValue,
              old.ownedNotifications == new.ownedNotifications,
              old.notificationClearEpoch == new.notificationClearEpoch,
              old.notificationClearRound == new.notificationClearRound,
              old.freshNextLocalRevision
                == new.freshNextLocalRevision else {
            throw DataResetStateMachineError
                .invalidTransition("unrelated legacy progress change")
        }
        let differences = zip(old.legacyParts, new.legacyParts)
            .enumerated()
            .filter { $0.element.0 != $0.element.1 }
        guard differences.count == 1 else {
            throw DataResetStateMachineError
                .invalidTransition("one legacy part per update")
        }
        let difference = differences[0]
        let index = difference.offset
        let oldPart = difference.element.0
        let newPart = difference.element.1
        guard oldPart.wasPresent,
              oldPart.state == .sourceExpected,
              newPart.state == .quarantined,
              old.legacyParts[..<index].allSatisfy({
                  !$0.wasPresent || $0.state == .quarantined
              }) else {
            throw DataResetStateMachineError
                .invalidTransition("legacy move was not next")
        }
    }

    private static func validateSamePhaseNotificationProgress(
        from old: DataResetJournalV1,
        to new: DataResetJournalV1
    ) throws {
        guard old.oldManagedRootStateRawValue
                == new.oldManagedRootStateRawValue,
              old.quarantineStateRawValue
                == new.quarantineStateRawValue,
              old.legacyParts == new.legacyParts,
              old.freshNextLocalRevision
                == new.freshNextLocalRevision else {
            throw DataResetStateMachineError
                .invalidTransition("unrelated notification progress change")
        }
        if new.notificationClearEpoch == old.notificationClearEpoch {
            guard new.notificationClearRound
                    == old.notificationClearRound + 1,
                  new.notificationClearRound <= 3 else {
                throw DataResetStateMachineError
                    .invalidTransition("notification round")
            }
        } else {
            guard old.notificationClearEpoch < Int64.max,
                  new.notificationClearEpoch
                    == old.notificationClearEpoch + 1,
                  new.notificationClearRound == 0 else {
                throw DataResetStateMachineError
                    .invalidTransition("notification retry epoch")
            }
        }
    }

    private static func requireDigest(
        _ value: String,
        label: String
    ) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  digestCharacters.contains($0)
              }) else {
            throw DataResetStateMachineError
                .invalidJournal("\(label) is not lowercase SHA-256")
        }
    }
}

struct DataResetJournalCodec: Sendable {
    private static let rootKeys: Set<String> = [
        "formatVersion",
        "operationID",
        "phaseRawValue",
        "confirmedStateDigest",
        "exclusiveManifestDigest",
        "createdAt",
        "updatedAt",
        "managedRootSourcePath",
        "managedRootQuarantinePath",
        "oldManagedRootStateRawValue",
        "quarantineRootPath",
        "quarantineStateRawValue",
        "legacyParts",
        "ownedNotifications",
        "notificationClearEpoch",
        "notificationClearRound",
        "freshGenerationID",
        "freshDatasetID",
        "freshNextLocalRevision",
        "journalDigest"
    ]
    private static let legacyKeys: Set<String> = [
        "roleRawValue",
        "sourcePath",
        "quarantinePath",
        "wasPresent",
        "stateRawValue"
    ]
    private static let notificationKeys: Set<String> = [
        "namespaceRawValue",
        "deliveryStateRawValue",
        "identifier"
    ]

    func encode(_ value: DataResetJournalV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func decode(
        _ data: Data,
        layout: DataResetPathLayout
    ) throws -> DataResetJournalV1 {
        guard data.count <= 64 * 1_024 * 1_024,
              let root = try JSONSerialization
                .jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Self.rootKeys,
              let legacy = root["legacyParts"] as? [[String: Any]],
              legacy.count == 3,
              legacy.allSatisfy({
                  Set($0.keys) == Self.legacyKeys
              }),
              let notifications =
                root["ownedNotifications"] as? [[String: Any]],
              notifications.allSatisfy({
                  Set($0.keys) == Self.notificationKeys
              }) else {
            throw DataResetStateMachineError
                .invalidJournal("JSON shape is not exact")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal: DataResetJournalV1
        do {
            journal = try decoder.decode(
                DataResetJournalV1.self,
                from: data
            )
        } catch {
            throw DataResetStateMachineError
                .invalidJournal("typed JSON decode failed")
        }
        try DataResetJournalValidator.validate(journal, layout: layout)
        return journal
    }
}

struct DataResetJournalStore: Sendable {
    let layout: DataResetPathLayout
    let fileSystem: any DataResetFileSystem
    private let codec = DataResetJournalCodec()

    func read() throws -> DataResetJournalV1 {
        try validateControlPaths(requiresJournal: true)
        try fileSystem.verifyProtectedSystemManagedFile(
            at: layout.journalURL
        )
        let data: Data
        do {
            data = try fileSystem.readData(at: layout.journalURL)
        } catch {
            throw DataResetStateMachineError.journalReadFailed
        }
        return try codec.decode(data, layout: layout)
    }

    @discardableResult
    func writeAndReadback(
        _ journal: DataResetJournalV1
    ) throws -> DataResetJournalV1 {
        try DataResetJournalValidator.validate(journal, layout: layout)
        try validateControlPaths(requiresJournal: false)
        let encoded: Data
        do {
            encoded = try codec.encode(journal)
            try fileSystem.writeProtectedAtomicData(
                encoded,
                to: layout.journalURL
            )
            try fileSystem.verifyProtectedSystemManagedFile(
                at: layout.journalURL
            )
        } catch let error as DataResetStateMachineError {
            throw error
        } catch {
            throw DataResetStateMachineError.journalWriteFailed
        }
        let readback = try read()
        guard readback == journal else {
            throw DataResetStateMachineError.journalReadbackMismatch
        }
        return readback
    }

    private func validateControlPaths(
        requiresJournal: Bool
    ) throws {
        guard try fileSystem.kind(at: layout.applicationSupportURL)
                == .directory else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(
                    layout.applicationSupportURL.path
                )
        }
        let controlKind = try fileSystem.kind(
            at: layout.controlDirectoryURL
        )
        guard controlKind == .missing || controlKind == .directory
        else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(
                    layout.controlDirectoryURL.path
                )
        }
        let journalKind = try fileSystem.kind(at: layout.journalURL)
        if controlKind == .directory {
            try fileSystem
                .verifyProtectedSystemManagedDirectory(
                    at: layout.controlDirectoryURL
                )
            let children = try fileSystem.children(
                of: layout.controlDirectoryURL
            )
            let allowedNames: Set<String> =
                requiresJournal
                    ? ["reset-journal.json"]
                    : ["reset-journal.json"]
            guard children.count
                    == Set(children.map(\.lastPathComponent))
                        .count,
                  Set(children.map(\.lastPathComponent))
                    .isSubset(of: allowedNames),
                  !requiresJournal || children.count == 1
            else {
                throw DataResetStateMachineError
                    .unsafeFileSystemState(
                        layout.controlDirectoryURL.path
                    )
            }
        }
        if requiresJournal {
            guard controlKind == .directory,
                  journalKind == .regularFile else {
                throw DataResetStateMachineError.journalReadFailed
            }
        } else {
            guard journalKind == .missing
                    || journalKind == .regularFile else {
                throw DataResetStateMachineError
                    .unsafeFileSystemState(layout.journalURL.path)
            }
        }
    }
}

enum DataResetStateMachine {
    static func transitioned(
        from old: DataResetJournalV1,
        to phase: DataResetPhaseV1,
        now: Date,
        layout: DataResetPathLayout,
        mutate: (inout DataResetJournalV1) throws -> Void = { _ in }
    ) throws -> DataResetJournalV1 {
        var next = old
        next.phaseRawValue = phase.rawValue
        next.updatedAt = try DataResetJournalValidator.wholeSecond(now)
        try mutate(&next)
        next.journalDigest = try DataResetJournalDigest.digest(next)
        try DataResetJournalValidator.validateTransition(
            from: old,
            to: next,
            layout: layout
        )
        return next
    }
}

struct DataResetQuarantineExecutor: Sendable {
    let store: DataResetJournalStore
    let now: @Sendable () -> Date

    init(
        store: DataResetJournalStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    func advanceBeforeRestart(
        from initial: DataResetJournalV1
    ) throws -> DataResetJournalV1 {
        guard try store.read() == initial else {
            throw DataResetStateMachineError.journalReadbackMismatch
        }
        var journal = initial
        while true {
            try DataResetJournalValidator.validate(
                journal,
                layout: store.layout
            )
            guard let phase = journal.phase else {
                throw DataResetStateMachineError
                    .invalidJournal("unknown phase")
            }
            switch phase {
            case .quiesced:
                try prepareQuarantine(for: journal)
                journal = try persistTransition(
                    journal,
                    to: .quarantinePrepared
                ) {
                    $0.quarantineStateRawValue =
                        DataResetQuarantineStateV1.created.rawValue
                }
            case .quarantinePrepared:
                try reconcileMove(
                    journal: journal,
                    source: URL(
                        fileURLWithPath:
                            journal.managedRootSourcePath
                    ),
                    target: URL(
                        fileURLWithPath:
                            journal.managedRootQuarantinePath
                    ),
                    expectedKind: .directory
                )
                journal = try persistTransition(
                    journal,
                    to: .managedRootQuarantined
                ) {
                    $0.oldManagedRootStateRawValue =
                        DataResetOldManagedRootStateV1
                        .quarantined.rawValue
                }
            case .managedRootQuarantined:
                if let index = journal.legacyParts.firstIndex(where: {
                    $0.wasPresent && $0.state == .sourceExpected
                }) {
                    let part = journal.legacyParts[index]
                    try reconcileMove(
                        journal: journal,
                        source: URL(fileURLWithPath: part.sourcePath),
                        target: URL(
                            fileURLWithPath: part.quarantinePath
                        ),
                        expectedKind: .regularFile
                    )
                    journal = try persistTransition(
                        journal,
                        to: .managedRootQuarantined
                    ) {
                        $0.legacyParts[index].stateRawValue =
                            DataResetLegacyStateV1
                            .quarantined.rawValue
                    }
                } else {
                    try verifyAbsentLegacyParts(journal)
                    journal = try persistTransition(
                        journal,
                        to: .legacyPartsQuarantined
                    )
                }
            case .legacyPartsQuarantined:
                journal = try persistTransition(
                    journal,
                    to: .restartRequired
                )
            case .restartRequired:
                return journal
            default:
                throw DataResetStateMachineError
                    .invalidTransition(
                        "before-restart executor received \(phase.rawValue)"
                    )
            }
        }
    }

    func resumeColdLaunchThroughPurge(
        from initial: DataResetJournalV1
    ) throws -> DataResetJournalV1 {
        guard try store.read() == initial else {
            throw DataResetStateMachineError.journalReadbackMismatch
        }
        var journal = initial
        if journal.phase?.ordinal
            ?? Int.max < DataResetPhaseV1.restartRequired.ordinal
        {
            journal = try advanceBeforeRestart(from: journal)
        }
        guard journal.phase == .restartRequired else {
            if journal.phase == .quarantinePurged {
                return journal
            }
            throw DataResetStateMachineError
                .invalidTransition("cold-launch purge phase")
        }
        try convergeMovesBeforePurge(&journal)
        try purgeQuarantine(journal)
        journal = try persistTransition(
            journal,
            to: .quarantinePurged
        ) {
            $0.oldManagedRootStateRawValue =
                DataResetOldManagedRootStateV1.purged.rawValue
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.purged.rawValue
            for index in $0.legacyParts.indices
                where $0.legacyParts[index].wasPresent
            {
                $0.legacyParts[index].stateRawValue =
                    DataResetLegacyStateV1.purged.rawValue
            }
        }
        return journal
    }

    private func persistTransition(
        _ journal: DataResetJournalV1,
        to phase: DataResetPhaseV1,
        mutate: (inout DataResetJournalV1) throws -> Void = { _ in }
    ) throws -> DataResetJournalV1 {
        let next = try DataResetStateMachine.transitioned(
            from: journal,
            to: phase,
            now: now(),
            layout: store.layout,
            mutate: mutate
        )
        return try store.writeAndReadback(next)
    }

    private func prepareQuarantine(
        for journal: DataResetJournalV1
    ) throws {
        try requireApplicationSupportDirectory()
        let root = URL(fileURLWithPath: journal.quarantineRootPath)
        let legacy = root.appending(
            path: "legacy",
            directoryHint: .isDirectory
        )
        switch try store.fileSystem.kind(at: root) {
        case .missing:
            try store.fileSystem.createDirectory(at: root)
            try store.fileSystem.createDirectory(at: legacy)
        case .directory:
            let children = try store.fileSystem.children(of: root)
            let names = Set(children.map(\.lastPathComponent))
            guard names.isEmpty || names == ["legacy"],
                  names.count == children.count else {
                throw DataResetStateMachineError
                    .unsafeFileSystemState(root.path)
            }
            if names.isEmpty {
                try store.fileSystem.createDirectory(at: legacy)
            }
            break
        default:
            throw DataResetStateMachineError
                .unsafeFileSystemState(root.path)
        }
        try requireExactChildren(root, names: ["legacy"])
        try requireExactChildren(legacy, names: [])
        try requireQuarantineParentChain(journal)
        guard try store.fileSystem.kind(
            at: URL(
                fileURLWithPath:
                    journal.managedRootQuarantinePath
            )
        ) == .missing else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(
                    journal.managedRootQuarantinePath
                )
        }
        try verifyAbsentLegacyParts(journal)
    }

    private func verifyAbsentLegacyParts(
        _ journal: DataResetJournalV1
    ) throws {
        try requireQuarantineParentChain(journal)
        for part in journal.legacyParts where !part.wasPresent {
            guard try store.fileSystem.kind(
                at: URL(fileURLWithPath: part.sourcePath)
            ) == .missing,
            try store.fileSystem.kind(
                at: URL(fileURLWithPath: part.quarantinePath)
            ) == .missing else {
                throw DataResetStateMachineError
                    .unsafeFileSystemState(part.sourcePath)
            }
        }
    }

    private func reconcileMove(
        journal: DataResetJournalV1,
        source: URL,
        target: URL,
        expectedKind: DataResetItemKind
    ) throws {
        try requireQuarantineParentChain(journal)
        let sourceKind = try store.fileSystem.kind(at: source)
        let targetKind = try store.fileSystem.kind(at: target)
        switch (sourceKind, targetKind) {
        case (expectedKind, .missing):
            try store.fileSystem.moveItem(at: source, to: target)
        case (.missing, expectedKind):
            break
        default:
            throw DataResetStateMachineError
                .unsafeFileSystemState(
                    "\(source.path) -> \(target.path)"
                )
        }
        try requireQuarantineParentChain(journal)
        guard try store.fileSystem.kind(at: source) == .missing,
              try store.fileSystem.kind(at: target) == expectedKind
        else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(target.path)
        }
        if expectedKind == .directory {
            try requireTreeWithoutSymbolicLinks(target)
        }
    }

    private func convergeMovesBeforePurge(
        _ journal: inout DataResetJournalV1
    ) throws {
        try requireApplicationSupportDirectory()
        let rootSource = URL(
            fileURLWithPath: journal.managedRootSourcePath
        )
        let rootTarget = URL(
            fileURLWithPath: journal.managedRootQuarantinePath
        )
        let quarantineRoot = URL(
            fileURLWithPath: journal.quarantineRootPath
        )
        if try store.fileSystem.kind(at: quarantineRoot) == .missing {
            guard try store.fileSystem.kind(at: rootSource) == .missing,
                  try store.fileSystem.kind(at: rootTarget) == .missing,
                  try journal.legacyParts.allSatisfy({ part in
                      try store.fileSystem.kind(
                          at: URL(fileURLWithPath: part.sourcePath)
                      ) == .missing
                          && store.fileSystem.kind(
                              at: URL(
                                  fileURLWithPath:
                                      part.quarantinePath
                              )
                          ) == .missing
                  }) else {
                throw DataResetStateMachineError
                    .unsafeFileSystemState("purge-after-action mismatch")
            }
            return
        }
        try requireQuarantineParentChain(journal)
        try reconcileQuarantinedItem(
            source: rootSource,
            target: rootTarget,
            expectedKind: .directory
        )
        for part in journal.legacyParts {
            let source = URL(fileURLWithPath: part.sourcePath)
            let target = URL(fileURLWithPath: part.quarantinePath)
            if part.wasPresent {
                try reconcileQuarantinedItem(
                    source: source,
                    target: target,
                    expectedKind: .regularFile
                )
            } else {
                guard try store.fileSystem.kind(at: source) == .missing,
                      try store.fileSystem.kind(at: target) == .missing
                else {
                    throw DataResetStateMachineError
                        .unsafeFileSystemState(part.sourcePath)
                }
            }
        }
        try requireExactQuarantineTree(journal)
    }

    private func reconcileQuarantinedItem(
        source: URL,
        target: URL,
        expectedKind: DataResetItemKind
    ) throws {
        let sourceKind = try store.fileSystem.kind(at: source)
        let targetKind = try store.fileSystem.kind(at: target)
        guard sourceKind == .missing,
              targetKind == expectedKind else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(
                    "\(source.path) -> \(target.path)"
                )
        }
        if expectedKind == .directory {
            try requireTreeWithoutSymbolicLinks(target)
        }
    }

    private func purgeQuarantine(
        _ journal: DataResetJournalV1
    ) throws {
        try requireApplicationSupportDirectory()
        let quarantineRoot = URL(
            fileURLWithPath: journal.quarantineRootPath
        )
        if try store.fileSystem.kind(at: quarantineRoot) != .missing {
            try requireQuarantineParentChain(journal)
            try requireExactQuarantineTree(journal)
            try store.fileSystem.removeItem(at: quarantineRoot)
        }
        try requireApplicationSupportDirectory()
        guard try store.fileSystem.kind(at: quarantineRoot) == .missing,
              try store.fileSystem.kind(
                  at: URL(
                      fileURLWithPath:
                          journal.managedRootSourcePath
                  )
              ) == .missing,
              try journal.legacyParts.allSatisfy({
                  try store.fileSystem.kind(
                      at: URL(fileURLWithPath: $0.sourcePath)
                  ) == .missing
              }) else {
            throw DataResetStateMachineError
                .unsafeFileSystemState("purge readback")
        }
    }

    private func requireExactQuarantineTree(
        _ journal: DataResetJournalV1
    ) throws {
        let root = URL(fileURLWithPath: journal.quarantineRootPath)
        let legacy = root.appending(
            path: "legacy",
            directoryHint: .isDirectory
        )
        try requireExactChildren(
            root,
            names: ["legacy", "managed-root"]
        )
        let expectedLegacy = Set(
            journal.legacyParts
                .filter(\.wasPresent)
                .map(\.roleRawValue)
        )
        try requireExactChildren(legacy, names: expectedLegacy)
        try requireTreeWithoutSymbolicLinks(root)
    }

    private func requireApplicationSupportDirectory() throws {
        let support = store.layout.applicationSupportURL
        guard try store.fileSystem.kind(at: support) == .directory
        else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(support.path)
        }
    }

    private func requireQuarantineParentChain(
        _ journal: DataResetJournalV1
    ) throws {
        try requireApplicationSupportDirectory()
        let root = URL(fileURLWithPath: journal.quarantineRootPath)
        let legacy = root.appending(
            path: "legacy",
            directoryHint: .isDirectory
        )
        guard root.deletingLastPathComponent()
                == store.layout.applicationSupportURL,
              legacy.deletingLastPathComponent() == root,
              try store.fileSystem.kind(at: root) == .directory,
              try store.fileSystem.kind(at: legacy) == .directory
        else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(root.path)
        }
        try store.fileSystem
            .verifyProtectedSystemManagedDirectory(at: root)
        try store.fileSystem
            .verifyProtectedSystemManagedDirectory(at: legacy)
    }

    private func requireExactChildren(
        _ directory: URL,
        names: Set<String>
    ) throws {
        guard try store.fileSystem.kind(at: directory) == .directory
        else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(directory.path)
        }
        let children = try store.fileSystem.children(of: directory)
        let actual = Set(children.map(\.lastPathComponent))
        guard actual == names,
              actual.count == children.count else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(directory.path)
        }
        for child in children
            where try store.fileSystem.kind(at: child)
                == .symbolicLink
        {
            throw DataResetStateMachineError
                .unsafeFileSystemState(child.path)
        }
    }

    private func requireTreeWithoutSymbolicLinks(_ root: URL) throws {
        let kind = try store.fileSystem.kind(at: root)
        guard kind == .directory else {
            throw DataResetStateMachineError
                .unsafeFileSystemState(root.path)
        }
        var stack = [root]
        var visited = 0
        while let directory = stack.popLast() {
            for child in try store.fileSystem.children(of: directory) {
                visited += 1
                guard visited
                    <= DataInventoryTaxonomy.maximumRowsPerModel else {
                    throw DataResetStateMachineError
                        .unsafeFileSystemState(root.path)
                }
                switch try store.fileSystem.kind(at: child) {
                case .directory:
                    stack.append(child)
                case .regularFile:
                    break
                case .symbolicLink, .missing, .other:
                    throw DataResetStateMachineError
                        .unsafeFileSystemState(child.path)
                }
            }
        }
    }
}
