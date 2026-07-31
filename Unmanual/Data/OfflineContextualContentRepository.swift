import Foundation

enum OfflineContextualContentUnavailableReason: Equatable, Sendable {
    case missingResource
    case pendingHumanReviewAndClassification
    case rejectedByHumanReview
    case invalidContent([OfflineContextualContentValidationIssue])
    case unreadableContent(String)
}

struct OfflineContextualContentValidationIssue:
    Error, Equatable, Sendable {
    let code: String
    let path: String
    let message: String
}

enum OfflineContextualContentLoadState: Equatable, Sendable {
    case available(OfflineContextualContentSnapshot)
    case unavailable(OfflineContextualContentUnavailableReason)

    var snapshot: OfflineContextualContentSnapshot? {
        guard case let .available(snapshot) = self else { return nil }
        return snapshot
    }
}

struct OfflineContextualContentSnapshot: Equatable, Sendable {
    let manifest: OfflineContextualContentManifest
    let sources: [OfflineContextualContentSource]
    let cards: [OfflineContextualContentCardSnapshot]
    let scenarioAnchors: [OfflineContextualContentScenarioAnchor]
    let attribution: OfflineContextualContentAttribution
    let statusDate: Date

    func cards(
        for scenario: OfflineContextualContentScenario
    ) -> [OfflineContextualContentCardSnapshot] {
        let cardByID = Dictionary(
            uniqueKeysWithValues: cards.map { ($0.id, $0) }
        )
        return scenarioAnchors
            .filter { $0.scenario == scenario }
            .sorted {
                ($0.displayOrder, $0.id) < ($1.displayOrder, $1.id)
            }
            .compactMap { cardByID[$0.cardID] }
    }

    func search(
        query: String,
        category: OfflineContextualContentCategory?,
        favoriteIDs: Set<String>,
        favoritesOnly: Bool
    ) -> OfflineContextualContentSearchResult {
        OfflineContextualContentSearch.search(
            cards: cards,
            query: query,
            category: category,
            favoriteIDs: favoriteIDs,
            favoritesOnly: favoritesOnly
        )
    }
}

enum OfflineContextualContentSearch {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ],
                locale: locale
            )
            .precomposedStringWithCanonicalMapping
    }

    static func search(
        cards: [OfflineContextualContentCardSnapshot],
        query: String,
        category: OfflineContextualContentCategory?,
        favoriteIDs: Set<String>,
        favoritesOnly: Bool
    ) -> OfflineContextualContentSearchResult {
        guard query.unicodeScalars.count <=
                OfflineContextualContentLimits.maximumQueryScalars else {
            return OfflineContextualContentSearchResult(
                cards: [],
                issue: .tooLong
            )
        }
        let normalized = normalize(query)
        guard normalized.unicodeScalars.count <=
                OfflineContextualContentLimits.maximumQueryScalars else {
            return OfflineContextualContentSearchResult(
                cards: [],
                issue: .tooLong
            )
        }
        let tokens = normalized.components(
            separatedBy: .whitespacesAndNewlines
        ).filter { !$0.isEmpty }
        guard tokens.count <=
                OfflineContextualContentLimits.maximumQueryTokens else {
            return OfflineContextualContentSearchResult(
                cards: [],
                issue: .tooManyTokens
            )
        }
        let fullQuery = tokens.joined(separator: " ")
        let eligible = cards.filter {
            (category == nil || $0.category == category)
                && (!favoritesOnly || favoriteIDs.contains($0.id))
        }
        guard !tokens.isEmpty else {
            return OfflineContextualContentSearchResult(
                cards: eligible
                    .sorted(by: stableDisplayOrder)
                    .prefix(OfflineContextualContentLimits.maximumCards)
                    .map { $0 },
                issue: nil
            )
        }

        let scored = eligible.compactMap { snapshot -> ScoredCard? in
            let fields = SearchFields(snapshot.card)
            let tokenRanks = tokens.compactMap { fields.rank(for: $0) }
            guard tokenRanks.count == tokens.count else {
                return nil
            }
            return ScoredCard(
                snapshot: snapshot,
                fullQueryRank: fields.rank(for: fullQuery) ?? 8,
                tokenRanks: tokenRanks.sorted(by: >)
            )
        }
        let results = scored.sorted(by: precedes)
            .prefix(OfflineContextualContentLimits.maximumCards)
            .map(\.snapshot)
        return OfflineContextualContentSearchResult(
            cards: results,
            issue: nil
        )
    }

    private struct SearchFields {
        let title: String
        let aliases: [String]
        let category: String
        let contentType: String
        let summary: String

        init(_ card: OfflineContextualContentCard) {
            title = normalize(card.title)
            aliases = card.aliases.map(normalize)
            category = normalize(
                card.category.displayTitle
                    + " "
                    + card.category.rawValue
            )
            contentType = normalize(
                card.contentType.displayTitle
                    + " "
                    + card.contentType.rawValue
            )
            summary = normalize(card.summary)
        }

        func rank(for query: String) -> Int? {
            if title == query {
                return 1
            }
            if title.hasPrefix(query) {
                return 2
            }
            if title.contains(query) {
                return 3
            }
            if aliases.contains(query) {
                return 4
            }
            if aliases.contains(where: { $0.contains(query) }) {
                return 5
            }
            if category.contains(query) || contentType.contains(query) {
                return 6
            }
            if summary.contains(query) {
                return 7
            }
            return nil
        }
    }

    private struct ScoredCard {
        let snapshot: OfflineContextualContentCardSnapshot
        let fullQueryRank: Int
        let tokenRanks: [Int]
    }

    private static func precedes(
        _ lhs: ScoredCard,
        _ rhs: ScoredCard
    ) -> Bool {
        if lhs.fullQueryRank != rhs.fullQueryRank {
            return lhs.fullQueryRank < rhs.fullQueryRank
        }
        if lhs.tokenRanks != rhs.tokenRanks {
            return lexicographicallyPrecedes(
                lhs.tokenRanks,
                rhs.tokenRanks
            )
        }
        return stableDisplayOrder(lhs.snapshot, rhs.snapshot)
    }

    private static func lexicographicallyPrecedes(
        _ lhs: [Int],
        _ rhs: [Int]
    ) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right
        }
        return lhs.count < rhs.count
    }

    private static func stableDisplayOrder(
        _ lhs: OfflineContextualContentCardSnapshot,
        _ rhs: OfflineContextualContentCardSnapshot
    ) -> Bool {
        if lhs.displayOrder != rhs.displayOrder {
            return lhs.displayOrder < rhs.displayOrder
        }
        return lhs.id < rhs.id
    }
}

