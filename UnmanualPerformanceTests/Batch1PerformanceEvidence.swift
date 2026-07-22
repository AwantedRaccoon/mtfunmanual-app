import Foundation

struct Batch1PerformanceInvocation: Codable, Equatable {
    let requestedMode: String
    let platform: String
    let deviceModelIdentifier: String
    let operatingSystem: String
    let appVersion: String
    let appBuild: String

    static func capture(
        environment: [String: String],
        isSimulator: Bool,
        processInfo: ProcessInfo
    ) -> Batch1PerformanceInvocation {
        Batch1PerformanceInvocation(
            requestedMode: environment["UNMANUAL_BATCH1_PERF_MODE"] ?? "disabled",
            platform: isSimulator ? "simulator" : "physical-device",
            deviceModelIdentifier: environment["SIMULATOR_MODEL_IDENTIFIER"]
                ?? Batch1PerformanceEnvironment.machineIdentifier(),
            operatingSystem: processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown"
        )
    }
}

struct Batch1PerformanceEnvironment: Codable, Equatable {
    enum EnvironmentError: Error, Equatable {
        case physicalCommitMustBeFullSHA
        case physicalTreeMustBeClean
        case unsupportedPhysicalDevice(String)
        case lowPowerModeEnabled
        case unacceptableThermalState(String)
    }

    let mode: Batch1PerformanceRunMode
    let evidenceScope: String
    let deviceModelIdentifier: String
    let operatingSystem: String
    let kernelRelease: String
    let appVersion: String
    let appBuild: String
    let gitCommit: String
    let treeState: String
    let configuration: String
    let optimization: String
    let testability: String
    let lowPowerModeEnabled: Bool
    let startingThermalState: String

    static func capture(
        mode: Batch1PerformanceRunMode,
        processInfo: ProcessInfo
    ) throws -> Batch1PerformanceEnvironment {
        let environment = processInfo.environment
        let deviceModel = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineIdentifier()
        let gitCommit = environment["UNMANUAL_PERF_GIT_COMMIT"] ?? "unknown"
        let treeState = environment["UNMANUAL_PERF_TREE_STATE"] ?? "unknown"
        let thermalState = thermalLabel(processInfo.thermalState)

        if mode == .physicalCharacterization {
            guard gitCommit.count == 40,
                  gitCommit.allSatisfy({ $0.isHexDigit }) else {
                throw EnvironmentError.physicalCommitMustBeFullSHA
            }
            guard treeState == "clean" else {
                throw EnvironmentError.physicalTreeMustBeClean
            }
            guard ["iPhone12,8", "iPhone11,8"].contains(deviceModel) else {
                throw EnvironmentError.unsupportedPhysicalDevice(deviceModel)
            }
            guard !processInfo.isLowPowerModeEnabled else {
                throw EnvironmentError.lowPowerModeEnabled
            }
            guard processInfo.thermalState != .serious,
                  processInfo.thermalState != .critical else {
                throw EnvironmentError.unacceptableThermalState(thermalState)
            }
        }

        return Batch1PerformanceEnvironment(
            mode: mode,
            evidenceScope: mode == .simulatorPreflight
                ? "harness-preflight-only; not physical-device performance evidence"
                : "physical-device characterization; thresholds are not frozen",
            deviceModelIdentifier: deviceModel,
            operatingSystem: processInfo.operatingSystemVersionString,
            kernelRelease: kernelRelease(),
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            gitCommit: gitCommit,
            treeState: treeState,
            configuration: "Release-config hosted XCTest build",
            optimization: "-O whole-module optimization (scheme/build contract)",
            testability: "ENABLE_TESTABILITY=YES required by the test command; not bit-identical to shipping binary",
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            startingThermalState: thermalState
        )
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func kernelRelease() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.release) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

struct Batch1FixtureCounts: Codable, Equatable, Sendable {
    static let legacySourceExpected = Batch1FixtureCounts(
        profiles: 1,
        regimens: 24,
        countdowns: 60,
        journeyEntries: 7_300,
        labRecords: 1_200,
        migrationIssues: 0,
        revisions: 8_585
    )

