import Foundation
import SwiftData

enum DataControlBackfillSource: String, Codable, Sendable {
    case bootstrapV12
    case schemaUpgradeV11
}

enum DataControlTargetKind: String, Codable, CaseIterable, Sendable {
    case journeyEntry
    case administrationOccurrence
    case draftRegimenVersion
    case sealedRegimenVersion
    case hrtJourney

    var isPlannerTarget: Bool {
        switch self {
        case .administrationOccurrence, .draftRegimenVersion,
             .sealedRegimenVersion:
            true
        case .journeyEntry, .hrtJourney:
            false
        }
    }

    var requiresTargetID: Bool {
        switch self {
        case .journeyEntry, .draftRegimenVersion, .sealedRegimenVersion:
            true
        case .administrationOccurrence, .hrtJourney:
            false
        }
    }

    func validates(stableKey: String, targetID: UUID?) -> Bool {
        guard requiresTargetID == (targetID != nil) else { return false }
        switch self {
        case .journeyEntry, .draftRegimenVersion, .sealedRegimenVersion:
            return stableKey == targetID?.uuidString.lowercased()
        case .administrationOccurrence:
            return !stableKey.isEmpty
                && stableKey == stableKey.precomposedStringWithCanonicalMapping
        case .hrtJourney:
            return stableKey == "primary-hrt-journey"
        }
    }

    func targetKey(stableKey: String) -> String {
        rawValue + ":" + stableKey
    }
}

@Model
final class DataControlDeletionTombstoneRecord {
    @Attribute(.unique) var targetKey: String
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var targetKindRawValue: String
    var targetStableKey: String
    var targetID: UUID?
    var sourceGenerationID: UUID
    var sourceDatasetID: UUID
    var sourceNextLocalRevision: Int64
    var expectedRecordKey: String
    var expectedLocalRevision: Int64
    var expectedDigestHex: String
    var targetSnapshotManifest: String
    var impactDigest: String
    var attachmentManifest: String
    var notificationManifest: String
    var retainedRecordCount: Int
    var deletedAttachmentCount: Int
    var deletedAttachmentBytes: Int64
    var affectedReminderCount: Int
    var committedAt: Date
    var localYear: Int
    var localMonth: Int
    var localDay: Int
    var localHour: Int
    var localMinute: Int
    var localSecond: Int
    var localNanosecond: Int
    var timeZoneIdentifier: String
    var utcOffsetSeconds: Int
    var precisionRawValue: String
    var provenanceRawValue: String
    var commandDigest: String

    var targetKind: DataControlTargetKind? {
        DataControlTargetKind(rawValue: targetKindRawValue)
    }

    var timestamp: HistoricalTimestamp? {
        guard let localDate = try? CivilDateFact(
            year: localYear,
            month: localMonth,
            day: localDay
        ),
        let localTime = try? HistoricalLocalTime(
            hour: localHour,
            minute: localMinute,
            second: localSecond,
            nanosecond: localNanosecond
        ),
        let precision = HistoricalTimestampPrecision(
            rawValue: precisionRawValue
        ),
        let provenance = HistoricalTimestampProvenance(
            rawValue: provenanceRawValue
        ) else {
            return nil
        }
        return try? HistoricalTimestamp(
            validatingInstant: committedAt,
            localDate: localDate,
            localTime: localTime,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            precision: precision,
            provenance: provenance
        )
    }

    init(
        targetKey: String,
        id: UUID,
        operationID: UUID,
        targetKind: DataControlTargetKind,
        targetStableKey: String,
        targetID: UUID?,
        sourceGenerationID: UUID,
        sourceDatasetID: UUID,
        sourceNextLocalRevision: Int64,
        expectedRecordKey: String,
        expectedLocalRevision: Int64,
        expectedDigestHex: String,
        targetSnapshotManifest: String,
        impactDigest: String,
        attachmentManifest: String,
        notificationManifest: String,
        retainedRecordCount: Int,
        deletedAttachmentCount: Int,
        deletedAttachmentBytes: Int64,
        affectedReminderCount: Int,
        timestamp: HistoricalTimestamp,
        commandDigest: String
    ) {
        self.targetKey = targetKey
        self.id = id
        self.operationID = operationID
        self.targetKindRawValue = targetKind.rawValue
        self.targetStableKey = targetStableKey
        self.targetID = targetID
        self.sourceGenerationID = sourceGenerationID
        self.sourceDatasetID = sourceDatasetID
        self.sourceNextLocalRevision = sourceNextLocalRevision
        self.expectedRecordKey = expectedRecordKey
        self.expectedLocalRevision = expectedLocalRevision
        self.expectedDigestHex = expectedDigestHex
        self.targetSnapshotManifest = targetSnapshotManifest
        self.impactDigest = impactDigest
        self.attachmentManifest = attachmentManifest
        self.notificationManifest = notificationManifest
        self.retainedRecordCount = retainedRecordCount
        self.deletedAttachmentCount = deletedAttachmentCount
        self.deletedAttachmentBytes = deletedAttachmentBytes
        self.affectedReminderCount = affectedReminderCount
        self.committedAt = timestamp.instant
        self.localYear = timestamp.localDate.year
        self.localMonth = timestamp.localDate.month
        self.localDay = timestamp.localDate.day
        self.localHour = timestamp.localTime.hour
        self.localMinute = timestamp.localTime.minute
        self.localSecond = timestamp.localTime.second
        self.localNanosecond = timestamp.localTime.nanosecond
        self.timeZoneIdentifier = timestamp.timeZoneIdentifier
        self.utcOffsetSeconds = timestamp.utcOffsetSeconds
        self.precisionRawValue = timestamp.precision.rawValue
        self.provenanceRawValue = timestamp.provenance.rawValue
        self.commandDigest = commandDigest
    }
}

