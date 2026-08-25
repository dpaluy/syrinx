import Foundation
import XCTest
@testable import SyrinxCore

final class ServiceCoordinatorTests: XCTestCase {
    func testVersionedConfigurationWinsOverDuplicateEnvironmentValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-config-precedence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, mode_t(0o700))
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = StandardPaths(data: root, cache: root, logs: root)
        let configuration = try ServiceConfiguration(
            port: Port(6101),
            modelID: ModelIdentifier("file-model"),
            maxUploadBytes: ByteLimit(1_001, key: "test-upload"),
            maxEnvelopeBytes: ByteLimit(1_002, key: "test-envelope"),
            maxDurationSeconds: DurationLimit(101, key: "test-duration"),
            maxJobs: JobLimit(3, key: "test-jobs"),
            httpIdleTimeoutMilliseconds: DurationLimit(1_003, key: "test-idle"),
            httpRequestTimeoutMilliseconds: DurationLimit(1_004, key: "test-request"),
            httpHeaderFieldBytes: ByteLimit(1_005, key: "test-field"),
            httpHeaderListBytes: ByteLimit(1_006, key: "test-list"),
            httpHeaderFieldCount: JobLimit(4, key: "test-count"),
            shutdownTimeoutSeconds: ShutdownTimeout(17, key: "test-shutdown")
        )
        let data = try JSONEncoder().encode(ServiceConfigurationSnapshot(configuration: configuration))
        let configURL = root.appendingPathComponent("versioned.json")
        try ServiceFileSystem().writePrivateFileAtomically(data, to: configURL)

        let captured = ConfigurationBox()
        let command = ServeCommand(
            environment: [
                "SYRINX_CONFIG_PATH": configURL.path,
                "SYRINX_PORT": "6102",
                "SYRINX_MODEL_ID": "stale-environment-model",
                "SYRINX_MAX_JOBS": "99"
            ],
            paths: paths,
            engineFactory: { configuration, _ in
                captured.set(configuration)
                return FakeServeEngine()
            },
            serviceFactory: { _, _, _ in FakeServeService() }
        )

        let result = await command.run(arguments: [])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(captured.value?.port.value, 6101)
        XCTAssertEqual(captured.value?.modelID.value, "file-model")
        XCTAssertEqual(captured.value?.maxJobs.value, 3)
        XCTAssertEqual(captured.value?.shutdownTimeoutSeconds.value, 17)
    }

    func testServiceLaunchRequiresDigestOfTheExactVersionedConfigurationBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-service-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, mode_t(0o700))
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = StandardPaths(data: root, cache: root, logs: root)
        let configuration = ServiceConfiguration()
        let data = try JSONEncoder().encode(ServiceConfigurationSnapshot(configuration: configuration))
        let configURL = root.appendingPathComponent("versioned.json")
        try ServiceFileSystem().writePrivateFileAtomically(data, to: configURL)
        let digest = ServiceConfigurationDigest.forData(data)
        let constructed = LockedFlag()
        let command = ServeCommand(
            environment: [
                "SYRINX_SERVICE_LAUNCH": "1",
                "SYRINX_CONFIG_PATH": configURL.path,
                "SYRINX_CONFIG_SHA256": digest
            ],
            paths: paths,
            engineFactory: { _, _ in
                constructed.setTrue()
                return FakeServeEngine()
            },
            serviceFactory: { _, _, _ in FakeServeService() }
        )

        let accepted = await command.run(arguments: [])
        XCTAssertEqual(accepted.exitCode, 0, accepted.stderr)
        XCTAssertTrue(constructed.value)

        let replacement = Data("{\"host\":\"127.0.0.1\",\"port\":5093}".utf8)
        try ServiceFileSystem().writePrivateFileAtomically(replacement, to: configURL)
        let rejected = await ServeCommand(
            environment: [
                "SYRINX_SERVICE_LAUNCH": "1",
                "SYRINX_CONFIG_PATH": configURL.path,
                "SYRINX_CONFIG_SHA256": digest
            ],
            paths: paths,
            engineFactory: { _, _ in
                XCTFail("digest mismatch must fail before engine construction")
                return FakeServeEngine()
            },
            serviceFactory: { _, _, _ in FakeServeService() }
        ).run(arguments: [])
        XCTAssertEqual(rejected, CommandResult(exitCode: 1, stderr: "serve_failed: configuration_error\n"))
    }

    func testDirectServeRejectsInvalidSecretSourcesAndSecretBytes() async throws {
        let cases: [(name: String, environment: [String: String], bytes: Data?, mode: mode_t?)] = [
            ("unsupported", ["SYRINX_API_KEY_SOURCE": "environment"], nil, nil),
            ("missing-file", ["SYRINX_API_KEY_SOURCE": "file"], nil, nil),
            ("ambiguous", [
                "SYRINX_API_KEY_SOURCE": "file",
                "SYRINX_API_KEY_FILE": "/private/missing-secret",
                "SYRINX_API_KEY": "inline-secret"
            ], nil, nil),
            ("empty", ["SYRINX_API_KEY_SOURCE": "file"], Data(), nil),
            ("unsafe-mode", ["SYRINX_API_KEY_SOURCE": "file"], Data("valid-secret".utf8), 0o644),
            ("newline", ["SYRINX_API_KEY_SOURCE": "file"], Data("valid\nsecret".utf8), nil),
            ("control", ["SYRINX_API_KEY_SOURCE": "file"], Data([0x01, 0x41]), nil)
        ]

        for testCase in cases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("syrinx-secret-(testCase.name)-(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            chmod(root.path, mode_t(0o700))
            defer { try? FileManager.default.removeItem(at: root) }

            var environment = testCase.environment
            if let bytes = testCase.bytes {
                let secret = root.appendingPathComponent("secret")
                try ServiceFileSystem().writePrivateFileAtomically(bytes, to: secret)
                if let mode = testCase.mode { chmod(secret.path, mode) }
                environment["SYRINX_API_KEY_FILE"] = secret.path
            }
            let constructed = LockedFlag()
            let command = ServeCommand(
                environment: environment,
                paths: StandardPaths(data: root, cache: root, logs: root),
                engineFactory: { _, _ in
                    constructed.setTrue()
                    return FakeServeEngine()
                },
                serviceFactory: { _, _, _ in FakeServeService() }
            )

            let result = await command.run(arguments: [])

            XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: configuration_error\n"), testCase.name)
            XCTAssertFalse(constructed.value, testCase.name)
            XCTAssertFalse(result.stderr.contains("valid"), testCase.name)
        }
    }

    func testStartupFailureDoesNotConstructOrBindHTTP() async {
        let engine = FakeServeEngine(startError: TranscriptionDiagnostic(code: .modelLoadFailed, message: "private model path"))
        let serviceWasConstructed = LockedFlag()
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in
                serviceWasConstructed.setTrue()
                return FakeServeService()
            }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: model_load_failed\n"))
        XCTAssertFalse(serviceWasConstructed.value)
        XCTAssertEqual(drainCount, 1)
    }

    func testStartupCancellationDoesNotConstructOrBindHTTP() async {
        let engine = FakeServeEngine(startError: CancellationError())
        let serviceWasConstructed = LockedFlag()
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in
                serviceWasConstructed.setTrue()
                return FakeServeService()
            }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: cancelled\n"))
        XCTAssertFalse(serviceWasConstructed.value)
        XCTAssertEqual(drainCount, 1)
    }

    func testCancellationDuringActiveEngineStartUsesUncancelledOwnedCleanup() async throws {
        let events = EventRecorder()
        let engine = FakeServeEngine(events: events, blocksStart: true)
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in XCTFail("HTTP must not be constructed"); return FakeServeService() }
        )
        let commandTask = Task { await command.run(arguments: []) }

        try await waitUntil(timeoutMilliseconds: 1_000) { await engine.startStarted }
        commandTask.cancel()
        let result = try await valueWithin(.seconds(2)) { await commandTask.value }
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: cancelled\n"))
        XCTAssertEqual(events.values, ["engine_start", "engine_start_cancelled", "engine_drain"])
        XCTAssertEqual(drainCount, 1)
    }

    func testSuccessfulStartWithoutReadinessDoesNotConstructOrBindHTTP() async {
        let engine = FakeServeEngine(readyAfterStart: false)
        let serviceWasConstructed = LockedFlag()
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in
                serviceWasConstructed.setTrue()
                return FakeServeService()
            }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: runtime_unavailable\n"))
        XCTAssertFalse(serviceWasConstructed.value)
        XCTAssertEqual(drainCount, 1)
    }

    func testNormalShutdownDrainsHTTPBeforeEngineExactlyOnce() async {
        let events = EventRecorder()
        let engine = FakeServeEngine(events: events)
        let service = FakeServeService(events: events)
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in
                events.append("construct_engine")
                return engine
            },
            serviceFactory: { _, _, _ in
                events.append("construct_http")
                return service
            }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(events.values, [
            "construct_engine", "engine_start", "construct_http", "http_run",
            "http_begin_drain", "http_wait_for_zero", "engine_drain"
        ])
        XCTAssertEqual(drainCount, 1)
    }

    func testServerFailureStillDrainsEngineAndReturnsStableResult() async {
        let engine = FakeServeEngine()
        let service = FakeServeService(runError: ServerFailure())
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in service }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: server_failed\n"))
        XCTAssertEqual(drainCount, 1)
    }

    func testBindFailureStillDrainsEngine() async {
        let engine = FakeServeEngine()
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in FakeServeService(runError: BindFailure(path: "/private/bind/socket")) }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: server_failed\n"))
        XCTAssertFalse(result.stderr.contains("/private/bind/socket"))
        XCTAssertEqual(drainCount, 1)
    }

    func testHTTPDrainTimeoutIsFailClosedAfterBeginDrainAndSingleEngineDrain() async {
        let events = EventRecorder()
        let engine = FakeServeEngine(events: events)
        let service = FakeServeService(
            runError: ServerFailure(),
            httpDrainResult: false,
            events: events
        )
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in service }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: shutdown_timeout\n"))
        XCTAssertEqual(events.values, [
            "engine_start", "http_run", "http_begin_drain", "http_wait_for_zero", "engine_drain"
        ])
        XCTAssertEqual(drainCount, 1)
    }

    func testServiceCancellationDrainsHTTPThenEngineAndReturnsCancelled() async {
        let events = EventRecorder()
        let engine = FakeServeEngine(events: events)
        let service = FakeServeService(runError: CancellationError(), events: events)
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in service }
        )

        let result = await command.run(arguments: [])

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: cancelled\n"))
        XCTAssertEqual(events.values, [
            "engine_start", "http_run", "http_begin_drain", "http_wait_for_zero", "engine_drain"
        ])
    }

    func testCancellationWhileServiceRunIsActiveDrainsInOrder() async throws {
        let events = EventRecorder()
        let engine = FakeServeEngine(events: events)
        let service = BlockingServeService(events: events)
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in service }
        )
        let commandTask = Task { await command.run(arguments: []) }

        try await waitUntil(timeoutMilliseconds: 1_000) { await service.isRunning() }
        commandTask.cancel()
        let result = try await valueWithin(.seconds(2)) { await commandTask.value }
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: cancelled\n"))
        XCTAssertEqual(events.values, [
            "engine_start", "http_run", "http_cancelled", "http_begin_drain",
            "http_wait_for_zero", "engine_drain"
        ])
        XCTAssertEqual(drainCount, 1)
    }

    func testServiceAndHTTPFailurePathsDoNotRepeatEngineCleanup() async {
        let engine = FakeServeEngine(drainResult: .timedOut)
        let service = FakeServeService(runError: ServerFailure(), httpDrainResult: false)
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in service }
        )

        _ = await command.run(arguments: [])
        let firstDrainCount = await engine.drainCount
        _ = await command.run(arguments: [])
        let totalDrainCount = await engine.drainCount

        XCTAssertEqual(firstDrainCount, 1)
        XCTAssertEqual(totalDrainCount, 2)
    }

    func testConfigurationAndPathsAreLoadedBeforeComposition() async {
        let events = EventRecorder()
        let engine = FakeServeEngine(events: events)
        let environment = [
            "SYRINX_PORT": "5099",
            "SYRINX_MAX_JOBS": "2"
        ]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-serve-config-\(UUID().uuidString)")
        let paths = StandardPaths(data: root, cache: root, logs: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = ServeCommand(
            environment: environment,
            paths: paths,
            engineFactory: { configuration, receivedPaths in
                events.append("port=\(configuration.port.value)")
                events.append("jobs=\(configuration.maxJobs.value)")
                events.append("data=\(receivedPaths.data.path)")
                return engine
            },
            serviceFactory: { httpConfiguration, handler, readiness in
                events.append("service_port=\(httpConfiguration.service.port.value)")
                events.append("service_jobs=\(httpConfiguration.service.maxJobs.value)")
                if let receivedEngine = handler as? FakeServeEngine, receivedEngine === engine {
                    events.append("same_engine=true")
                } else {
                    events.append("same_engine=false")
                }
                return FakeServeService(events: events, readiness: readiness)
            }
        )

        let result = await command.run(arguments: [])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(events.values, [
            "port=5099", "jobs=2", "data=\(root.path)",
            "engine_start", "service_port=5099", "service_jobs=2", "same_engine=true",
            "http_run", "readiness=true", "http_begin_drain",
            "http_wait_for_zero", "engine_drain"
        ])
    }

    func testPathValidationFailureIsStableAndDoesNotConstructEngine() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-serve-invalid-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a directory".utf8).write(to: file)
        let constructed = LockedFlag()
        let paths = StandardPaths(data: file, cache: file, logs: file)
        let command = ServeCommand(
            environment: [:],
            paths: paths,
            engineFactory: { _, _ in
                constructed.setTrue()
                return FakeServeEngine()
            },
            serviceFactory: { _, _, _ in FakeServeService() }
        )

        let result = await command.run(arguments: [])

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: configuration_error\n"))
        XCTAssertFalse(result.stderr.contains(file.path))
        XCTAssertFalse(constructed.value)
    }

    func testShutdownTimeoutIsFailClosed() async {
        let engine = FakeServeEngine(drainResult: .timedOut)
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in engine },
            serviceFactory: { _, _, _ in FakeServeService() }
        )

        let result = await command.run(arguments: [])
        let drainCount = await engine.drainCount

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: shutdown_timeout\n"))
        XCTAssertEqual(drainCount, 1)
    }

    func testConstructionFailureIsStableAndRedacted() async {
        let privatePath = "/Users/private/model-store"
        let command = ServeCommand(
            environment: [:],
            paths: testPaths(),
            engineFactory: { _, _ in
                throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: privatePath)
            },
            serviceFactory: { _, _, _ in XCTFail("HTTP must not be constructed"); return FakeServeService() }
        )

        let result = await command.run(arguments: [])

        XCTAssertEqual(result, CommandResult(exitCode: 1, stderr: "serve_failed: runtime_unavailable\n"))
        XCTAssertFalse(result.stderr.contains(privatePath))
    }

    private func testPaths() -> StandardPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-serve-test-\(UUID().uuidString)")
        return StandardPaths(data: root, cache: root, logs: root)
    }
}

