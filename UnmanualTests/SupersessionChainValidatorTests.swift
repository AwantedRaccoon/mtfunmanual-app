import XCTest
@testable import Unmanual

final class SupersessionChainValidatorTests: XCTestCase {
    func testAcceptsOneConnectedAppendOnlyChain() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertTrue(
            SupersessionChainValidator.formsSingleChain([
                SupersessionLink(id: first, predecessorID: nil),
                SupersessionLink(id: second, predecessorID: first),
                SupersessionLink(id: third, predecessorID: second)
            ])
        )
    }

    func testRejectsDisconnectedCycleEvenWhenAnotherComponentHasOneLeaf() {
        let root = UUID()
        let leaf = UUID()
        let cycleA = UUID()
        let cycleB = UUID()

        XCTAssertFalse(
            SupersessionChainValidator.formsSingleChain([
                SupersessionLink(id: root, predecessorID: nil),
                SupersessionLink(id: leaf, predecessorID: root),
                SupersessionLink(id: cycleA, predecessorID: cycleB),
                SupersessionLink(id: cycleB, predecessorID: cycleA)
            ])
        )
    }

    func testRejectsBranchesAndUnknownPredecessors() {
        let root = UUID()

        XCTAssertFalse(
            SupersessionChainValidator.formsSingleChain([
                SupersessionLink(id: root, predecessorID: nil),
                SupersessionLink(id: UUID(), predecessorID: root),
                SupersessionLink(id: UUID(), predecessorID: root)
            ])
        )
        XCTAssertFalse(
            SupersessionChainValidator.formsSingleChain([
                SupersessionLink(id: root, predecessorID: UUID())
            ])
        )
    }
}
