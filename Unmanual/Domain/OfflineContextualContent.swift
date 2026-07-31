import Foundation

enum OfflineContextualContentVersionContract {
    static let supportedContentVersion =
        "offline-contextual-content-candidate.1"

    static func isSupported(_ value: String) -> Bool {
        value == supportedContentVersion
    }

    static func releaseStateMatchesPack(
        releaseStateVersion: String,
        packVersion: String
    ) -> Bool {
        isSupported(releaseStateVersion)
            && isSupported(packVersion)
            && releaseStateVersion == packVersion
    }
}

struct OfflineContextualContentPack: Codable, Equatable, Sendable {
    let manifest: OfflineContextualContentManifest
    let sources: [OfflineContextualContentSource]
    let cards: [OfflineContextualContentCard]
    let scenarioAnchors: [OfflineContextualContentScenarioAnchor]
    let attribution: OfflineContextualContentAttribution
}

struct OfflineContextualContentManifest: Codable, Equatable, Sendable {
    let schemaVersion: String
    let contentVersion: String
    let locale: String
    let generatedAt: String
    let retrievedAt: String
    let expiresAt: String
    let sourceCommit: String
    let contentDigest: String
    let sourceCount: Int
    let cardCount: Int
    let scenarioAnchorCount: Int
    let review: OfflineContextualContentReview
    let classificationStatus: OfflineContextualContentClassificationStatus
}

struct OfflineContextualContentReview: Codable, Equatable, Sendable {
    let status: OfflineContextualContentReviewStatus
    let ownerRole: String
    let contentReviewerDisplayName: String?
    let medicalReviewerDisplayName: String?
    let completedAt: String?
    let scope: String
}

enum OfflineContextualContentReviewStatus:
    String, Codable, CaseIterable, Sendable {
    case candidate
    case approved
    case rejected
}

enum OfflineContextualContentClassificationStatus:
    String, Codable, CaseIterable, Sendable {
    case pending
    case resolved
}

struct OfflineContextualContentSource:
    Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let rightsHolder: String
    let title: String
    let versionOrPublishedAt: String
    let retrievedAt: String
    let expiresAt: String
    let sourceStatus: OfflineContextualContentSourceStatus
    let url: String
    let licenseIdentifier: String
    let licenseURL: String?
    let distributionMode: OfflineContextualContentDistributionMode
    let applicableRegions: [String]
    let applicablePopulations: [String]
    let boundary: String
}

enum OfflineContextualContentSourceStatus:
    String, Codable, CaseIterable, Hashable, Sendable {
    case current
    case knownUnavailable
}

enum OfflineContextualContentDistributionMode:
    String, Codable, CaseIterable, Hashable, Sendable {
    case linkOnly
    case redistributable
}

struct OfflineContextualContentCard:
    Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let applicabilityBoundary: String
    let contentType: OfflineContextualContentType
    let category: OfflineContextualContentCategory
    let aliases: [String]
    let sourceIDs: [String]
    let displayOrder: Int
    let contentVersion: String
    let cardDigest: String
    let retrievedAt: String
    let expiresAt: String
    let originalURL: String
    let provenance: OfflineContextualContentProvenance
}

enum OfflineContextualContentType:
    String, Codable, CaseIterable, Hashable, Sendable {
    case questionAnswer
    case recordingGuide
    case visitChecklist

    var displayTitle: String {
        switch self {
        case .questionAnswer:
            "问题摘要"
        case .recordingGuide:
            "记录说明"
        case .visitChecklist:
            "就诊清单"
        }
    }
}

enum OfflineContextualContentCategory:
    String, Codable, CaseIterable, Hashable, Sendable {
    case identityAndTerms
    case hrtAndCare
    case recordsAndVisits
    case voiceAndPresentation
    case surgery
    case sexualHealth
    case mentalWellbeing
    case privacyAndRelationships
    case legalAndDocuments
    case preventiveCare

    var displayTitle: String {
        switch self {
        case .identityAndTerms:
            "身份与术语"
        case .hrtAndCare:
            "HRT 与照护"
        case .recordsAndVisits:
            "记录与就诊"
        case .voiceAndPresentation:
            "声音与表达"
        case .surgery:
            "手术"
        case .sexualHealth:
            "性健康"
        case .mentalWellbeing:
            "心理与支持"
        case .privacyAndRelationships:
            "隐私与关系"
        case .legalAndDocuments:
            "法律与证件"
        case .preventiveCare:
            "预防照护"
        }
    }
}