@Model
final class DataControlBackfillState {
    static let fixedKey = "v11-to-v12-data-control"
    static let stableID = CoreTimeRegimenBackfill.stableUUID(for: fixedKey)

    @Attribute(.unique) var taskKey: String
    var sourceRawValue: String
    var initialTombstoneCount: Int
    var initialTombstoneSetDigest: String
    var completedAt: Date?
    var updatedAt: Date

    var source: DataControlBackfillSource? {
        DataControlBackfillSource(rawValue: sourceRawValue)
    }

    init(
        taskKey: String = DataControlBackfillState.fixedKey,
        source: DataControlBackfillSource,
        initialTombstoneCount: Int,
        initialTombstoneSetDigest: String,
        completedAt: Date?,
        updatedAt: Date
    ) {
        self.taskKey = taskKey
        self.sourceRawValue = source.rawValue
        self.initialTombstoneCount = initialTombstoneCount
        self.initialTombstoneSetDigest = initialTombstoneSetDigest
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

struct DataControlTargetSourceEntry: Equatable, Sendable {
    let recordKey: String
    let localRevision: Int64
    let digestHex: String
}

struct DataControlOccurrenceProjection: Equatable, Sendable {
    let key: String
    let scheduleRuleID: UUID
    let scheduleRevision: Int64
    let regimenVersionID: UUID
    let regimenItemID: UUID
    let displayTimeZoneIdentifier: String
    let localYear: Int64
    let localMonth: Int64
    let localDay: Int64
    let localHour: Int64
    let localMinute: Int64
    let localSecond: Int64
    let localNanosecond: Int64
    let resolvedTimeZoneIdentifier: String
    let utcOffsetSeconds: Int64
    let instant: Date
}

struct DataControlTargetSnapshot: Equatable, Sendable {
    let targetKind: DataControlTargetKind
    let targetStableKey: String
    let targetID: UUID?
    let expectedRecordKey: String
    let sources: [DataControlTargetSourceEntry]
    let occurrenceProjection: DataControlOccurrenceProjection?

    var targetKey: String {
        targetKind.targetKey(stableKey: targetStableKey)
    }

    var expectedLocalRevision: Int64? {
        sources.map(\.localRevision).max()
    }
}

struct DataControlAttachmentManifestEntry: Equatable, Sendable {
    let attachmentID: UUID
    let ownerType: String
    let ownerID: UUID
    let relativePath: String
    let originalFilename: String
    let contentType: String
    let createdAt: Date
    let byteCount: Int64
    let sha256Hex: String
    let deletionOperationID: UUID
}

enum DataControlNotificationNamespace: UInt8, Codable, Sendable {
    case execution = 0x01
    case countdown = 0x02

    var rawName: String {
        switch self {
        case .execution: "execution"
        case .countdown: "countdown"
        }
    }

    var identifierPrefix: String {
        switch self {
        case .execution: "unmanual.exec.v1."
        case .countdown: "unmanual.countdown.v1."
        }
    }
}

struct DataControlPendingNotificationEntry: Equatable, Sendable {
    let namespace: DataControlNotificationNamespace
    let identifier: String
}

struct DeletionImpact: Equatable, Sendable {
    static let boundaryContractVersion = "batch6-impact-v1"

    let generationID: UUID
    let datasetID: UUID
    let expectedNextLocalRevision: Int64
    let targetKind: DataControlTargetKind
    let targetStableKey: String
    let targetID: UUID?
    let expectedRecordKey: String
    let expectedLocalRevision: Int64
    let expectedDigestHex: String
    let targetSnapshotManifest: String
    let attachmentManifest: String
    let notificationManifest: String
    let retainedRecordCount: Int
    let deletedAttachmentCount: Int
    let deletedAttachmentBytes: Int64
    let affectedReminderCount: Int

    var targetKey: String {
        targetKind.targetKey(stableKey: targetStableKey)
    }
}

struct DeleteDataControlTargetCommand: Equatable, Sendable {
    let operationID: UUID
    let generationID: UUID
    let datasetID: UUID
    let expectedNextLocalRevision: Int64
    let targetKind: DataControlTargetKind
    let targetStableKey: String
    let targetID: UUID?
    let expectedRecordKey: String
    let expectedLocalRevision: Int64
    let expectedDigestHex: String
    let targetSnapshotManifest: String
    let impactDigest: String
    let attachmentManifest: String
    let notificationManifest: String
    let committedAt: Date
    let localYear: Int
    let localMonth: Int
    let localDay: Int
    let localHour: Int
    let localMinute: Int
    let localSecond: Int
    let localNanosecond: Int
    let timeZoneIdentifier: String
    let utcOffsetSeconds: Int
    let precisionRawValue: String
    let provenanceRawValue: String

    init(
        operationID: UUID,
        generationID: UUID,
        datasetID: UUID,
        expectedNextLocalRevision: Int64,
        targetKind: DataControlTargetKind,
        targetStableKey: String,
        targetID: UUID?,
        expectedRecordKey: String,
        expectedLocalRevision: Int64,
        expectedDigestHex: String,
        targetSnapshotManifest: String,
        impactDigest: String,
        attachmentManifest: String,
        notificationManifest: String,
        timestamp: HistoricalTimestamp
    ) {
        self.operationID = operationID
        self.generationID = generationID
        self.datasetID = datasetID
        self.expectedNextLocalRevision = expectedNextLocalRevision
        self.targetKind = targetKind
        self.targetStableKey = targetStableKey
        self.targetID = targetID
        self.expectedRecordKey = expectedRecordKey
        self.expectedLocalRevision = expectedLocalRevision
        self.expectedDigestHex = expectedDigestHex
        self.targetSnapshotManifest = targetSnapshotManifest
        self.impactDigest = impactDigest
        self.attachmentManifest = attachmentManifest
        self.notificationManifest = notificationManifest
        self.committedAt = timestamp.instant
        self.localYear = timestamp.localDate.year
        self.localMonth = timestamp.localDate.month
        self.localDay = timestamp.localDate.day
        self.localHour = timestamp.localTime.hour
        self.localMinute = timestamp.localTime.minute
        self.localSecond = timestamp.localTime.second
        self.localNanosecond = timestamp.localTime.nanosecond
        self.timeZoneIdentifier = timestamp.timeZoneIdentifier
        self.utcOffsetSeconds = timestamp.utcOffsetSeconds
        self.precisionRawValue = timestamp.precision.rawValue
        self.provenanceRawValue = timestamp.provenance.rawValue
    }
}

enum DataControlDigestV1 {
    static let tombstoneSetRecordID = CoreTimeRegimenBackfill.stableUUID(
        for: "data-control-tombstone-set-v1"
    )

    static func initialTombstoneSetDigest() throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "DataControlTombstoneSetV1",
            recordID: tombstoneSetRecordID,
            fields: [.init("count", .integer(0))]
        )
    }