    static let expected = Batch1FixtureCounts(
        profiles: 1,
        regimens: 24,
        countdowns: 60,
        journeyEntries: 7_300,
        labRecords: 1_200,
        migrationIssues: 0,
        revisions: 17_112
    )

    let profiles: Int
    let regimens: Int
    let countdowns: Int
    let journeyEntries: Int
    let labRecords: Int
    let migrationIssues: Int
    let revisions: Int

    var legacyFacts: Int {
        profiles + regimens + countdowns + journeyEntries + labRecords
    }
}

struct Batch1V3CompanionCounts: Codable, Equatable, Sendable {
    static let expected = Batch1V3CompanionCounts(
        preferences: 1,
        journeyProfiles: 1,
        hrtPeriods: 1,
        regimenVersions: 24,
        regimenItems: 0,
        scheduleRules: 0,
        historicalTimes: 8_500
    )

    let preferences: Int
    let journeyProfiles: Int
    let hrtPeriods: Int
    let regimenVersions: Int
    let regimenItems: Int
    let scheduleRules: Int
    let historicalTimes: Int

    var facts: Int {
        preferences + journeyProfiles + hrtPeriods + regimenVersions
            + regimenItems + scheduleRules + historicalTimes
    }
}

enum Batch1V3FoundationContract {
    static let activatedFactCount = Batch1FixtureCounts.expected.legacyFacts
        + Batch1V3CompanionCounts.expected.facts + 1
    static let activatedRevisionCount = Batch1FixtureCounts.expected.revisions + 1
    static let nextLocalRevision = Int64(activatedRevisionCount + 1)
    static let quickWriteAddedFactCount = 2
    static let postQuickWriteRevisionCount = activatedRevisionCount + quickWriteAddedFactCount
    static let postQuickWriteNextLocalRevision = nextLocalRevision + 1
}

struct Batch1PerformanceFixtureManifest: Codable, Equatable, Sendable {
    let version: String
    let sourceKind: String
    let counts: Batch1FixtureCounts
    let sha256: [String: String]
}

struct Batch1PerformanceSample: Codable, Equatable, Sendable {
    let sampleIndex: Int
    let migrationOpenNanoseconds: Int64
    let todaySnapshotNanoseconds: Int64
    let archiveSnapshotNanoseconds: Int64
    let quickJourneyWriteNanoseconds: Int64
    let cleanupSucceeded: Bool

    func duration(for operation: Batch1PerformanceOperation) -> Int64 {
        switch operation {
        case .migrationOpen: migrationOpenNanoseconds
        case .todaySnapshot: todaySnapshotNanoseconds
        case .archiveSnapshot: archiveSnapshotNanoseconds
        case .quickJourneyWrite: quickJourneyWriteNanoseconds
        }
    }
}

struct Batch1PerformanceSummary: Codable, Equatable {
    let rank: Int
    let p95Nanoseconds: Int64
}

@MainActor
final class Batch1PerformanceRecorder {
    enum RecorderError: Error, Equatable {
        case incompleteSamples(actual: Int)
        case missingFixture
    }

    let contract: Batch1PerformanceContract
    private let invocation: Batch1PerformanceInvocation
    private var environment: Batch1PerformanceEnvironment?
    private let startedAt = Date()
    private(set) var completedSampleCount = 0
    private(set) var summaries: [Batch1PerformanceOperation: Batch1PerformanceSummary] = [:]
    private var samples: [Batch1PerformanceSample] = []
    private var fixture: Batch1PerformanceFixtureManifest?
    private var failure: String?
    private var status = "running"
    private var endingThermalState = "not-captured"
    private var rootCleanupSucceeded: Bool?
    private var rootCleanupFailure: String?

    init(
        contract: Batch1PerformanceContract,
        invocation: Batch1PerformanceInvocation
    ) {
        self.contract = contract
        self.invocation = invocation
    }

    func setEnvironment(_ environment: Batch1PerformanceEnvironment) {
        self.environment = environment
    }

    func setFixture(_ fixture: Batch1PerformanceFixtureManifest) {
        self.fixture = fixture
    }

    func append(_ sample: Batch1PerformanceSample) {
        samples.append(sample)
        completedSampleCount = samples.count
    }