enum OfflineContextualContentBundleCandidatePolicy {
    static var isEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}

struct OfflineContextualContentRepository: Sendable {
    static let candidateResourceName =
        "offline-contextual-content-candidate-v1"
    static let releaseStateResourceName =
        "offline-contextual-content-release-state-v1"

    let state: OfflineContextualContentLoadState

    init(
        bundle: Bundle,
        exposure: OfflineContextualContentExposure,
        statusDate: Date
    ) {
        self.init(
            bundle: bundle,
            exposure: exposure,
            statusDate: statusDate,
            releaseValidationDate: statusDate
        )
    }

    init(
        runtimeBundle bundle: Bundle,
        exposure: OfflineContextualContentExposure,
        statusDate: Date
    ) {
        self.init(
            bundle: bundle,
            exposure: exposure,
            statusDate: statusDate,
            releaseValidationDate: nil
        )
    }

    private init(
        bundle: Bundle,
        exposure: OfflineContextualContentExposure,
        statusDate: Date,
        releaseValidationDate: Date?
    ) {
        switch exposure {
        case .candidate:
#if DEBUG
            guard let url = bundle.url(
                forResource: Self.candidateResourceName,
                withExtension: "json"
            ) else {
                self.init(state: .unavailable(.missingResource))
                return
            }
            do {
                self.init(
                    data: try Data(
                        contentsOf: url,
                        options: [.mappedIfSafe]
                    ),
                    exposure: .candidate,
                    statusDate: statusDate
                )
            } catch {
                self.init(
                    state: .unavailable(
                        .unreadableContent("resource")
                    )
                )
            }
#else
            self.init(
                state: .unavailable(
                    .pendingHumanReviewAndClassification
                )
            )
#endif
        case .release:
            guard let stateURL = bundle.url(
                forResource: Self.releaseStateResourceName,
                withExtension: "json"
            ) else {
                self.init(state: .unavailable(.missingResource))
                return
            }
            let releaseState: OfflineContextualContentReleaseState
            do {
                let data = try Data(
                    contentsOf: stateURL,
                    options: [.mappedIfSafe]
                )
                let repository =
                    OfflineContextualContentReleaseStateRepository(
                        data: data
                    )
                guard case let .available(value) = repository.state else {
                    self.init(
                        state: .unavailable(
                            .unreadableContent("release-state")
                        )
                    )
                    return
                }
                releaseState = value
            } catch {
                self.init(
                    state: .unavailable(
                        .unreadableContent("release-state")
                    )
                )
                return
            }

            switch releaseState.status {
            case .pendingHumanReviewAndClassification:
                self.init(
                    state: .unavailable(
                        .pendingHumanReviewAndClassification
                    )
                )
            case .rejected:
                self.init(
                    state: .unavailable(.rejectedByHumanReview)
                )
            case .approved:
                guard let resourceName =
                    releaseState.approvedResourceName,
                    let url = bundle.url(
                        forResource: resourceName,
                        withExtension: "json"
                    ) else {
                    self.init(state: .unavailable(.missingResource))
                    return
                }
                do {
                    let loaded = Self(
                        data: try Data(
                            contentsOf: url,
                            options: [.mappedIfSafe]
                        ),
                        exposure: .release,
                        validationDate:
                            releaseValidationDate,
                        statusDate: statusDate
                    )
                    guard case let .available(snapshot) = loaded.state else {
                        self.init(state: loaded.state)
                        return
                    }
                    guard OfflineContextualContentVersionContract
                        .releaseStateMatchesPack(
                            releaseStateVersion:
                                releaseState.contentVersion,
                            packVersion:
                                snapshot.manifest.contentVersion
                        ) else {
                        self.init(
                            state: .unavailable(
                                .invalidContent([
                                    OfflineContextualContentValidationIssue(
                                        code:
                                            "releaseState.contentVersion",
                                        path: "$.contentVersion",
                                        message:
                                            "release-state 未与正式内容包版本绑定。"
                                    )
                                ])
                            )
                        )
                        return
                    }
                    self.init(state: loaded.state)
                } catch {
                    self.init(
                        state: .unavailable(
                            .unreadableContent("resource")
                        )
                    )
                }
            }
        }
    }

