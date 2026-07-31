import Foundation
import SwiftData

@Model
final class ContentFavoriteRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var contentID: String
    var contentVersion: String
    var cardDigest: String
    var createdAt: Date
    var updatedAt: Date
    var removedAt: Date?
    var lastOperationID: UUID

    init(
        id: UUID,
        contentID: String,
        contentVersion: String,
        cardDigest: String,
        createdAt: Date,
        updatedAt: Date,
        removedAt: Date?,
        lastOperationID: UUID
    ) {
        self.id = id
        self.contentID = contentID
        self.contentVersion = contentVersion
        self.cardDigest = cardDigest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.removedAt = removedAt
        self.lastOperationID = lastOperationID
    }
}

struct ContentFavoriteSnapshot: Equatable, Sendable {
    let id: UUID
    let contentID: String
    let contentVersion: String
    let cardDigest: String
    let createdAt: Date
    let updatedAt: Date
    let removedAt: Date?
    let lastOperationID: UUID
    let localRevision: Int64
    let digestHex: String

    var isFavorite: Bool { removedAt == nil }
}

struct SetContentFavoriteCommand: Equatable, Sendable {
    let operationID: UUID
    let recordID: UUID
    let contentID: String
    let contentVersion: String
    let cardDigest: String
    let desiredFavorite: Bool
    let expectedLocalRevision: Int64?
    let expectedDigestHex: String?
    let committedAt: Date

    init(
        operationID: UUID,
        recordID: UUID,
        contentID: String,
        contentVersion: String,
        cardDigest: String,
        desiredFavorite: Bool,
        expectedLocalRevision: Int64?,
        expectedDigestHex: String?,
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.recordID = recordID
        self.contentID = contentID
        self.contentVersion = contentVersion
        self.cardDigest = cardDigest
        self.desiredFavorite = desiredFavorite
        self.expectedLocalRevision = expectedLocalRevision
        self.expectedDigestHex = expectedDigestHex
        self.committedAt = committedAt
    }
}

struct SetContentFavoriteResult: Equatable, Sendable {
    let snapshot: ContentFavoriteSnapshot
    let didApply: Bool
}

enum ContentFavoriteWriteFailure: Error, Equatable, Sendable {
    case invalidInput
    case staleRecord
    case operationConflict
    case corruptionSuspected
}

enum ContentFavoriteContract {
    static let recordType = "ContentFavoriteRecord"
    static let maximumRecords = 100_000

    static func recordKey(_ id: UUID) -> String {
        recordType + ":" + id.uuidString.lowercased()
    }

    static func isValidContentID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 128,
              bytes.allSatisfy({ $0 < 0x80 }),
              (0x61...0x7A).contains(bytes[0]) else {
            return false
        }
        var previousWasSeparator = false
        for byte in bytes {
            let isLetter = (0x61...0x7A).contains(byte)
            let isDigit = (0x30...0x39).contains(byte)
            let isSeparator = byte == 0x2D || byte == 0x2E
            guard isLetter || isDigit || isSeparator else {
                return false
            }
            if isSeparator && previousWasSeparator {
                return false
            }
            previousWasSeparator = isSeparator
        }
        return !previousWasSeparator
    }

    static func isValidContentVersion(_ value: String) -> Bool {
        let normalized =
            value.precomposedStringWithCanonicalMapping
        return !value.isEmpty
            && value.lengthOfBytes(using: .utf8) <= 128
            && value.utf8.elementsEqual(normalized.utf8)
    }

    static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x61...0x66).contains($0)
            }
    }

    static func isValid(_ record: ContentFavoriteRecord) -> Bool {
        isValidContentID(record.contentID)
            && isValidContentVersion(record.contentVersion)
            && isCanonicalDigest(record.cardDigest)
            && record.createdAt.timeIntervalSince1970.isFinite
            && record.updatedAt.timeIntervalSince1970.isFinite
            && record.updatedAt >= record.createdAt
            && (
                record.removedAt == nil
                    || (
                        record.removedAt?.timeIntervalSince1970
                            .isFinite == true
                            && record.removedAt == record.updatedAt
                    )
            )
    }
}

enum ContentFavoriteDigestV1 {
    static func record(
        _ value: ContentFavoriteRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("cardDigest", .string(value.cardDigest)),
            .init("contentID", .string(value.contentID)),
            .init("contentVersion", .string(value.contentVersion)),
            .init(
                "createdAt",
                try RecordDigestV1.timestampValue(value.createdAt)
            ),
            .init(
                "lastOperationID",
                .uuid(value.lastOperationID)
            ),
            .init(
                "removedAt",
                try value.removedAt.map(
                    RecordDigestV1.timestampValue
                ) ?? .null
            ),
            .init(
                "updatedAt",
                try RecordDigestV1.timestampValue(value.updatedAt)
            )
        ]
    }

    static func command(
        _ value: SetContentFavoriteCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "SetContentFavoriteCommand",
            recordID: value.operationID,
            fields: [
                .init("cardDigest", .string(value.cardDigest)),
                .init(
                    "committedAt",
                    try RecordDigestV1.timestampValue(
                        value.committedAt
                    )
                ),
                .init("contentID", .string(value.contentID)),
                .init(
                    "contentVersion",
                    .string(value.contentVersion)
                ),
                .init(
                    "desiredFavorite",
                    .bool(value.desiredFavorite)
                ),
                .init(
                    "expectedDigestHex",
                    value.expectedDigestHex.map(
                        RecordDigestV1.Value.string
                    ) ?? .null
                ),
                .init(
                    "expectedLocalRevision",
                    value.expectedLocalRevision.map(
                        RecordDigestV1.Value.integer
                    ) ?? .null
                ),
                .init("operationID", .uuid(value.operationID)),
                .init("recordID", .uuid(value.recordID)),
                .init(
                    "recordKey",
                    .string(
                        ContentFavoriteContract.recordKey(
                            value.recordID
                        )
                    )
                )
            ]
        )
    }
}