    static func backfillState(
        _ value: DataControlBackfillState
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "completedAt",
                try value.completedAt.map(RecordDigestV1.timestampValue)
                    ?? .null
            ),
            .init(
                "initialTombstoneCount",
                .integer(Int64(value.initialTombstoneCount))
            ),
            .init(
                "initialTombstoneSetDigest",
                .string(value.initialTombstoneSetDigest)
            ),
            .init("source", .string(value.sourceRawValue)),
            .init("taskKey", .string(value.taskKey)),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(value.updatedAt)
            )
        ]
    }

    static func tombstone(
        _ value: DataControlDeletionTombstoneRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "affectedReminderCount",
                .integer(Int64(value.affectedReminderCount))
            ),
            .init("attachmentManifest", .string(value.attachmentManifest)),
            .init("commandDigest", .string(value.commandDigest)),
            .init(
                "committedAt",
                try RecordDigestV1.timestampValue(value.committedAt)
            ),
            .init(
                "deletedAttachmentBytes",
                .integer(value.deletedAttachmentBytes)
            ),
            .init(
                "deletedAttachmentCount",
                .integer(Int64(value.deletedAttachmentCount))
            ),
            .init("expectedDigestHex", .string(value.expectedDigestHex)),
            .init(
                "expectedLocalRevision",
                .integer(value.expectedLocalRevision)
            ),
            .init("expectedRecordKey", .string(value.expectedRecordKey)),
            .init("id", .uuid(value.id)),
            .init("impactDigest", .string(value.impactDigest)),
            .init("localDay", .integer(Int64(value.localDay))),
            .init("localHour", .integer(Int64(value.localHour))),
            .init("localMinute", .integer(Int64(value.localMinute))),
            .init("localMonth", .integer(Int64(value.localMonth))),
            .init(
                "localNanosecond",
                .integer(Int64(value.localNanosecond))
            ),
            .init("localSecond", .integer(Int64(value.localSecond))),
            .init("localYear", .integer(Int64(value.localYear))),
            .init("notificationManifest", .string(value.notificationManifest)),
            .init("operationID", .uuid(value.operationID)),
            .init("precisionRawValue", .string(value.precisionRawValue)),
            .init("provenanceRawValue", .string(value.provenanceRawValue)),
            .init(
                "retainedRecordCount",
                .integer(Int64(value.retainedRecordCount))
            ),
            .init("sourceDatasetID", .uuid(value.sourceDatasetID)),
            .init("sourceGenerationID", .uuid(value.sourceGenerationID)),
            .init(
                "sourceNextLocalRevision",
                .integer(value.sourceNextLocalRevision)
            ),
            .init("targetID", value.targetID.map(RecordDigestV1.Value.uuid) ?? .null),
            .init("targetKey", .string(value.targetKey)),
            .init("targetKindRawValue", .string(value.targetKindRawValue)),
            .init(
                "targetSnapshotManifest",
                .string(value.targetSnapshotManifest)
            ),
            .init("targetStableKey", .string(value.targetStableKey)),
            .init(
                "timeZoneIdentifier",
                .string(value.timeZoneIdentifier)
            ),
            .init(
                "utcOffsetSeconds",
                .integer(Int64(value.utcOffsetSeconds))
            )
        ]
    }

    static func targetToken(_ snapshotManifest: String) throws -> String {
        guard let snapshot = DataControlTargetSnapshotManifest.decode(
            snapshotManifest
        ) else {
            throw AppDataFailure.corruptionSuspected
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "DataControlTargetTokenV1",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: "data-control-target:" + snapshot.targetKey
            ),
            fields: [
                .init(
                    "targetSnapshotManifest",
                    .string(snapshotManifest)
                )
            ]
        )
    }

    static func impact(_ value: DeletionImpact) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "DeletionImpactV1",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: "data-control-target:" + value.targetKey
            ),
            fields: [
                .init(
                    "affectedReminderCount",
                    .integer(Int64(value.affectedReminderCount))
                ),
                .init(
                    "attachmentManifest",
                    .string(value.attachmentManifest)
                ),
                .init(
                    "boundaryContractVersion",
                    .string(DeletionImpact.boundaryContractVersion)
                ),
                .init(
                    "datasetID",
                    .uuid(value.datasetID)
                ),
                .init(
                    "deletedAttachmentBytes",
                    .integer(value.deletedAttachmentBytes)
                ),
                .init(
                    "deletedAttachmentCount",
                    .integer(Int64(value.deletedAttachmentCount))
                ),
                .init(
                    "expectedDigestHex",
                    .string(value.expectedDigestHex)
                ),
                .init(
                    "expectedLocalRevision",
                    .integer(value.expectedLocalRevision)
                ),
                .init(
                    "expectedNextLocalRevision",
                    .integer(value.expectedNextLocalRevision)
                ),
                .init(
                    "expectedRecordKey",
                    .string(value.expectedRecordKey)
                ),
                .init("generationID", .uuid(value.generationID)),
                .init(
                    "notificationManifest",
                    .string(value.notificationManifest)
                ),
                .init(
                    "retainedRecordCount",
                    .integer(Int64(value.retainedRecordCount))
                ),
                .init(
                    "targetID",
                    value.targetID.map(RecordDigestV1.Value.uuid) ?? .null
                ),
                .init(
                    "targetKindRawValue",
                    .string(value.targetKind.rawValue)
                ),
                .init(
                    "targetSnapshotManifest",
                    .string(value.targetSnapshotManifest)
                ),
                .init(
                    "targetStableKey",
                    .string(value.targetStableKey)
                )
            ]
        )
    }

    static func deleteCommand(
        _ command: DeleteDataControlTargetCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "DeleteDataControlTargetCommand",
            recordID: command.operationID,
            fields: [
                .init(
                    "committedAt",
                    try RecordDigestV1.timestampValue(command.committedAt)
                ),
                .init("datasetID", .uuid(command.datasetID)),
                .init(
                    "expectedDigestHex",
                    .string(command.expectedDigestHex)
                ),
                .init(
                    "expectedLocalRevision",
                    .integer(command.expectedLocalRevision)
                ),
                .init(
                    "expectedNextLocalRevision",
                    .integer(command.expectedNextLocalRevision)
                ),
                .init(
                    "expectedRecordKey",
                    .string(command.expectedRecordKey)
                ),
                .init("generationID", .uuid(command.generationID)),
                .init("impactDigest", .string(command.impactDigest)),
                .init("localDay", .integer(Int64(command.localDay))),
                .init("localHour", .integer(Int64(command.localHour))),
                .init("localMinute", .integer(Int64(command.localMinute))),
                .init("localMonth", .integer(Int64(command.localMonth))),
                .init(
                    "localNanosecond",
                    .integer(Int64(command.localNanosecond))
                ),
                .init("localSecond", .integer(Int64(command.localSecond))),
                .init("localYear", .integer(Int64(command.localYear))),
                .init(
                    "notificationManifest",
                    .string(command.notificationManifest)
                ),
                .init("operationID", .uuid(command.operationID)),
                .init(
                    "precisionRawValue",
                    .string(command.precisionRawValue)
                ),
                .init(
                    "provenanceRawValue",
                    .string(command.provenanceRawValue)
                ),
                .init(
                    "targetID",
                    command.targetID.map(RecordDigestV1.Value.uuid) ?? .null
                ),
                .init(
                    "targetKindRawValue",
                    .string(command.targetKind.rawValue)
                ),
                .init(
                    "targetSnapshotManifest",
                    .string(command.targetSnapshotManifest)
                ),
                .init(
                    "targetStableKey",
                    .string(command.targetStableKey)
                ),
                .init(
                    "timeZoneIdentifier",
                    .string(command.timeZoneIdentifier)
                ),
                .init(
                    "utcOffsetSeconds",
                    .integer(Int64(command.utcOffsetSeconds))
                ),
                .init(
                    "attachmentManifest",
                    .string(command.attachmentManifest)
                )
            ]
        )
    }
}

