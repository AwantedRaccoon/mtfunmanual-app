import XCTest
@testable import Unmanual

final class Batch1PerformanceContractTests: XCTestCase {
    private enum ExpectedFailure: Error {
        case invalidConfiguration
    }

    func testReleaseBuildExcludesUnreviewedMedicationCatalog() {
#if DEBUG
        XCTFail("This contract test must run in the Release-configured performance scheme")
#else
        XCTAssertTrue(MedicationCatalog.entries.isEmpty)
        XCTAssertTrue(MedicationCatalog.search("estradiol").isEmpty)
#endif
    }

    func testNearestRankP95UsesNineteenthValueForTwentySamples() throws {
        let samples = Array(1...20).reversed().map(Int64.init)

        let result = try Batch1PerformanceStatistics.nearestRankP95(samples)

        XCTAssertEqual(result.rank, 19)
        XCTAssertEqual(result.valueNanoseconds, 19)
    }

    func testNearestRankP95RejectsIncompleteEvidence() {
        XCTAssertThrowsError(
            try Batch1PerformanceStatistics.nearestRankP95(Array(repeating: 1, count: 19))
        )
    }

    func testBatch1ContractUsesProductionBoundariesWithoutInventingThresholds() {
        let contract = Batch1PerformanceContract.v1

        XCTAssertEqual(contract.warmupCount, 1)
        XCTAssertEqual(contract.sampleCount, 20)
        XCTAssertEqual(
            contract.operations,
            [.migrationOpen, .todaySnapshot, .archiveSnapshot, .quickJourneyWrite]
        )
        XCTAssertTrue(contract.thresholdNanoseconds.isEmpty)
    }

    func testFiveYearExpectedCountsIncludeV5PersonalTimelineFacts() {
        XCTAssertEqual(Batch1FixtureCounts.legacySourceExpected.revisions, 8_585)
        XCTAssertEqual(Batch1FixtureCounts.legacySourceExpected.legacyFacts, 8_585)
        XCTAssertEqual(Batch1V3CompanionCounts.expected.facts, 9_727)
        XCTAssertEqual(Batch1V5PersonalTimelineCounts.expected.canonicalFacts, 4_800)
        XCTAssertEqual(Batch1FixtureCounts.expected.revisions, 23_113)
        XCTAssertEqual(Batch1V5FoundationContract.activatedFactCount, 23_113)
        XCTAssertEqual(Batch1V5FoundationContract.activatedRevisionCount, 23_113)
        XCTAssertEqual(Batch1V5FoundationContract.nextLocalRevision, 23_114)
        XCTAssertEqual(Batch1V5FoundationContract.postQuickWriteRevisionCount, 23_115)
        XCTAssertEqual(Batch1V5FoundationContract.postQuickWriteNextLocalRevision, 23_115)
    }

    @MainActor
    func testOneFiveYearIterationExercisesV5FoundationAndQuickWriteContracts() async throws {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        var applicationSupportValues = URLResourceValues()
        applicationSupportValues.isExcludedFromBackup = false
        var mutableApplicationSupport = applicationSupport
        try mutableApplicationSupport.setResourceValues(applicationSupportValues)
        let root = applicationSupport
            .appending(path: "UnmanualBatch1Correctness", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let fixture = try Batch1FiveYearFixtureBuilder.makeSnapshot(
            at: root.appending(path: "Fixture", directoryHint: .isDirectory)
        )
        let sample = try await Batch1PerformanceWorker().runIteration(
            fixture: fixture,
            rootURL: root.appending(path: "Iteration", directoryHint: .isDirectory),
            sampleIndex: 0
        )

        XCTAssertTrue(sample.cleanupSucceeded)
        try fixture.verifyUnchanged()
    }

    func testRunModeRequiresExplicitPlatformMatchedOptIn() throws {
        XCTAssertEqual(
            try Batch1PerformanceRunMode.resolve(environment: [:], isSimulator: true),
            .disabled
        )
        XCTAssertEqual(
            try Batch1PerformanceRunMode.resolve(
                environment: ["UNMANUAL_BATCH1_PERF_MODE": "simulator-preflight"],
                isSimulator: true
            ),
            .simulatorPreflight
        )
        XCTAssertThrowsError(
            try Batch1PerformanceRunMode.resolve(
                environment: ["UNMANUAL_BATCH1_PERF_MODE": "physical-characterization"],
                isSimulator: true
            )
        )
        XCTAssertThrowsError(
            try Batch1PerformanceRunMode.resolve(
                environment: ["UNMANUAL_BATCH1_PERF_MODE": "simulator-preflight"],
                isSimulator: false
            )
        )
    }

    @MainActor
    func testInvalidRecorderSerializesEvidenceBeforeValidatedEnvironmentExists() throws {
        let recorder = Batch1PerformanceRecorder(
            contract: .v1,
            invocation: Batch1PerformanceInvocation(
                requestedMode: "physical-characterization",
                platform: "simulator",
                deviceModelIdentifier: "iPhone12,8",
                operatingSystem: "test-os",
                appVersion: "1.0",
                appBuild: "1"
            )
        )

        recorder.markInvalid(ExpectedFailure.invalidConfiguration)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recorder.jsonData()) as? [String: Any]
        )
        let invocation = try XCTUnwrap(object["invocation"] as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "invalid")
        XCTAssertNil(object["environment"])
        XCTAssertEqual(invocation["requestedMode"] as? String, "physical-characterization")
        XCTAssertEqual(invocation["platform"] as? String, "simulator")
        XCTAssertNotNil(object["failure"] as? String)
        XCTAssertTrue(
            String(decoding: recorder.csvData(), as: UTF8.self).hasPrefix("sampleIndex,")
        )
    }

    @MainActor
    func testRootCleanupFailureIsPreservedInInvalidEvidence() throws {
        let recorder = Batch1PerformanceRecorder(
            contract: .v1,
            invocation: Batch1PerformanceInvocation(
                requestedMode: "simulator-preflight",
                platform: "simulator",
                deviceModelIdentifier: "iPhone12,8",
                operatingSystem: "test-os",
                appVersion: "1.0",
                appBuild: "1"
            )
        )

        recorder.markRootCleanupFailed(ExpectedFailure.invalidConfiguration)
        recorder.markInvalid(ExpectedFailure.invalidConfiguration)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recorder.jsonData()) as? [String: Any]
        )

        XCTAssertEqual(object["status"] as? String, "invalid")
        XCTAssertEqual(object["rootCleanupSucceeded"] as? Bool, false)
        XCTAssertNotNil(object["rootCleanupFailure"] as? String)
    }
}