enum ContentFavoriteRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure = .corruptionSuspected
    ) throws {
        _ = try snapshots(in: context, failure: failure)
    }

    static func snapshots(
        in context: ModelContext,
        failure: AppDataFailure = .corruptionSuspected
    ) throws -> [ContentFavoriteSnapshot] {
        var recordDescriptor =
            FetchDescriptor<ContentFavoriteRecord>()
        recordDescriptor.fetchLimit =
            ContentFavoriteContract.maximumRecords + 1
        let records = try context.fetch(recordDescriptor)
        guard records.count <=
                ContentFavoriteContract.maximumRecords else {
            throw failure
        }
        _ = try AppDataIndex.checkedUniqueMap(
            records,
            keyedBy: \.id,
            failure: failure
        )
        _ = try AppDataIndex.checkedUniqueMap(
            records,
            keyedBy: \.contentID,
            failure: failure
        )

        var metadataDescriptor =
            FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRows = try context.fetch(metadataDescriptor)
        guard metadataRows.count == 1,
              let metadata = metadataRows.first else {
            throw failure
        }

        let recordType = ContentFavoriteContract.recordType
        var revisionDescriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordType == recordType
            }
        )
        revisionDescriptor.fetchLimit =
            ContentFavoriteContract.maximumRecords + 1
        let revisions = try context.fetch(revisionDescriptor)
        let revisionsByID = try AppDataIndex.checkedUniqueMap(
            revisions,
            keyedBy: \.recordID,
            failure: failure
        )
        guard revisions.count == records.count else {
            throw failure
        }

        let receiptSet =
            try OperationReceiptLedgerIntegrityValidator.validate(
                in: context,
                failure: failure
            )
        let favoriteReceipts =
            receiptSet.receiptsByOperationID.values.filter {
                $0.resultRecordType
                    == ContentFavoriteContract.recordType
            }
        let recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
        for receipt in favoriteReceipts {
            guard let record = recordsByID[receipt.resultRecordID],
                  receipt.committedAt >= record.createdAt,
                  receipt.committedAt <= record.updatedAt,
                  let receiptRevision = receiptSet
                    .revisionsByOperationID[receipt.operationID],
                  receiptRevision.committedAt
                    == receipt.committedAt else {
                throw failure
            }
        }

        let favoriteReceiptIDs = Set(
            favoriteReceipts.map(\.operationID)
        )
        let snapshots = try records.map { record in
            guard ContentFavoriteContract.isValid(record),
                  let revision = revisionsByID[record.id],
                  revision.recordKey
                    == ContentFavoriteContract.recordKey(record.id),
                  revision.recordType
                    == ContentFavoriteContract.recordType,
                  revision.recordID == record.id,
                  revision.datasetID == metadata.datasetID,
                  revision.localRevision > 0,
                  revision.localRevision
                    < metadata.nextLocalRevision,
                  revision.digestVersion
                    == RecordDigestV1.version,
                  revision.committedAt == record.updatedAt,
                  revision.digestHex
                    == (try RecordDigestV1.sha256Hex(
                        recordType:
                            ContentFavoriteContract.recordType,
                        recordID: record.id,
                        fields:
                            try ContentFavoriteDigestV1.record(record)
                    )),
                  favoriteReceiptIDs.contains(
                    record.lastOperationID
                  ),
                  let receipt = receiptSet
                    .receiptsByOperationID[
                        record.lastOperationID
                    ],
                  receipt.resultRecordType
                    == ContentFavoriteContract.recordType,
                  receipt.resultRecordID == record.id,
                  receipt.committedAt == record.updatedAt,
                  let receiptRevision = receiptSet
                    .revisionsByOperationID[
                        record.lastOperationID
                    ],
                  receiptRevision.localRevision
                    == revision.localRevision,
                  receiptRevision.committedAt
                    == revision.committedAt else {
                throw failure
            }
            return snapshot(record, revision: revision)
        }

        guard favoriteReceipts.allSatisfy({
            recordsByID[$0.resultRecordID] != nil
        }) else {
            throw failure
        }
        return snapshots.sorted { $0.contentID < $1.contentID }
    }

    static func snapshot(
        contentID: String,
        in context: ModelContext,
        failure: AppDataFailure = .corruptionSuspected
    ) throws -> ContentFavoriteSnapshot? {
        try snapshots(in: context, failure: failure).first {
            $0.contentID == contentID
        }
    }

    private static func snapshot(
        _ record: ContentFavoriteRecord,
        revision: RecordRevision
    ) -> ContentFavoriteSnapshot {
        ContentFavoriteSnapshot(
            id: record.id,
            contentID: record.contentID,
            contentVersion: record.contentVersion,
            cardDigest: record.cardDigest,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            removedAt: record.removedAt,
            lastOperationID: record.lastOperationID,
            localRevision: revision.localRevision,
            digestHex: revision.digestHex
        )
    }
}