private enum DataControlCanonicalCodec {
    static let maximumEntries = 1_000_000

    struct Writer {
        private(set) var data = Data()

        mutating func append(_ value: UInt8) {
            data.append(value)
        }

        mutating func append(_ value: UInt32) {
            var value = value.bigEndian
            withUnsafeBytes(of: &value) {
                data.append(contentsOf: $0)
            }
        }

        mutating func append(_ value: Int64) {
            var value = value.bigEndian
            withUnsafeBytes(of: &value) {
                data.append(contentsOf: $0)
            }
        }

        mutating func append(_ value: UUID) {
            var uuid = value.uuid
            withUnsafeBytes(of: &uuid) {
                data.append(contentsOf: $0)
            }
        }

        mutating func append(string: String) -> Bool {
            let normalized = string.precomposedStringWithCanonicalMapping
            let bytes = Data(normalized.utf8)
            guard bytes.count <= Int(UInt32.max) else { return false }
            append(UInt32(bytes.count))
            data.append(bytes)
            return true
        }

        mutating func append(hashHex: String) -> Bool {
            guard let bytes = DataControlCanonicalCodec.hashBytes(hashHex) else {
                return false
            }
            data.append(bytes)
            return true
        }
    }

    struct Reader {
        let data: Data
        private(set) var offset = 0