struct OfflineContextualContentProvenance:
    Codable, Equatable, Hashable, Sendable {
    let sourceRepository: String
    let sourceCommit: String
    let sourcePath: String
    let sourceFileSHA256: String
    let adaptationStatus: OfflineContextualContentAdaptationStatus
    let modificationNote: String
}

enum OfflineContextualContentAdaptationStatus:
    String, Codable, CaseIterable, Hashable, Sendable {
    case unmodified
    case modified
}

struct OfflineContextualContentScenarioAnchor:
    Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let scenario: OfflineContextualContentScenario
    let purpose: String
    let displayOrder: Int
    let cardID: String
}

enum OfflineContextualContentScenario:
    String, Codable, CaseIterable, Hashable, Sendable {
    case regimenField
    case labRecording
    case regimenAnalysisSource
    case visitPreparation
    case timelineRecord
    case pocketAppendix
}

struct OfflineContextualContentAttribution:
    Codable, Equatable, Sendable {
    let sourceRepository: String
    let sourceCommit: String
    let creator: String
    let licenseIdentifier: String
    let licenseURL: String
    let adaptationStatus: OfflineContextualContentAdaptationStatus
    let modificationNote: String
    let shareAlikeStatement: String
}

enum OfflineContextualContentExposure: Equatable, Sendable {
    case candidate
    case release
}

enum OfflineContextualContentCardStatus: Equatable, Sendable {
    case current
    case stale
    case sourceUnavailable
    case unavailable
}

enum OfflineContextualContentSourceLinkStatus:
    Equatable, Sendable {
    case current
    case needsReverification
    case unavailable

    static func resolve(
        _ source: OfflineContextualContentSource,
        statusDate: Date
    ) -> Self {
        guard source.sourceStatus == .current else {
            return .unavailable
        }
        guard let expiry = UTCDateParser.date(
            source.expiresAt
        ) else {
            return .unavailable
        }
        return UTCDateParser.startOfDay(statusDate) > expiry
            ? .needsReverification
            : .current
    }
}

struct OfflineContextualContentCardSnapshot:
    Identifiable, Equatable, Sendable {
    let card: OfflineContextualContentCard
    let sources: [OfflineContextualContentSource]
    let status: OfflineContextualContentCardStatus

    var id: String { card.id }
    var title: String { card.title }
    var summary: String { card.summary }
    var category: OfflineContextualContentCategory { card.category }
    var contentType: OfflineContextualContentType { card.contentType }
    var displayOrder: Int { card.displayOrder }
}

enum OfflineContextualContentQueryIssue: Equatable, Sendable {
    case tooLong
    case tooManyTokens
}

struct OfflineContextualContentSearchResult: Equatable, Sendable {
    let cards: [OfflineContextualContentCardSnapshot]
    let issue: OfflineContextualContentQueryIssue?
}

struct OfflineContextualContentReleaseState:
    Codable, Equatable, Sendable {
    let schemaVersion: String
    let status: OfflineContextualContentReleaseStatus
    let contentVersion: String
    let message: String
    let candidateResourceExcluded: Bool
    let contentReviewApproved: Bool
    let medicalReviewApproved: Bool
    let classificationResolved: Bool
    let approvedResourceName: String?
}

enum OfflineContextualContentReleaseStatus:
    String, Codable, Equatable, Sendable {
    case pendingHumanReviewAndClassification
    case rejected
    case approved
}

enum OfflineContextualContentReleaseStateLoadState:
    Equatable, Sendable {
    case available(OfflineContextualContentReleaseState)
    case unavailable([OfflineContextualContentValidationIssue])
}