    func markComplete() throws {
        guard fixture != nil else { throw RecorderError.missingFixture }
        guard samples.count == contract.sampleCount else {
            throw RecorderError.incompleteSamples(actual: samples.count)
        }
        var results: [Batch1PerformanceOperation: Batch1PerformanceSummary] = [:]
        for operation in contract.operations {
            let result = try Batch1PerformanceStatistics.nearestRankP95(
                samples.map { $0.duration(for: operation) }
            )
            results[operation] = Batch1PerformanceSummary(
                rank: result.rank,
                p95Nanoseconds: result.valueNanoseconds
            )
        }
        summaries = results
        endingThermalState = Batch1PerformanceEnvironment.thermalLabel(
            ProcessInfo.processInfo.thermalState
        )
        status = "complete-characterization"
    }

    func markInvalid(_ error: Error) {
        summaries = [:]
        failure = String(reflecting: error)
        endingThermalState = Batch1PerformanceEnvironment.thermalLabel(
            ProcessInfo.processInfo.thermalState
        )
        status = "invalid"
    }

    func markSkipped(_ reason: String) {
        summaries = [:]
        failure = reason
        endingThermalState = Batch1PerformanceEnvironment.thermalLabel(
            ProcessInfo.processInfo.thermalState
        )
        status = "skipped-disabled"
    }

    func markRootCleanupSucceeded() {
        rootCleanupSucceeded = true
        rootCleanupFailure = nil
    }

    func markRootCleanupFailed(_ error: Error) {
        rootCleanupSucceeded = false
        rootCleanupFailure = String(reflecting: error)
    }

    func jsonData() throws -> Data {
        let report = Batch1PerformanceReport(
            schemaVersion: "1.0.0",
            contractVersion: contract.version,
            startedAt: startedAt,
            finishedAt: Date(),
            status: status,
            acceptance: "not-evaluated; numeric thresholds and a frozen cross-device fixture are pending",
            warmupCount: contract.warmupCount,
            requestedSampleCount: contract.sampleCount,
            completedSampleCount: completedSampleCount,
            operationDefinitions: Dictionary(
                uniqueKeysWithValues: contract.operations.map { ($0.rawValue, $0.definition) }
            ),
            thresholdNanoseconds: Dictionary(
                uniqueKeysWithValues: contract.thresholdNanoseconds.map { ($0.key.rawValue, $0.value) }
            ),
            summaries: Dictionary(
                uniqueKeysWithValues: summaries.map { ($0.key.rawValue, $0.value) }
            ),
            fixture: fixture,
            invocation: invocation,
            environment: environment,
            endingThermalState: endingThermalState,
            rootCleanupSucceeded: rootCleanupSucceeded,
            rootCleanupFailure: rootCleanupFailure,
            samples: samples,
            failure: failure
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    func csvData() -> Data {
        var lines = [
            "sampleIndex,migrationOpenNs,todaySnapshotNs,archiveSnapshotNs,quickJourneyWriteNs,cleanupSucceeded"
        ]
        lines += samples.map {
            [
                String($0.sampleIndex),
                String($0.migrationOpenNanoseconds),
                String($0.todaySnapshotNanoseconds),
                String($0.archiveSnapshotNanoseconds),
                String($0.quickJourneyWriteNanoseconds),
                String($0.cleanupSucceeded)
            ].joined(separator: ",")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

private struct Batch1PerformanceReport: Codable {
    let schemaVersion: String
    let contractVersion: String
    let startedAt: Date
    let finishedAt: Date
    let status: String
    let acceptance: String
    let warmupCount: Int
    let requestedSampleCount: Int
    let completedSampleCount: Int
    let operationDefinitions: [String: String]
    let thresholdNanoseconds: [String: Int64]
    let summaries: [String: Batch1PerformanceSummary]
    let fixture: Batch1PerformanceFixtureManifest?
    let invocation: Batch1PerformanceInvocation
    let environment: Batch1PerformanceEnvironment?
    let endingThermalState: String
    let rootCleanupSucceeded: Bool?
    let rootCleanupFailure: String?
    let samples: [Batch1PerformanceSample]
    let failure: String?
}