    private init(state: OfflineContextualContentLoadState) {
        self.state = state
    }

    init(
        data: Data,
        exposure: OfflineContextualContentExposure,
        statusDate: Date
    ) {
        self.init(
            data: data,
            exposure: exposure,
            validationDate: statusDate,
            statusDate: statusDate
        )
    }

    private init(
        data: Data,
        exposure: OfflineContextualContentExposure,
        validationDate: Date?,
        statusDate: Date
    ) {
        do {
            let decoded = try OfflineContextualContentDecoder.decode(data)
            let exposureDate: Date
            switch exposure {
            case .candidate:
                exposureDate = statusDate
            case .release:
                exposureDate =
                    validationDate
                    ?? decoded.pack.manifest.review.completedAt
                        .flatMap(UTCDateParser.date)
                    ?? statusDate
            }
            let issues = OfflineContextualContentValidator.validate(
                decoded,
                exposure: exposure,
                statusDate: exposureDate
            )
            guard issues.isEmpty else {
                state = .unavailable(.invalidContent(issues))
                return
            }
            state = .available(
                Self.makeSnapshot(
                    from: decoded.pack,
                    statusDate: statusDate
                )
            )
        } catch let validationIssue
            as OfflineContextualContentValidationIssue {
            state = .unavailable(.invalidContent([validationIssue]))
        } catch {
            state = .unavailable(.unreadableContent("unexpected"))
        }
    }

    private static func makeSnapshot(
        from pack: OfflineContextualContentPack,
        statusDate: Date
    ) -> OfflineContextualContentSnapshot {
        let sourceByID = pack.sources.reduce(
            into: [String: OfflineContextualContentSource]()
        ) {
            $0[$1.id] = $1
        }
        let cards = pack.cards
            .map { card in
                let sources = card.sourceIDs.compactMap { sourceByID[$0] }
                return OfflineContextualContentCardSnapshot(
                    card: card,
                    sources: sources,
                    status: status(
                        for: card,
                        sources: sources,
                        statusDate: statusDate
                    )
                )
            }
            .sorted {
                ($0.displayOrder, $0.id) < ($1.displayOrder, $1.id)
            }

        return OfflineContextualContentSnapshot(
            manifest: pack.manifest,
            sources: pack.sources,
            cards: cards,
            scenarioAnchors: pack.scenarioAnchors,
            attribution: pack.attribution,
            statusDate: statusDate
        )
    }

    private static func status(
        for card: OfflineContextualContentCard,
        sources: [OfflineContextualContentSource],
        statusDate: Date
    ) -> OfflineContextualContentCardStatus {
        if sources.contains(where: {
            $0.sourceStatus == .knownUnavailable
        }) {
            return .sourceUnavailable
        }
        if isExpired(card.expiresAt, statusDate: statusDate)
            || sources.contains(where: {
                isExpired($0.expiresAt, statusDate: statusDate)
            }) {
            return .stale
        }
        return .current
    }

    private static func isExpired(
        _ value: String,
        statusDate: Date
    ) -> Bool {
        guard let expiry = UTCDateParser.date(value) else { return true }
        return UTCDateParser.startOfDay(statusDate) > expiry
    }
}

enum UTCDateParser {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    static func date(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9]
        guard bytes.count == 10,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              digitIndices.allSatisfy({
                  (0x30...0x39).contains(bytes[$0])
              }),
              let year = Int(
                  String(decoding: bytes[0..<4], as: UTF8.self)
              ),
              let month = Int(
                  String(decoding: bytes[5..<7], as: UTF8.self)
              ),
              let day = Int(
                  String(decoding: bytes[8..<10], as: UTF8.self)
              ),
              let date = calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day
                )
              ) else {
            return nil
        }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else {
            return nil
        }
        return date
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}
