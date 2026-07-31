import Foundation
import XCTest
@testable import Unmanual

final class OfflineContextualContentReleaseStateTests: XCTestCase {
    func testPendingStateLoadsWithExactFrozenTruthTable() throws {
        let repository = OfflineContextualContentReleaseStateRepository(
            data: Data(pendingJSON.utf8)
        )

        guard case let .available(state) = repository.state else {
            return XCTFail("合法 pending release-state 应可读取")
        }
        XCTAssertEqual(state.status, .pendingHumanReviewAndClassification)
        XCTAssertTrue(state.candidateResourceExcluded)
        XCTAssertNil(state.approvedResourceName)
    }

    func testReleaseStateRejectsDuplicateUnknownAndTruthTableMismatch() {
        assertInvalid(
            pendingJSON.replacingOccurrences(
                of: "\"schemaVersion\": \"1\",",
                with: """
                "schemaVersion": "1",
                  "\\u0073chemaVersion": "1",
                """
            ),
            code: "json.duplicateKey"
        )
        assertInvalid(
            pendingJSON.replacingOccurrences(
                of: "\"schemaVersion\": \"1\",",
                with: """
                "schemaVersion": "1",
                  "unexpected": false,
                """
            ),
            code: "shape.exactKeys"
        )
        assertInvalid(
            pendingJSON.replacingOccurrences(
                of: "\"contentReviewApproved\": false",
                with: "\"contentReviewApproved\": true"
            ),
            code: "releaseState.truthTable"
        )
        assertInvalid(
            pendingJSON.replacingOccurrences(
                of: "offline-contextual-content-candidate.1",
                with: "future-content.2"
            ),
            code: "releaseState.contentVersion"
        )
    }

    func testApprovedStateRequiresSafeReleaseBasename() {
        let approved = pendingJSON
            .replacingOccurrences(
                of: "pendingHumanReviewAndClassification",
                with: "approved"
            )
            .replacingOccurrences(
                of: "\"contentReviewApproved\": false",
                with: "\"contentReviewApproved\": true"
            )
            .replacingOccurrences(
                of: "\"medicalReviewApproved\": false",
                with: "\"medicalReviewApproved\": true"
            )
            .replacingOccurrences(
                of: "\"classificationResolved\": false",
                with: "\"classificationResolved\": true"
            )
            .replacingOccurrences(
                of: "\"approvedResourceName\": null",
                with: """
                "approvedResourceName": "offline-contextual-content-release-v1.0"
                """
            )
        let repository = OfflineContextualContentReleaseStateRepository(
            data: Data(approved.utf8)
        )
        guard case let .available(state) = repository.state else {
            return XCTFail("合法 approved basename 应可读取")
        }
        XCTAssertEqual(
            state.approvedResourceName,
            "offline-contextual-content-release-v1.0"
        )

        for invalid in [
            "../offline-contextual-content-release-v1",
            "offline-contextual-content-candidate-v1",
            "offline-contextual-content-release-V1",
            "offline-contextual-content-release-v1.json",
            "offline-contextual-content-release-v1/",
            "release-v1"
        ] {
            assertInvalid(
                approved.replacingOccurrences(
                    of: "offline-contextual-content-release-v1.0",
                    with: invalid
                ),
                code: "releaseState.resourceName"
            )
        }
    }

    private let pendingJSON = """
    {
      "schemaVersion": "1",
      "status": "pendingHumanReviewAndClassification",
      "contentVersion": "offline-contextual-content-candidate.1",
      "message": "等待真实人类内容、医疗与 App Review 分类复核。",
      "candidateResourceExcluded": true,
      "contentReviewApproved": false,
      "medicalReviewApproved": false,
      "classificationResolved": false,
      "approvedResourceName": null
    }
    """

    private func assertInvalid(
        _ json: String,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let repository = OfflineContextualContentReleaseStateRepository(
            data: Data(json.utf8)
        )
        guard case let .unavailable(issues) = repository.state else {
            return XCTFail(
                "release-state 应 fail closed",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            issues.contains { $0.code == code },
            "缺少 \(code)，实际为 \(issues)",
            file: file,
            line: line
        )
    }
}
