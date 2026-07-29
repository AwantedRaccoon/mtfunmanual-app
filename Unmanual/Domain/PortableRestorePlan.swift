import CryptoKit
import Foundation

enum PortableImportMode: String, Codable, CaseIterable, Sendable {
    case merge
    case restore
    case replace
}

enum PortableImportConflictKind: String, Codable, Equatable, Sendable {
    case sameRevisionDifferentDigest
    case divergentRevision
    case crossDatasetIdentityCollision
    case missingLocalAmbiguous
    case terminalDeletion
    case missingRelationship
}

struct PortableImportConflict: Codable, Equatable, Sendable {
    let recordKey: String
    let kind: PortableImportConflictKind
}

struct PortableImportPlan: Codable, Equatable, Sendable {
    let mode: PortableImportMode
    let packageRootDigest: String
    let localStateDigest: String
    let incomingDatasetID: UUID
    let localDatasetID: UUID
    let noOpRecordKeys: [String]
    let acceptedRecordKeys: [String]
    let conflicts: [PortableImportConflict]
    let attachmentCount: Int
    let tokenSHA256: String

    var canConfirm: Bool {
        mode != .merge && conflicts.isEmpty
    }
}

enum PortableImportPlanError: Error, Equatable {
    case invalidDigest
    case invalidMode
    case conflictResolutionRequired
    case stalePlan
}

enum PortableImportPlanner {
    static func makePlan(
        mode: PortableImportMode,
        packageRootDigest: String,
        localStateDigest: String,
        incoming: PortableDataV2Document,
        local: PortableDataV2Document,
        localIsRestoreEligible: Bool = false,
        terminalRecordKeys: Set<String> = [],
        acceptedDifferentDatasetRecordKeys: Set<String> = []
    ) throws -> PortableImportPlan {
        guard isSHA256(packageRootDigest),
              isSHA256(localStateDigest) else {
            throw PortableImportPlanError.invalidDigest
        }
        let incomingByKey = Dictionary(
            uniqueKeysWithValues: incoming.payload.records.map {
                ($0.recordKey, $0)
            }
        )
        let localByKey = Dictionary(
            uniqueKeysWithValues: local.payload.records.map {
                ($0.recordKey, $0)
            }
        )

        var noOp: [String] = []
        var accepted: [String] = []
        var conflicts: [PortableImportConflict] = []

        switch mode {
        case .restore:
            guard localIsRestoreEligible else {
                throw PortableImportPlanError.invalidMode
            }
            accepted = incomingByKey.keys.sorted()
        case .replace:
            accepted = incomingByKey.keys.sorted()
        case .merge:
            for key in incomingByKey.keys.sorted() {
                guard let incomingRecord = incomingByKey[key] else {
                    continue
                }
                if terminalRecordKeys.contains(key) {
                    conflicts.append(
                        PortableImportConflict(
                            recordKey: key,
                            kind: .terminalDeletion
                        )
                    )
                    continue
                }
                guard let localRecord = localByKey[key] else {
                    if incoming.payload.datasetID
                        == local.payload.datasetID {
                        conflicts.append(
                            PortableImportConflict(
                                recordKey: key,
                                kind: .missingLocalAmbiguous
                            )
                        )
                    } else if acceptedDifferentDatasetRecordKeys
                        .contains(key) {
                        accepted.append(key)
                    } else {
                        conflicts.append(
                            PortableImportConflict(
                                recordKey: key,
                                kind: .missingLocalAmbiguous
                            )
                        )
                    }
                    continue
                }
                if incomingRecord.localRevision
                        == localRecord.localRevision {
                    if incomingRecord.digestHex
                        == localRecord.digestHex {
                        noOp.append(key)
                    } else {
                        conflicts.append(
                            PortableImportConflict(
                                recordKey: key,
                                kind: .sameRevisionDifferentDigest
                            )
                        )
                    }
                    continue
                }
                if incoming.payload.datasetID
                    != local.payload.datasetID {
                    conflicts.append(
                        PortableImportConflict(
                            recordKey: key,
                            kind: .crossDatasetIdentityCollision
                        )
                    )
                } else if incomingRecord.digestHex
                    == localRecord.digestHex {
                    noOp.append(key)
                } else {
                    conflicts.append(
                        PortableImportConflict(
                            recordKey: key,
                            kind: .divergentRevision
                        )
                    )
                }
            }
        }

        let unsigned = PortableImportPlan(
            mode: mode,
            packageRootDigest: packageRootDigest,
            localStateDigest: localStateDigest,
            incomingDatasetID: incoming.payload.datasetID,
            localDatasetID: local.payload.datasetID,
            noOpRecordKeys: noOp,
            acceptedRecordKeys: accepted,
            conflicts: conflicts,
            attachmentCount:
                incoming.payload.activeAttachments.count,
            tokenSHA256: ""
        )
        return PortableImportPlan(
            mode: unsigned.mode,
            packageRootDigest: unsigned.packageRootDigest,
            localStateDigest: unsigned.localStateDigest,
            incomingDatasetID: unsigned.incomingDatasetID,
            localDatasetID: unsigned.localDatasetID,
            noOpRecordKeys: unsigned.noOpRecordKeys,
            acceptedRecordKeys: unsigned.acceptedRecordKeys,
            conflicts: unsigned.conflicts,
            attachmentCount: unsigned.attachmentCount,
            tokenSHA256: try tokenDigest(unsigned)
        )
    }

    static func validateConfirmation(
        _ plan: PortableImportPlan,
        packageRootDigest: String,
        localStateDigest: String
    ) throws {
        guard plan.conflicts.isEmpty else {
            throw PortableImportPlanError.conflictResolutionRequired
        }
        guard plan.mode != .merge else {
            throw PortableImportPlanError.invalidMode
        }
        guard plan.packageRootDigest == packageRootDigest,
              plan.localStateDigest == localStateDigest else {
            throw PortableImportPlanError.stalePlan
        }
        let unsigned = PortableImportPlan(
            mode: plan.mode,
            packageRootDigest: plan.packageRootDigest,
            localStateDigest: plan.localStateDigest,
            incomingDatasetID: plan.incomingDatasetID,
            localDatasetID: plan.localDatasetID,
            noOpRecordKeys: plan.noOpRecordKeys,
            acceptedRecordKeys: plan.acceptedRecordKeys,
            conflicts: plan.conflicts,
            attachmentCount: plan.attachmentCount,
            tokenSHA256: ""
        )
        guard try tokenDigest(unsigned) == plan.tokenSHA256 else {
            throw PortableImportPlanError.stalePlan
        }
    }

    private static func tokenDigest(
        _ value: PortableImportPlan
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0)
                    || (97...102).contains($0)
            }
    }
}