private actor FakeServeEngine: ServeEngine {
    private let startError: Error?
    private let drainResult: DrainResult
    private let events: EventRecorder?
    private let readyAfterStart: Bool
    private let blocksStart: Bool
    private(set) var drainCount = 0
    private var ready = false
    private(set) var startStarted = false

    init(
        startError: Error? = nil,
        drainResult: DrainResult = .completed,
        events: EventRecorder? = nil,
        readyAfterStart: Bool = true,
        blocksStart: Bool = false
    ) {
        self.startError = startError
        self.drainResult = drainResult
        self.events = events
        self.readyAfterStart = readyAfterStart
        self.blocksStart = blocksStart
    }

    var isReady: Bool { ready }

    func start() async throws {
        events?.append("engine_start")
        startStarted = true
        if blocksStart {
            do {
                while true {
                    try await Task.sleep(for: .milliseconds(5))
                }
            } catch {
                events?.append("engine_start_cancelled")
                throw CancellationError()
            }
        }
        if let startError { throw startError }
        ready = readyAfterStart
    }

    func drain(timeout: Duration) async -> DrainResult {
        if Task.isCancelled {
            events?.append("engine_drain_cancelled")
            return .timedOut
        }
        events?.append("engine_drain")
        drainCount += 1
        ready = false
        return drainResult
    }

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        TranscriptionResult(text: "fake", duration: 0, processingTime: 0, modelID: modelID)
    }
}