        var isAtEnd: Bool {
            offset == data.count
        }

        mutating func readUInt8() -> UInt8? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readUInt32() -> UInt32? {
            guard let bytes = readBytes(count: 4) else { return nil }
            return bytes.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
        }

        mutating func readInt64() -> Int64? {
            guard let bytes = readBytes(count: 8) else { return nil }
            let bits = bytes.reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            return Int64(bitPattern: bits)
        }

        mutating func readUUID() -> UUID? {
            guard let bytes = readBytes(count: 16) else { return nil }
            return UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
        }

        mutating func readString() -> String? {
            guard let count = readUInt32(),
                  let bytes = readBytes(count: Int(count)),
                  let value = String(bytes: bytes, encoding: .utf8),
                  value == value.precomposedStringWithCanonicalMapping else {
                return nil
            }
            return value
        }

        mutating func readHashHex() -> String? {
            guard let bytes = readBytes(count: 32) else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        mutating func readDate() -> Date? {
            guard let microseconds = readInt64() else { return nil }
            let date = Date(
                timeIntervalSince1970: Double(microseconds) / 1_000_000
            )
            guard date.timeIntervalSince1970.isFinite,
                  (try? RecordDigestV1.timestampMicroseconds(date))
                    == microseconds else {
                return nil
            }
            return date
        }

        private mutating func readBytes(count: Int) -> [UInt8]? {
            guard count >= 0, count <= data.count - offset else { return nil }
            let end = offset + count
            defer { offset = end }
            return Array(data[offset..<end])
        }
    }

