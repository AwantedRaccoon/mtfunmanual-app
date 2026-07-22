import Foundation

enum RegimenEditState: String, Codable, Equatable, Sendable {
    case draft
    case sealed
}

struct RegimenTimelineVersion: Identifiable, Equatable, Sendable {
    let id: UUID
    let start: CivilDateFact
    let end: CivilDateFact?
    let editState: RegimenEditState
    let requiresReview: Bool

    func contains(_ date: CivilDateFact) -> Bool {
        start <= date && end.map { date < $0 } ?? true
    }
}

struct RegimenTimelineProjection: Equatable, Sendable {
    let current: RegimenTimelineVersion?
    let upcoming: [RegimenTimelineVersion]
    let history: [RegimenTimelineVersion]
    let isAmbiguous: Bool
}

enum RegimenTimelineResolver {
    static func normalizedEligibleTimeline(
        _ versions: [RegimenTimelineVersion]
    ) -> [RegimenTimelineVersion]? {
        let eligible = normalized(versions
            .filter { $0.editState == .sealed && !$0.requiresReview }
            .sorted(by: stableOrder))
        for pair in zip(eligible, eligible.dropFirst()) {
            guard pair.0.start < pair.1.start,
                  pair.0.end.map({ $0 <= pair.1.start }) ?? true else {
                return nil
            }
        }
        return eligible
    }

    static func project(
        _ versions: [RegimenTimelineVersion],
        asOf date: CivilDateFact
    ) -> RegimenTimelineProjection {
        let eligible = normalized(versions
            .filter { $0.editState == .sealed && !$0.requiresReview }
            .sorted(by: stableOrder))
        let candidates = eligible.filter { $0.contains(date) }
        return RegimenTimelineProjection(
            current: candidates.count == 1 ? candidates.first : nil,
            upcoming: eligible.filter { date < $0.start },
            history: eligible.filter { $0.end.map { $0 <= date } ?? false },
            isAmbiguous: candidates.count > 1
        )
    }

    static func resolveAssociation(
        _ versions: [RegimenTimelineVersion],
        on date: CivilDateFact
    ) -> UUID? {
        let candidates = normalized(versions
            .filter { $0.editState == .sealed && !$0.requiresReview }
            .sorted(by: stableOrder))
            .filter {
            $0.editState == .sealed && !$0.requiresReview && $0.contains(date)
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    private static func stableOrder(
        _ lhs: RegimenTimelineVersion,
        _ rhs: RegimenTimelineVersion
    ) -> Bool {
        lhs.start != rhs.start
            ? lhs.start < rhs.start
            : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func normalized(
        _ versions: [RegimenTimelineVersion]
    ) -> [RegimenTimelineVersion] {
        versions.enumerated().map { index, version in
            guard version.end == nil,
                  versions.indices.contains(index + 1),
                  version.start < versions[index + 1].start else {
                return version
            }
            return RegimenTimelineVersion(
                id: version.id,
                start: version.start,
                end: versions[index + 1].start,
                editState: version.editState,
                requiresReview: version.requiresReview
            )
        }
    }
}