private actor FakeServeService: ServeHTTPService {
    private let runError: Error?
    private let httpDrainResult: Bool
    private let events: EventRecorder?
    private let readiness: ReadinessSource?

    init(
        runError: Error? = nil,
        httpDrainResult: Bool = true,
        events: EventRecorder? = nil,
        readiness: ReadinessSource? = nil
    ) {
        self.runError = runError
        self.httpDrainResult = httpDrainResult
        self.events = events
        self.readiness = readiness
    }

    func run() async throws {
        events?.append("http_run")
        if let readiness {
            events?.append("readiness=\(await readiness.isReady())")
        }
        if let runError { throw runError }
    }

    func beginDrain() async {
        if Task.isCancelled {
            events?.append("http_begin_drain_cancelled")
            return
        }
        events?.append("http_begin_drain")
    }

    func waitForHTTPDrain() async -> Bool {
        if Task.isCancelled {
            events?.append("http_wait_for_zero_cancelled")
            return false
        }
        events?.append("http_wait_for_zero")
        return httpDrainResult
    }
}

private actor BlockingServeService: ServeHTTPService {
    private let events: EventRecorder
    private var running = false

    init(events: EventRecorder) {
        self.events = events
    }

    func run() async throws {
        events.append("http_run")
        running = true
        do {
            while true {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            events.append("http_cancelled")
            throw CancellationError()
        }
    }

    func isRunning() -> Bool {
        running
    }

    func beginDrain() async {
        if Task.isCancelled {
            events.append("http_begin_drain_cancelled")
            return
        }
        events.append("http_begin_drain")
    }

    func waitForHTTPDrain() async -> Bool {
        if Task.isCancelled {
            events.append("http_wait_for_zero_cancelled")
            return false
        }
        events.append("http_wait_for_zero")
        return true
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage = false

    func setTrue() {
        lock.lock()
        valueStorage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valueStorage
    }
}

private final class ConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ServiceConfiguration?

    func set(_ value: ServiceConfiguration) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: ServiceConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct ServerFailure: Error, Sendable {}
private struct BindFailure: Error, Sendable {
    let path: String
}

private struct TestTimeout: Error, Sendable {}

private func waitUntil(
    timeoutMilliseconds: Int,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestTimeout()
}

private func valueWithin<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