    static func encode(prefix: String, bytes: Data) -> String {
        prefix + base64URLEncode(bytes)
    }

    static func decode(_ value: String, prefix: String) -> Data? {
        guard value.hasPrefix(prefix) else { return nil }
        let payload = String(value.dropFirst(prefix.count))
        guard !payload.contains("="),
              payload.allSatisfy({
                  $0.isASCII
                      && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
              }),
              payload.count % 4 != 1 else {
            return nil
        }
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              base64URLEncode(data) == payload else {
            return nil
        }
        return data
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.precomposedStringWithCanonicalMapping,
              !value.hasPrefix("/"),
              !value.contains("\\") else {
            return false
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func isDigest(_ value: String) -> Bool {
        hashBytes(value) != nil
    }

    static func uuidBytes(_ value: UUID) -> [UInt8] {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Array($0) }
    }

    static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hashBytes(_ value: String) -> Data? {
        guard value.count == 64,
              value.allSatisfy({
                  $0.isHexDigit && !$0.isUppercase
              }) else {
            return nil
        }
        var result = Data()
        result.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }
}

enum DataControlTargetSnapshotManifest {
    private static let prefix = "dct1."

    static func encode(_ snapshot: DataControlTargetSnapshot) -> String? {
        guard snapshot.targetKind.validates(
            stableKey: snapshot.targetStableKey,
            targetID: snapshot.targetID
        ),
        snapshot.expectedRecordKey
            == "DataControlTarget:" + snapshot.targetKey,
        !snapshot.sources.isEmpty,
        snapshot.sources.count <= DataControlCanonicalCodec.maximumEntries else {
            return nil
        }
        let sources = snapshot.sources.sorted {
            DataControlCanonicalCodec.utf8Precedes(
                $0.recordKey,
                $1.recordKey
            )
        }
        guard Set(sources.map(\.recordKey)).count == sources.count,
              sources.allSatisfy({
                  !$0.recordKey.isEmpty
                      && $0.localRevision > 0
                      && DataControlCanonicalCodec.isDigest($0.digestHex)
              }),
              (snapshot.targetKind == .administrationOccurrence)
                == (snapshot.occurrenceProjection != nil) else {
            return nil
        }

        var writer = DataControlCanonicalCodec.Writer()
        guard writer.append(string: snapshot.targetKind.rawValue),
              writer.append(string: snapshot.targetStableKey) else {
            return nil
        }
        if let targetID = snapshot.targetID {
            writer.append(UInt8(0x01))
            writer.append(targetID)
        } else {
            writer.append(UInt8(0x00))
        }
        guard writer.append(string: snapshot.expectedRecordKey) else {
            return nil
        }
        writer.append(UInt32(sources.count))
        for source in sources {
            guard writer.append(string: source.recordKey) else {
                return nil
            }
            writer.append(source.localRevision)
            guard writer.append(hashHex: source.digestHex) else {
                return nil
            }
        }

        guard let occurrence = snapshot.occurrenceProjection else {
            writer.append(UInt8(0x00))
            return DataControlCanonicalCodec.encode(
                prefix: prefix,
                bytes: writer.data
            )
        }
        writer.append(UInt8(0x01))
        guard writer.append(string: occurrence.key) else { return nil }
        writer.append(occurrence.scheduleRuleID)
        writer.append(occurrence.scheduleRevision)
        writer.append(occurrence.regimenVersionID)
        writer.append(occurrence.regimenItemID)
        guard writer.append(string: occurrence.displayTimeZoneIdentifier) else {
            return nil
        }
        writer.append(occurrence.localYear)
        writer.append(occurrence.localMonth)
        writer.append(occurrence.localDay)
        writer.append(occurrence.localHour)
        writer.append(occurrence.localMinute)
        writer.append(occurrence.localSecond)
        writer.append(occurrence.localNanosecond)
        guard writer.append(string: occurrence.resolvedTimeZoneIdentifier) else {
            return nil
        }
        writer.append(occurrence.utcOffsetSeconds)
        guard let instant = try? RecordDigestV1.timestampMicroseconds(
            occurrence.instant
        ) else {
            return nil
        }
        writer.append(instant)
        return DataControlCanonicalCodec.encode(
            prefix: prefix,
            bytes: writer.data
        )
    }

