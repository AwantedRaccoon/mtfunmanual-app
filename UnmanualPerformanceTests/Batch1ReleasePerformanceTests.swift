import XCTest

@MainActor
final class Batch1ReleasePerformanceTests: XCTestCase {
    func testFiveYearReleasePerformance() async throws {
#if targetEnvironment(simulator)
        let isSimulator = true
#else
        let isSimulator = false
#endif
        let processInfo = ProcessInfo.processInfo
        let recorder = Batch1PerformanceRecorder(
            contract: .v1,
            invocation: Batch1PerformanceInvocation.capture(
                environment: processInfo.environment,
                isSimulator: isSimulator,
                processInfo: processInfo
            )
        )
        defer { attachEvidence(from: recorder) }

        let mode: Batch1PerformanceRunMode
        do {
            mode = try Batch1PerformanceRunMode.resolve(
                environment: processInfo.environment,
                isSimulator: isSimulator
            )
        } catch {
            recorder.markInvalid(error)
            XCTFail("Batch 1 performance configuration is invalid: \(String(reflecting: error))")
            return
        }
        if mode == .disabled {
            let reason = "Set UNMANUAL_BATCH1_PERF_MODE explicitly; this heavy test never runs by default."
            recorder.markSkipped(reason)
            try XCTSkipIf(true, reason)
        }

        do {
            let environment = try Batch1PerformanceEnvironment.capture(
                mode: mode,
                processInfo: processInfo
            )
            recorder.setEnvironment(environment)
        } catch {
            recorder.markInvalid(error)
            XCTFail("Batch 1 performance environment is invalid: \(String(reflecting: error))")
            return
        }

        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        var applicationSupportValues = URLResourceValues()
        applicationSupportValues.isExcludedFromBackup = false
        var mutableApplicationSupport = applicationSupport
        try mutableApplicationSupport.setResourceValues(applicationSupportValues)
        let rootURL = applicationSupport
            .appending(path: "UnmanualBatch1Performance", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)

        var runError: Error?
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            let fixture = try Batch1FiveYearFixtureBuilder.makeSnapshot(
                at: rootURL.appending(path: "Fixture", directoryHint: .isDirectory)
            )
            recorder.setFixture(fixture.manifest)

            for warmupIndex in 0..<recorder.contract.warmupCount {
                let worker = Batch1PerformanceWorker()
                _ = try await worker.runIteration(
                    fixture: fixture,
                    rootURL: rootURL.appending(
                        path: "Warmup-\(warmupIndex)",
                        directoryHint: .isDirectory
                    ),
                    sampleIndex: -1
                )
            }

            for sampleIndex in 0..<recorder.contract.sampleCount {
                let worker = Batch1PerformanceWorker()
                let sample = try await worker.runIteration(
                    fixture: fixture,
                    rootURL: rootURL.appending(
                        path: "Sample-\(sampleIndex)",
                        directoryHint: .isDirectory
                    ),
                    sampleIndex: sampleIndex
                )
                recorder.append(sample)
            }

            try fixture.verifyUnchanged()
        } catch {
            runError = error
        }

        do {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                try FileManager.default.removeItem(at: rootURL)
            }
            recorder.markRootCleanupSucceeded()
        } catch {
            recorder.markRootCleanupFailed(error)
            if runError == nil { runError = error }
        }

        if let runError {
            recorder.markInvalid(runError)
            XCTFail("Batch 1 performance evidence is invalid: \(String(reflecting: runError))")
            return
        }

        do {
            try recorder.markComplete()
        } catch {
            recorder.markInvalid(error)
            XCTFail("Batch 1 performance report is invalid: \(String(reflecting: error))")
            return
        }

        XCTAssertEqual(recorder.completedSampleCount, recorder.contract.sampleCount)
        XCTAssertEqual(Set(recorder.summaries.keys), Set(recorder.contract.operations))
        XCTAssertEqual(recorder.summaries.values.map(\.rank), [19, 19, 19, 19])
    }

    private func attachEvidence(from recorder: Batch1PerformanceRecorder) {
        do {
            let json = XCTAttachment(
                data: try recorder.jsonData(),
                uniformTypeIdentifier: "public.json"
            )
            json.name = "batch1-performance.json"
            json.lifetime = .keepAlways
            add(json)

            let csv = XCTAttachment(
                data: recorder.csvData(),
                uniformTypeIdentifier: "public.comma-separated-values-text"
            )
            csv.name = "batch1-performance.csv"
            csv.lifetime = .keepAlways
            add(csv)
        } catch {
            XCTFail("Could not attach Batch 1 performance evidence: \(error)")
        }
    }
}
