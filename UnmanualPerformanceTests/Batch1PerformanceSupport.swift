import Foundation

enum Batch1PerformanceOperation: String, CaseIterable, Codable, Hashable {
    case migrationOpen
    case todaySnapshot
    case archiveSnapshot
    case quickJourneyWrite

    var definition: String {
        switch self {
        case .migrationOpen:
            "AppDataStoreBootstrapper.open() from invocation through validated active-store return, including production migration, backfill, reopen, activation and startup protection audit."
        case .todaySnapshot:
            "The first AppReadActor.todaySnapshot() call on an independently migrated store."
        case .archiveSnapshot:
            "AppReadActor.archiveSnapshot(), using bounded count and extrema queries without loading full tables."
        case .quickJourneyWrite:
            "AppDataWriter.addJourneyEntry(), including the post-commit store protection audit used by the production UI boundary."
        }
    }
}

struct Batch1PerformanceContract: Equatable {
    static let v1 = Batch1PerformanceContract(
        version: "1.0.0",
        warmupCount: 1,
        sampleCount: 20,
        operations: Batch1PerformanceOperation.allCases,
        thresholdNanoseconds: [:]
    )

    let version: String
    let warmupCount: Int
    let sampleCount: Int
    let operations: [Batch1PerformanceOperation]
    let thresholdNanoseconds: [Batch1PerformanceOperation: Int64]
}

enum Batch1PerformanceRunMode: String, Codable, Equatable {
    case disabled
    case simulatorPreflight
    case physicalCharacterization

    enum ConfigurationError: Error, Equatable {
        case unsupportedValue(String)
        case platformMismatch
    }

    static func resolve(
        environment: [String: String],
        isSimulator: Bool
    ) throws -> Batch1PerformanceRunMode {
        guard let value = environment["UNMANUAL_BATCH1_PERF_MODE"], !value.isEmpty else {
            return .disabled
        }
        switch value {
        case "simulator-preflight" where isSimulator:
            return .simulatorPreflight
        case "physical-characterization" where !isSimulator:
            return .physicalCharacterization
        case "simulator-preflight", "physical-characterization":
            throw ConfigurationError.platformMismatch
        default:
            throw ConfigurationError.unsupportedValue(value)
        }
    }
}

enum Batch1PerformanceStatistics {
    struct NearestRankResult: Equatable {
        let rank: Int
        let valueNanoseconds: Int64
    }

    enum StatisticsError: Error, Equatable {
        case incompleteEvidence(actualSampleCount: Int)
    }

    static func nearestRankP95(_ samples: [Int64]) throws -> NearestRankResult {
        guard samples.count >= 20 else {
            throw StatisticsError.incompleteEvidence(actualSampleCount: samples.count)
        }
        let rank = (95 * samples.count + 99) / 100
        let sorted = samples.sorted()
        return NearestRankResult(
            rank: rank,
            valueNanoseconds: sorted[rank - 1]
        )
    }
}