    static func decode(_ manifest: String) -> DataControlTargetSnapshot? {
        guard let data = DataControlCanonicalCodec.decode(
            manifest,
            prefix: prefix
        ) else {
            return nil
        }
        var reader = DataControlCanonicalCodec.Reader(data: data)
        guard let kindRawValue = reader.readString(),
              let kind = DataControlTargetKind(rawValue: kindRawValue),
              let stableKey = reader.readString(),
              let targetPresence = reader.readUInt8(),
              targetPresence == 0x00 || targetPresence == 0x01 else {
            return nil
        }
        let targetID: UUID?
        if targetPresence == 0x01 {
            guard let value = reader.readUUID() else { return nil }
            targetID = value
        } else {
            targetID = nil
        }
        guard let expectedRecordKey = reader.readString(),
              let sourceCountRaw = reader.readUInt32(),
              sourceCountRaw > 0,
              sourceCountRaw <= DataControlCanonicalCodec.maximumEntries else {
            return nil
        }
        var sources: [DataControlTargetSourceEntry] = []
        sources.reserveCapacity(Int(sourceCountRaw))
        for _ in 0..<sourceCountRaw {
            guard let recordKey = reader.readString(),
                  let localRevision = reader.readInt64(),
                  let digestHex = reader.readHashHex(),
                  localRevision > 0 else {
                return nil
            }
            sources.append(
                DataControlTargetSourceEntry(
                    recordKey: recordKey,
                    localRevision: localRevision,
                    digestHex: digestHex
                )
            )
        }
        guard let occurrencePresence = reader.readUInt8(),
              occurrencePresence == 0x00 || occurrencePresence == 0x01 else {
            return nil
        }
        let occurrence: DataControlOccurrenceProjection?
        if occurrencePresence == 0x01 {
            guard let key = reader.readString(),
                  let scheduleRuleID = reader.readUUID(),
                  let scheduleRevision = reader.readInt64(),
                  let regimenVersionID = reader.readUUID(),
                  let regimenItemID = reader.readUUID(),
                  let displayTimeZoneIdentifier = reader.readString(),
                  let localYear = reader.readInt64(),
                  let localMonth = reader.readInt64(),
                  let localDay = reader.readInt64(),
                  let localHour = reader.readInt64(),
                  let localMinute = reader.readInt64(),
                  let localSecond = reader.readInt64(),
                  let localNanosecond = reader.readInt64(),
                  let resolvedTimeZoneIdentifier = reader.readString(),
                  let utcOffsetSeconds = reader.readInt64(),
                  let instant = reader.readDate() else {
                return nil
            }
            occurrence = DataControlOccurrenceProjection(
                key: key,
                scheduleRuleID: scheduleRuleID,
                scheduleRevision: scheduleRevision,
                regimenVersionID: regimenVersionID,
                regimenItemID: regimenItemID,
                displayTimeZoneIdentifier: displayTimeZoneIdentifier,
                localYear: localYear,
                localMonth: localMonth,
                localDay: localDay,
                localHour: localHour,
                localMinute: localMinute,
                localSecond: localSecond,
                localNanosecond: localNanosecond,
                resolvedTimeZoneIdentifier: resolvedTimeZoneIdentifier,
                utcOffsetSeconds: utcOffsetSeconds,
                instant: instant
            )
        } else {
            occurrence = nil
        }
        let snapshot = DataControlTargetSnapshot(
            targetKind: kind,
            targetStableKey: stableKey,
            targetID: targetID,
            expectedRecordKey: expectedRecordKey,
            sources: sources,
            occurrenceProjection: occurrence
        )
        guard reader.isAtEnd,
              encode(snapshot) == manifest else {
            return nil
        }
        return snapshot
    }
}

enum DataControlAttachmentManifest {
    private static let prefix = "dcm1-a."

