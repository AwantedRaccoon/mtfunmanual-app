import Foundation

struct SupersessionLink: Equatable, Sendable {
    let id: UUID
    let predecessorID: UUID?
}

enum SupersessionChainValidator {
    static func formsSingleChain(_ links: [SupersessionLink]) -> Bool {
        guard !links.isEmpty else { return true }

        let groupsByID = Dictionary(grouping: links, by: \.id)
        guard groupsByID.values.allSatisfy({ $0.count == 1 }) else { return false }
        let linkByID = groupsByID.compactMapValues(\.first)
        guard linkByID.count == links.count,
              links.allSatisfy({ link in
                  guard let predecessorID = link.predecessorID else { return true }
                  return predecessorID != link.id && linkByID[predecessorID] != nil
              }) else {
            return false
        }

        let successorCounts = Dictionary(
            grouping: links.compactMap(\.predecessorID),
            by: { $0 }
        )
        guard successorCounts.values.allSatisfy({ $0.count == 1 }) else {
            return false
        }

        let supersededIDs = Set(links.compactMap(\.predecessorID))
        let leaves = links.filter { !supersededIDs.contains($0.id) }
        guard let leaf = leaves.only else { return false }

        var visited: Set<UUID> = []
        var cursor: SupersessionLink? = leaf
        while let current = cursor {
            guard visited.insert(current.id).inserted else { return false }
            cursor = current.predecessorID.flatMap { linkByID[$0] }
        }
        return visited.count == links.count
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
