import XCTest
@testable import SyrinxCore

final class RuntimeControllerTests: XCTestCase {
    func testStartTransitionsToReadyAfterTheReadinessProbe() async throws {
        let transcriber = FakeTranscriber()
        let loader = FakeRuntimeLoader(transcriber: transcriber)
        let controller = RuntimeController(loader: loader)
        let configuration = RuntimeStartConfiguration(
            modelDirectory: URL(fileURLWithPath: "/tmp/parakeet-tdt-0.6b-v3"),
            readinessProbe: request("probe.wav")
        )

        try await controller.start(configuration)

        let state = await controller.state
        let loadCount = await loader.loadCount
        let requests = await transcriber.requests
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.audioFile.lastPathComponent, "probe.wav")
    }

    func testConcurrentStartsShareOneLoadAttempt() async throws {
        let transcriber = FakeTranscriber()
        let loader = FakeRuntimeLoader(transcriber: transcriber, blocksLoad: true)
        let controller = RuntimeController(loader: loader)
        let configuration = RuntimeStartConfiguration(
            modelDirectory: modelURL(),
            readinessProbe: request("probe.wav")
        )

        let first = Task { try await controller.start(configuration) }
        let second = Task { try await controller.start(configuration) }
        await loader.waitUntilLoadStarted()

        let loadCountBeforeRelease = await loader.loadCount
        XCTAssertEqual(loadCountBeforeRelease, 1)

        await loader.releaseLoad()
        try await first.value
        try await second.value

        let state = await controller.state
        let loadCount = await loader.loadCount
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(loadCount, 1)
    }

    func testDifferentConfigurationDuringLoadingReturnsConflictWithoutStartingAnotherLoad() async throws {
        let loader = FakeRuntimeLoader(transcriber: FakeTranscriber(), blocksLoad: true)
        let controller = RuntimeController(loader: loader)
        let firstConfiguration = RuntimeStartConfiguration(
            modelDirectory: URL(fileURLWithPath: "/tmp/parakeet-tdt-0.6b-v3"),
            modelID: "parakeet-tdt-0.6b-v3",
            readinessProbe: request("probe.wav")
        )
        let differentConfiguration = RuntimeStartConfiguration(
            modelDirectory: URL(fileURLWithPath: "/tmp/other-parakeet-model"),
            modelID: "other-model",
            readinessProbe: request("other-probe.wav")
        )

        let first = Task { try await controller.start(firstConfiguration) }
        await loader.waitUntilLoadStarted()

        do {
            try await controller.start(differentConfiguration)
            XCTFail("expected a configuration conflict")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .configurationConflict)
            XCTAssertEqual(diagnostic.message, "runtime is using a different configuration")
            XCTAssertFalse(diagnostic.description.contains(firstConfiguration.modelDirectory.path))
            XCTAssertFalse(diagnostic.description.contains(differentConfiguration.modelDirectory.path))
            XCTAssertFalse(diagnostic.description.contains(differentConfiguration.readinessProbe.audioFile.path))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let loadCountBeforeRelease = await loader.loadCount
        XCTAssertEqual(loadCountBeforeRelease, 1)
        await loader.releaseLoad()
        try await first.value
    }

    func testDifferentConfigurationAfterReadyReturnsConflictAndKeepsRuntimeReady() async throws {
        let loader = FakeRuntimeLoader(transcriber: FakeTranscriber())
        let controller = RuntimeController(loader: loader)
        let firstConfiguration = RuntimeStartConfiguration(
            modelDirectory: URL(fileURLWithPath: "/tmp/parakeet-tdt-0.6b-v3"),
            modelID: "parakeet-tdt-0.6b-v3",
            readinessProbe: request("probe.wav")
        )
        let differentConfiguration = RuntimeStartConfiguration(
            modelDirectory: URL(fileURLWithPath: "/tmp/other-parakeet-model"),
            modelID: "other-model",
            readinessProbe: request("other-probe.wav")
        )

        try await controller.start(firstConfiguration)

        do {
            try await controller.start(differentConfiguration)
            XCTFail("expected a configuration conflict")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .configurationConflict)
            XCTAssertEqual(diagnostic.message, "runtime is using a different configuration")
            XCTAssertFalse(diagnostic.description.contains(firstConfiguration.modelDirectory.path))
            XCTAssertFalse(diagnostic.description.contains(differentConfiguration.modelDirectory.path))
            XCTAssertFalse(diagnostic.description.contains(differentConfiguration.readinessProbe.audioFile.path))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let state = await controller.state
        let loadCount = await loader.loadCount
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(loadCount, 1)
    }

    func testFailedStartupStoresAStableDiagnostic() async {
        let loader = FakeRuntimeLoader(transcriber: FakeTranscriber(), loadError: .failed)
        let controller = RuntimeController(loader: loader)

        do {
            try await controller.start(
                RuntimeStartConfiguration(modelDirectory: modelURL(), readinessProbe: request("probe.wav"))
            )
            XCTFail("expected startup failure")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .modelLoadFailed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        if case let .failed(diagnostic) = await controller.state {
            XCTAssertEqual(diagnostic.code, .modelLoadFailed)
        } else {
            XCTFail("expected failed runtime state")
        }
    }

    func testReadinessProbeFailureDoesNotMakeRuntimeReady() async {
        let transcriber = FakeTranscriber(transcriptionError: .failed)
        let loader = FakeRuntimeLoader(transcriber: transcriber)
        let controller = RuntimeController(loader: loader)
        let configuration = RuntimeStartConfiguration(
            modelDirectory: modelURL(),
            readinessProbe: request("probe.wav")
        )

        do {
            try await controller.start(configuration)
            XCTFail("expected readiness failure")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .readinessProbeFailed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        if case let .failed(diagnostic) = await controller.state {
            XCTAssertEqual(diagnostic.code, .readinessProbeFailed)
        } else {
            XCTFail("expected failed runtime state")
        }
    }

    func testAdmissionIsOneAcrossTheFullTranscriptionCall() async throws {
        let transcriber = FakeTranscriber(blocksAfterRequestCount: 1)
        let loader = FakeRuntimeLoader(transcriber: transcriber)
        let controller = RuntimeController(loader: loader)
        try await controller.start(
            RuntimeStartConfiguration(modelDirectory: modelURL(), readinessProbe: request("probe.wav"))
        )

        let firstRequest = request("first.wav")
        let first = Task { try await controller.transcribe(firstRequest) }
        await transcriber.waitUntilTranscriptionStarted()

        do {
            _ = try await controller.transcribe(request("second.wav"))
            XCTFail("expected the second request to be rejected")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .admissionLimitReached)
        }

        let requestsBeforeRelease = await transcriber.requests
        XCTAssertEqual(requestsBeforeRelease.count, 2)
        await transcriber.releaseTranscription()
        _ = try await first.value
        let requestsAfterRelease = await transcriber.requests
        XCTAssertEqual(requestsAfterRelease.count, 2)
    }

    func testDrainRejectsNewWorkAndReleasesReadyState() async throws {
        let transcriber = FakeTranscriber(blocksAfterRequestCount: 1)
        let loader = FakeRuntimeLoader(transcriber: transcriber)
        let controller = RuntimeController(loader: loader)
        try await controller.start(
            RuntimeStartConfiguration(modelDirectory: modelURL(), readinessProbe: request("probe.wav"))
        )
        let activeRequest = request("active.wav")
        let active = Task { try await controller.transcribe(activeRequest) }
        await transcriber.waitUntilTranscriptionStarted()

        let drain = Task { await controller.drain(timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(10))
        let stateWhileDraining = await controller.state
        XCTAssertEqual(stateWhileDraining, .draining)

        do {
            _ = try await controller.transcribe(request("rejected.wav"))
            XCTFail("expected draining admission failure")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .draining)
        }

        await transcriber.releaseTranscription()
        let drainResult = await drain.value
        XCTAssertEqual(drainResult, .completed)
        _ = try await active.value
        let stateAfterDrain = await controller.state
        XCTAssertEqual(stateAfterDrain, .cold)
    }

    func testDrainTimeoutReleasesRuntimeButWaitsForActiveWorkBeforeNextStart() async throws {
        let transcriber = FakeTranscriber(blocksAfterRequestCount: 1)
        let loader = FakeRuntimeLoader(transcriber: transcriber)
        let controller = RuntimeController(loader: loader)
        try await controller.start(
            RuntimeStartConfiguration(modelDirectory: modelURL(), readinessProbe: request("probe.wav"))
        )
        let activeRequest = request("active.wav")
        let active = Task { try await controller.transcribe(activeRequest) }
        await transcriber.waitUntilTranscriptionStarted()

        let drainResult = await controller.drain(timeout: .milliseconds(1))
        let stateAfterTimeout = await controller.state
        XCTAssertEqual(drainResult, .timedOut)
        XCTAssertEqual(stateAfterTimeout, .draining)

        do {
            try await controller.start(
                RuntimeStartConfiguration(modelDirectory: modelURL(), readinessProbe: request("probe.wav"))
            )
            XCTFail("expected start to remain blocked while active work is draining")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .draining)
        }

        await transcriber.releaseTranscription()
        _ = try await active.value
        let stateAfterActiveWork = await controller.state
        XCTAssertEqual(stateAfterActiveWork, .cold)
    }

    func testDrainTimeoutAlsoBoundsAnInProgressLoad() async throws {
        let loader = FakeRuntimeLoader(transcriber: FakeTranscriber(), blocksLoad: true)
        let controller = RuntimeController(loader: loader)
        let configuration = RuntimeStartConfiguration(
            modelDirectory: modelURL(),
            readinessProbe: request("probe.wav")
        )
        let start = Task {
            try await controller.start(configuration)
        }
        await loader.waitUntilLoadStarted()

        let result = await controller.drain(timeout: .milliseconds(1))
        let state = await controller.state
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(state, .draining)

        await loader.releaseLoad()
        do {
            try await start.value
            XCTFail("expected start to be rejected after draining")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .draining)
        }
        let finalState = await controller.state
        XCTAssertEqual(finalState, .cold)
    }

    private func modelURL() -> URL {
        URL(fileURLWithPath: "/tmp/parakeet-tdt-0.6b-v3")
    }

    private func request(_ name: String) -> TranscriptionRequest {
        TranscriptionRequest(audioFile: URL(fileURLWithPath: "/tmp/\(name)"))
    }
}