    static func encode(
        _ entries: [DataControlAttachmentManifestEntry]
    ) -> String? {
        guard entries.count <= DataControlCanonicalCodec.maximumEntries else {
            return nil
        }
        let entries = entries.sorted {
            DataControlCanonicalCodec.uuidBytes($0.attachmentID)
                .lexicographicallyPrecedes(
                    DataControlCanonicalCodec.uuidBytes($1.attachmentID)
                )
        }
        guard Set(entries.map(\.attachmentID)).count == entries.count,
              Set(entries.map(\.deletionOperationID)).count == entries.count,
              entries.allSatisfy({
                  !$0.ownerType.isEmpty
                      && DataControlCanonicalCodec.isSafeRelativePath(
                          $0.relativePath
                      )
                      && !$0.originalFilename.isEmpty
                      && !$0.contentType.isEmpty
                      && $0.byteCount >= 0
                      && $0.createdAt.timeIntervalSince1970.isFinite
                      && DataControlCanonicalCodec.isDigest($0.sha256Hex)
              }) else {
            return nil
        }
        var writer = DataControlCanonicalCodec.Writer()
        writer.append(UInt32(entries.count))
        for entry in entries {
            writer.append(entry.attachmentID)
            guard writer.append(string: entry.ownerType) else { return nil }
            writer.append(entry.ownerID)
            guard writer.append(string: entry.relativePath),
                  writer.append(string: entry.originalFilename),
                  writer.append(string: entry.contentType),
                  let createdAt = try? RecordDigestV1.timestampMicroseconds(
                      entry.createdAt
                  ) else {
                return nil
            }
            writer.append(createdAt)
            writer.append(entry.byteCount)
            guard writer.append(hashHex: entry.sha256Hex) else { return nil }
            writer.append(entry.deletionOperationID)
        }
        return DataControlCanonicalCodec.encode(
            prefix: prefix,
            bytes: writer.data
        )
    }

    static func decode(
        _ manifest: String
    ) -> [DataControlAttachmentManifestEntry]? {
        guard let data = DataControlCanonicalCodec.decode(
            manifest,
            prefix: prefix
        ) else {
            return nil
        }
        var reader = DataControlCanonicalCodec.Reader(data: data)
        guard let count = reader.readUInt32(),
              count <= DataControlCanonicalCodec.maximumEntries else {
            return nil
        }
        var entries: [DataControlAttachmentManifestEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let attachmentID = reader.readUUID(),
                  let ownerType = reader.readString(),
                  let ownerID = reader.readUUID(),
                  let relativePath = reader.readString(),
                  let originalFilename = reader.readString(),
                  let contentType = reader.readString(),
                  let createdAt = reader.readDate(),
                  let byteCount = reader.readInt64(),
                  let sha256Hex = reader.readHashHex(),
                  let deletionOperationID = reader.readUUID() else {
                return nil
            }
            entries.append(
                DataControlAttachmentManifestEntry(
                    attachmentID: attachmentID,
                    ownerType: ownerType,
                    ownerID: ownerID,
                    relativePath: relativePath,
                    originalFilename: originalFilename,
                    contentType: contentType,
                    createdAt: createdAt,
                    byteCount: byteCount,
                    sha256Hex: sha256Hex,
                    deletionOperationID: deletionOperationID
                )
            )
        }
        guard reader.isAtEnd, encode(entries) == manifest else { return nil }
        return entries
    }
}

enum DataControlPendingNotificationManifest {
    private static let prefix = "dcm1-n."

    static func encode(
        _ entries: [DataControlPendingNotificationEntry]
    ) -> String? {
        guard entries.count <= DataControlCanonicalCodec.maximumEntries else {
            return nil
        }
        let entries = entries.sorted {
            $0.namespace.rawValue != $1.namespace.rawValue
                ? $0.namespace.rawValue < $1.namespace.rawValue
                : DataControlCanonicalCodec.utf8Precedes(
                    $0.identifier,
                    $1.identifier
                )
        }
        guard Set(entries.map {
            String($0.namespace.rawValue) + ":" + $0.identifier
        }).count == entries.count,
        entries.allSatisfy({
            !$0.identifier.isEmpty
                && $0.identifier.hasPrefix($0.namespace.identifierPrefix)
        }) else {
            return nil
        }
        var writer = DataControlCanonicalCodec.Writer()
        writer.append(UInt32(entries.count))
        for entry in entries {
            writer.append(entry.namespace.rawValue)
            guard writer.append(string: entry.identifier) else { return nil }
        }
        return DataControlCanonicalCodec.encode(
            prefix: prefix,
            bytes: writer.data
        )
    }

    static func decode(
        _ manifest: String
    ) -> [DataControlPendingNotificationEntry]? {
        guard let data = DataControlCanonicalCodec.decode(
            manifest,
            prefix: prefix
        ) else {
            return nil
        }
        var reader = DataControlCanonicalCodec.Reader(data: data)
        guard let count = reader.readUInt32(),
              count <= DataControlCanonicalCodec.maximumEntries else {
            return nil
        }
        var entries: [DataControlPendingNotificationEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let rawNamespace = reader.readUInt8(),
                  let namespace = DataControlNotificationNamespace(
                      rawValue: rawNamespace
                  ),
                  let identifier = reader.readString() else {
                return nil
            }
            entries.append(
                DataControlPendingNotificationEntry(
                    namespace: namespace,
                    identifier: identifier
                )
            )
        }
        guard reader.isAtEnd, encode(entries) == manifest else { return nil }
        return entries
    }
}