private actor FakeRuntimeLoader: RuntimeLoader {
    enum Failure: Error, Sendable {
        case failed
    }

    let transcriber: FakeTranscriber
    let loadError: Failure?
    let blocksLoad: Bool
    private(set) var loadCount = 0
    private var loadStarted = false
    private var loadContinuation: CheckedContinuation<Void, Never>?

    init(
        transcriber: FakeTranscriber,
        blocksLoad: Bool = false,
        loadError: Failure? = nil
    ) {
        self.transcriber = transcriber
        self.blocksLoad = blocksLoad
        self.loadError = loadError
    }

    func load(configuration: RuntimeStartConfiguration) async throws -> any Transcriber {
        loadCount += 1
        loadStarted = true
        loadContinuation?.resume()
        loadContinuation = nil
        if blocksLoad {
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        if let loadError {
            throw loadError
        }
        return transcriber
    }

    func waitUntilLoadStarted() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func releaseLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}

private actor FakeTranscriber: Transcriber {
    enum Failure: Error, Sendable {
        case failed
    }

    let blocksTranscription: Bool
    let blocksAfterRequestCount: Int?
    let transcriptionError: Failure?
    private(set) var requests: [TranscriptionRequest] = []
    private var transcriptionStarted = false
    private var blockedTranscriptionStarted = false
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?

    init(
        blocksTranscription: Bool = false,
        blocksAfterRequestCount: Int? = nil,
        transcriptionError: Failure? = nil
    ) {
        self.blocksTranscription = blocksTranscription
        self.blocksAfterRequestCount = blocksAfterRequestCount
        self.transcriptionError = transcriptionError
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        requests.append(request)
        transcriptionStarted = true
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
        if blocksTranscription || requests.count > (blocksAfterRequestCount ?? .max) {
            blockedTranscriptionStarted = true
            transcriptionContinuation?.resume()
            transcriptionContinuation = nil
            await withCheckedContinuation { continuation in
                transcriptionContinuation = continuation
            }
        }
        if let transcriptionError {
            throw transcriptionError
        }
        return TranscriptionResult(
            text: request.audioFile.lastPathComponent,
            duration: 1,
            processingTime: 0.1,
            modelID: "fake"
        )
    }

    func waitUntilTranscriptionStarted() async {
        guard !blockedTranscriptionStarted else { return }
        await withCheckedContinuation { continuation in
            transcriptionContinuation = continuation
        }
    }

    func releaseTranscription() {
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
    }
}
