import Darwin
import Foundation

internal struct DeadlineMarker: Error, Sendable {}

private enum DeadlineRaceEvent<Value: Sendable>: @unchecked Sendable {
    case completed(Value)
    case failed(ErrorBox)
    case deadline
    case timerCancelled
}

private enum EngineState: Sendable, Equatable {
    case cold
    case starting
    case ready
    case draining
    case failed
}

internal struct TranscriptionPipelineHooks: Sendable {
    let afterAdmission: (@Sendable () -> Void)?
    let beforeOpen: (@Sendable () -> Void)?
    let afterOpen: (@Sendable () -> Void)?
    let beforeRIFF: (@Sendable () -> Void)?
    let beforeMetadata: (@Sendable () -> Void)?
    let beforeConversion: (@Sendable () -> Void)?
    let beforeInference: (@Sendable () -> Void)?
    let afterCleanup: (@Sendable () -> Void)?

    init(
        afterAdmission: (@Sendable () -> Void)? = nil,
        beforeOpen: (@Sendable () -> Void)? = nil,
        afterOpen: (@Sendable () -> Void)? = nil,
        beforeRIFF: (@Sendable () -> Void)? = nil,
        beforeMetadata: (@Sendable () -> Void)? = nil,
        beforeConversion: (@Sendable () -> Void)? = nil,
        beforeInference: (@Sendable () -> Void)? = nil,
        afterCleanup: (@Sendable () -> Void)? = nil
    ) {
        self.afterAdmission = afterAdmission
        self.beforeOpen = beforeOpen
        self.afterOpen = afterOpen
        self.beforeRIFF = beforeRIFF
        self.beforeMetadata = beforeMetadata
        self.beforeConversion = beforeConversion
        self.beforeInference = beforeInference
        self.afterCleanup = afterCleanup
    }
}

internal struct TranscriptionDeadlinePolicy: Sendable {
    static let maximumExplicitSeconds: TimeInterval = 3_600
    let defaultSeconds: TimeInterval

    init(configuration: ServiceConfiguration) {
        let configuredSeconds = Double(configuration.httpRequestTimeoutMilliseconds.value) / 1_000.0
        self.defaultSeconds = configuredSeconds
    }

    func resolve(requested: TimeInterval?) throws -> TimeInterval {
        guard let requested else {
            guard defaultSeconds.isFinite, defaultSeconds > 0 else {
                throw invalidDeadline()
            }
            return defaultSeconds
        }
        let seconds = requested
        guard seconds.isFinite, seconds > 0, seconds <= Self.maximumExplicitSeconds else {
            throw invalidDeadline()
        }
        return seconds
    }

    private func invalidDeadline() -> TranscriptionDiagnostic {
        TranscriptionDiagnostic(
            code: .invalidDeadline,
            message: "The deadline is invalid."
        )
    }
}

public actor NativeTranscriptionEngine: Transcriber, HTTPTranscriptionHandler {
    public let configuration: ServiceConfiguration

    private let lifecycle: ModelLifecycleCoordinator
    private let runtime: RuntimeController
    private let policy: AudioPreparationPolicy
    private let inspector: RIFFWAVInspector
    private let normalizer: AudioNormalizer
    private let admission: TranscriptionAdmissionGate
    private let deadlinePolicy: TranscriptionDeadlinePolicy
    private let hooks: TranscriptionPipelineHooks

    private var engineState: EngineState = .cold
    private var runtimeLease: ModelRuntimeLease?
    private var startupTask: Task<Void, Error>?
    private var deferredDrainTask: Task<Void, Never>?
    private var nextDrainWaiterID: UInt64 = 0
    private var drainWaiters: [UInt64: PendingDrainWaiter] = [:]

    public init(
        configuration: ServiceConfiguration = .init(),
        paths: StandardPaths = .init(),
        runtimeLoader: any RuntimeLoader = FluidAudioRuntimeLoader()
    ) throws {
        self.configuration = configuration
        let store = ModelStore(root: paths.data)
        self.lifecycle = try ModelLifecycleCoordinator(store: store)
        self.runtime = RuntimeController(loader: runtimeLoader)
        self.policy = try AudioPreparationPolicy(configuration: configuration)
        self.inspector = RIFFWAVInspector(policy: self.policy)
        self.normalizer = AudioNormalizer(policy: self.policy)
        self.admission = TranscriptionAdmissionGate()
        self.deadlinePolicy = TranscriptionDeadlinePolicy(configuration: configuration)
        self.hooks = TranscriptionPipelineHooks()
    }

    internal init(
        testingLifecycle: ModelLifecycleCoordinator,
        configuration: ServiceConfiguration,
        runtimeLoader: any RuntimeLoader,
        policy: AudioPreparationPolicy,
        hooks: TranscriptionPipelineHooks
    ) {
        self.configuration = configuration
        self.lifecycle = testingLifecycle
        self.runtime = RuntimeController(loader: runtimeLoader)
        self.policy = policy
        self.inspector = RIFFWAVInspector(policy: policy)
        self.normalizer = AudioNormalizer(
            policy: policy,
            phaseBoundaryHook: nil,
            phaseHook: { phase in
                switch phase {
                case .metadata:
                    hooks.beforeMetadata?()
                case .conversion:
                    hooks.beforeConversion?()
                }
            }
        )
        self.admission = TranscriptionAdmissionGate()
        self.deadlinePolicy = TranscriptionDeadlinePolicy(configuration: configuration)
        self.hooks = hooks
    }

    public var isReady: Bool {
        engineState == .ready
    }

    public func start() async throws {
        switch engineState {
        case .ready:
            return
        case .starting:
            guard let startupTask else {
                throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "The runtime is unavailable.")
            }
            // A concurrent waiter does not own the shared startup task. It
            // waits for the owner, then reports its own cancellation.
            let result = await awaitStartupResult(startupTask, forwardsCancellation: false)
            if Task.isCancelled {
                throw CancellationError()
            }
            try result.get()
            return
        case .draining:
            throw TranscriptionDiagnostic(code: .draining, message: "The service is draining.")
        case .cold, .failed:
            break
        }

        engineState = .starting
        let task = Task { [self] in
            try await performStart()
        }
        startupTask = task

        // The first caller owns startup cancellation. The shared task still
        // remains awaited until runtime cleanup and lease release finish.
        let result = await awaitStartupResult(task, forwardsCancellation: true)
        if startupTask != nil {
            startupTask = nil
        }

        if Task.isCancelled {
            if engineState == .starting {
                engineState = .failed
            }
            throw CancellationError()
        }

        do {
            try result.get()
        } catch {
            if engineState == .starting {
                engineState = .failed
            }
            throw error
        }
    }

    internal static func testingResolveDeadline(
        configuration: ServiceConfiguration,
        requested: TimeInterval?
    ) throws -> TimeInterval {
        try TranscriptionDeadlinePolicy(configuration: configuration).resolve(requested: requested)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard engineState == .ready else {
            let code: TranscriptionDiagnostic.Code = engineState == .draining ? .draining : .runtimeUnavailable
            throw TranscriptionDiagnostic(code: code, message: code == .draining ? "The service is draining." : "The runtime is unavailable.")
        }

        return try await runWithDeadline(request) { [self] deadline in
            try await runtime.withLoadedTranscriber { [self] transcriber in
                try await execute(request, deadline: deadline, transcriber: transcriber)
            }
        }
    }

    public func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        guard modelID == configuration.modelID.value else {
            throw TranscriptionDiagnostic(code: .inputRejected, message: "The selected model is not supported.")
        }
        let request = TranscriptionRequest(uploadedFile: uploadedFile)
        return try await transcribe(request)
    }

    public func drain(timeout: Duration = .seconds(30)) async -> DrainResult {
        if engineState == .cold {
            runtimeLease?.close()
            runtimeLease = nil
            return .completed
        }

        engineState = .draining
        await admission.beginDrain()
        startupTask?.cancel()
        if startupTask != nil {
            await runtime.cancelLoading()
        }
        ensureDeferredDrainTask()

        let completed = await waitForDrain(timeout: timeout)
        return completed ? .completed : .timedOut
    }

    internal func testingIsDraining() async -> Bool {
        await admission.isDraining
    }

    private func performStart() async throws {
        let probe = try SelfGeneratedReadinessProbe()
        defer { probe.remove() }

        let lease = try await lifecycle.resolveRuntime()
        runtimeLease = lease

        let readinessRequest = TranscriptionRequest(audioFile: probe.fileURL)
        let runtimeStartTask = Task { [self] in
            try await runtime.start(
                RuntimeStartConfiguration(
                    modelDirectory: lease.repositoryURL,
                    modelID: lease.modelId,
                    readinessProbe: readinessRequest
                ),
                readinessCheck: { [self] transcriber, request in
                    _ = try await runWithDeadline(request) { [self] deadline in
                        try await execute(request, deadline: deadline, transcriber: transcriber)
                    }
                }
            )
        }

        let startResult = await withTaskCancellationHandler(operation: {
            await runtimeStartTask.result
        }, onCancel: {
            runtimeStartTask.cancel()
            Task { [weak self] in
                await self?.runtime.cancelLoading()
            }
        })
        do {
            try startResult.get()
            try Task.checkCancellation()
            guard engineState == .starting else {
                throw TranscriptionDiagnostic(code: .draining, message: "The service is draining.")
            }
            engineState = .ready
        } catch {
            _ = await runtime.drain(timeout: .seconds(30))
            lease.close()
            if runtimeLease != nil {
                runtimeLease = nil
            }
            if engineState == .draining {
                throw TranscriptionDiagnostic(code: .draining, message: "The service is draining.")
            }
            throw map(error)
        }
    }

    private func execute(
        _ request: TranscriptionRequest,
        deadline: ContinuousClock.Instant,
        transcriber: any Transcriber
    ) async throws -> TranscriptionResult {
        let permit = try await admission.acquire(until: deadline)

        do {
            try Task.checkCancellation()
            try Self.checkDeadline(deadline)
            hooks.afterAdmission?()
            try Task.checkCancellation()
            try Self.checkDeadline(deadline)
            guard let lease = runtimeLease else {
                throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "The runtime is unavailable.")
            }

            let startedAt = ContinuousClock.now
            hooks.beforeOpen?()
            try Task.checkCancellation()
            let result = try await request.withAudioAccess { [self] inputAccess in
                hooks.afterOpen?()
                try Task.checkCancellation()

                hooks.beforeRIFF?()
                let inspected = try inspector.inspect(access: inputAccess)
                try Task.checkCancellation()
                try Self.checkDeadline(deadline)
                if inspected.duration > Double(policy.maxDurationSeconds) {
                    throw TranscriptionDiagnostic(code: .inputRejected, message: "The audio file is too long.")
                }

                let pipelineHooks = hooks
                return try await normalizer.withNormalizedAudio(
                    from: inputAccess,
                    phaseHook: { phase in
                        try Task.checkCancellation()
                        try Self.checkDeadline(deadline)
                        switch phase {
                        case .metadata:
                            pipelineHooks.beforeMetadata?()
                        case .conversion:
                            pipelineHooks.beforeConversion?()
                        }
                        try Task.checkCancellation()
                    },
                    phaseBoundaryHook: {
                        try Task.checkCancellation()
                        try Self.checkDeadline(deadline)
                    }
                ) { [self] prepared in
                    try Self.checkDeadline(deadline)
                    try Task.checkCancellation()

                    hooks.beforeInference?()
                    try Task.checkCancellation()
                    let backendResult = try await transcriber.transcribe(
                        TranscriptionRequest(audioFile: prepared.fileURL)
                    )

                    try Task.checkCancellation()
                    try Self.checkDeadline(deadline)

                    let elapsed = startedAt.duration(to: .now)
                    let elapsedSeconds = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
                    return TranscriptionResult(
                        text: backendResult.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        duration: prepared.duration,
                        processingTime: elapsedSeconds,
                        modelID: lease.modelId,
                        modelRevision: lease.immutableCommit
                    )
                }
            }
            try Task.checkCancellation()
            try Self.checkDeadline(deadline)
            hooks.afterCleanup?()
            await admission.release(permit)
            return result
        } catch {
            hooks.afterCleanup?()
            await admission.release(permit)
            throw error
        }
    }

    private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        guard ContinuousClock.now < deadline else {
            throw DeadlineMarker()
        }
    }

    private func awaitStartupResult(
        _ task: Task<Void, Error>,
        forwardsCancellation: Bool
    ) async -> Result<Void, Error> {
        await withTaskCancellationHandler(operation: {
            await task.result
        }, onCancel: {
            if forwardsCancellation {
                task.cancel()
            }
        })
    }

    private func runWithDeadline<Result: Sendable>(
        _ request: TranscriptionRequest,
        operation: @escaping @Sendable (ContinuousClock.Instant) async throws -> Result
    ) async throws -> Result {
        let seconds = try deadlinePolicy.resolve(requested: request.deadline)
        let nanoseconds = Int64((seconds * 1_000_000_000.0).rounded(.up))
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(nanoseconds))

        let winner = await withTaskGroup(of: DeadlineRaceEvent<Result>.self) { group in
            group.addTask {
                do {
                    return .completed(try await operation(deadline))
                } catch {
                    return .failed(ErrorBox(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .nanoseconds(nanoseconds))
                    return .deadline
                } catch {
                    return .timerCancelled
                }
            }

            let first = await group.next() ?? .timerCancelled
            group.cancelAll()
            return first
        }

        switch winner {
        case .deadline:
            throw TranscriptionDiagnostic(code: .deadlineExceeded, message: "The deadline was exceeded.")
        case .completed(let value):
            if Task.isCancelled {
                throw TranscriptionDiagnostic(code: .cancelled, message: "The operation was cancelled.")
            }
            return value
        case .failed(let box):
            throw map(box.error)
        case .timerCancelled:
            throw TranscriptionDiagnostic(code: .cancelled, message: "The operation was cancelled.")
        }
    }

    private func map(_ error: Error) -> Error {
        if error is DeadlineMarker {
            return TranscriptionDiagnostic(code: .deadlineExceeded, message: "The deadline was exceeded.")
        }
        if error is CancellationError {
            return TranscriptionDiagnostic(code: .cancelled, message: "The operation was cancelled.")
        }
        if let diagnostic = error as? TranscriptionDiagnostic {
            return stableDiagnostic(for: diagnostic.code)
        }
        if let preparation = error as? AudioPreparationError {
            switch preparation {
            case .invalidConfiguration,
                 .configurationArithmeticOverflow,
                 .inputNotRegularFile,
                 .inputUnreadable,
                 .emptyInput,
                 .uploadLimitExceeded,
                 .invalidWAV,
                 .unsupportedWAV,
                 .truncatedInput,
                 .duplicateChunk,
                 .arithmeticOverflow,
                 .invalidAudioMetadata,
                 .durationLimitExceeded,
                 .sampleLimitExceeded,
                 .conversionFailed:
                return TranscriptionDiagnostic(code: .inputRejected, message: "The audio input was rejected.")
            }
        }
        return TranscriptionDiagnostic(code: .runtimeUnavailable, message: "The runtime is unavailable.")
    }

    private func stableDiagnostic(for code: TranscriptionDiagnostic.Code) -> TranscriptionDiagnostic {
        let message: String
        switch code {
        case .admissionLimitReached:
            message = "The transcription capacity is full."
        case .draining:
            message = "The service is draining."
        case .configurationConflict:
            message = "The runtime configuration is not supported."
        case .modelLoadFailed:
            message = "The model could not be loaded."
        case .modelMissing:
            message = "The selected model is unavailable."
        case .readinessProbeFailed:
            message = "The runtime readiness check failed."
        case .runtimeUnavailable:
            message = "The runtime is unavailable."
        case .transcriptionFailed:
            message = "Transcription failed."
        case .inputRejected:
            message = "The audio input was rejected."
        case .cancelled:
            message = "The operation was cancelled."
        case .deadlineExceeded:
            message = "The deadline was exceeded."
        case .drainTimeout:
            message = "Runtime shutdown timed out."
        case .invalidDeadline:
            message = "The deadline is invalid."
        }
        return TranscriptionDiagnostic(code: code, message: message)
    }

    private func ensureDeferredDrainTask() {
        guard deferredDrainTask == nil else { return }
        let startup = startupTask
        deferredDrainTask = Task { [self] in
            if let startup {
                _ = await startup.result
            }
            await admission.waitForZero()
            await finishDrain()
        }
    }

    private func finishDrain() async {
        guard engineState == .draining else { return }
        let result = await runtime.drain(timeout: .seconds(30))
        guard result == .completed else {
            deferredDrainTask = nil
            ensureDeferredDrainTask()
            return
        }

        await admission.resetAfterDrain()
        runtimeLease?.close()
        runtimeLease = nil
        engineState = .cold
        deferredDrainTask = nil

        let waiters = drainWaiters
        drainWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    private func waitForDrain(timeout: Duration) async -> Bool {
        let id = nextDrainWaiterID
        nextDrainWaiterID &+= 1

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard engineState != .cold else {
                    continuation.resume(returning: true)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutDrainWaiter(id)
                }
                drainWaiters[id] = PendingDrainWaiter(continuation: continuation, timer: timer)
            }
        }, onCancel: {
            Task { [weak self] in
                await self?.cancelDrainWaiter(id)
            }
        })
    }

    private func timeoutDrainWaiter(_ id: UInt64) {
        guard let waiter = drainWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: false)
    }

    private func cancelDrainWaiter(_ id: UInt64) {
        guard let waiter = drainWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: false)
    }
}

private struct PendingDrainWaiter {
    let continuation: CheckedContinuation<Bool, Never>
    let timer: Task<Void, Never>
}

private struct ErrorBox: @unchecked Sendable {
    let error: Error

    init(_ error: Error) {
        self.error = error
    }
}

internal struct AdmissionPermit: Sendable, Equatable {
    let id: UInt64
}

internal actor TranscriptionAdmissionGate {
    private var nextPermitID: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var activePermit: AdmissionPermit?
    private var draining = false
    private var waiters: [UInt64: PendingAdmissionWaiter] = [:]
    private var waiterOrder: [UInt64] = []
    private var zeroWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private let afterPermitResume: (@Sendable () -> Void)?

    init(afterPermitResume: (@Sendable () -> Void)? = nil) {
        self.afterPermitResume = afterPermitResume
    }

    func acquire(until deadline: ContinuousClock.Instant?) async throws -> AdmissionPermit {
        try Task.checkCancellation()
        guard !draining else {
            throw TranscriptionDiagnostic(code: .draining, message: "The service is draining.")
        }

        if activePermit == nil {
            let permit = grantPermit()
            try validateGrantedPermit(permit, deadline: deadline)
            return permit
        }

        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        let permit = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    id: waiterID,
                    continuation: continuation,
                    deadline: deadline
                )
            }
        }, onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(waiterID)
            }
        })
        try validateGrantedPermit(permit, deadline: deadline)
        return permit
    }

    func release(_ permit: AdmissionPermit) {
        guard activePermit == permit else { return }
        activePermit = nil
        guard !draining else {
            signalZeroIfNeeded()
            return
        }
        grantNextOrSignalZero()
    }

    func beginDrain() {
        guard !draining else { return }
        draining = true
        let pending = waiters
        waiters.removeAll()
        waiterOrder.removeAll()
        for (_, waiter) in pending {
            waiter.timer?.cancel()
            waiter.continuation.resume(throwing: TranscriptionDiagnostic(code: .draining, message: "The service is draining."))
        }
        signalZeroIfNeeded()
    }

    func resetAfterDrain() {
        guard draining, activePermit == nil, waiters.isEmpty else { return }
        draining = false
    }

    var isDraining: Bool { draining }

    func waitForZero() async {
        guard activePermit != nil else { return }
        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if activePermit == nil {
                    continuation.resume()
                } else {
                    zeroWaiters[waiterID] = continuation
                }
            }
        }, onCancel: {
            Task { [weak self] in
                await self?.cancelZeroWaiter(waiterID)
            }
        })
    }

    private func enqueue(
        id: UInt64,
        continuation: CheckedContinuation<AdmissionPermit, Error>,
        deadline: ContinuousClock.Instant?
    ) {
        guard !draining else {
            continuation.resume(throwing: TranscriptionDiagnostic(code: .draining, message: "The service is draining."))
            return
        }
        guard activePermit != nil else {
            let permit = grantPermit()
            continuation.resume(returning: permit)
            afterPermitResume?()
            return
        }
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }

        let timer: Task<Void, Never>?
        if let deadline {
            timer = Task { [weak self] in
                let duration = ContinuousClock.now.duration(to: deadline)
                guard duration > .zero else {
                    await self?.expireWaiter(id)
                    return
                }
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                await self?.expireWaiter(id)
            }
        } else {
            timer = nil
        }
        waiters[id] = PendingAdmissionWaiter(continuation: continuation, timer: timer)
        waiterOrder.append(id)
    }

    private func grantPermit() -> AdmissionPermit {
        let permit = AdmissionPermit(id: nextPermitID)
        nextPermitID &+= 1
        activePermit = permit
        return permit
    }

    private func grantNextOrSignalZero() {
        while let next = waiterOrder.first {
            waiterOrder.removeFirst()
            guard let waiter = waiters.removeValue(forKey: next) else { continue }
            waiter.timer?.cancel()
            let permit = grantPermit()
            waiter.continuation.resume(returning: permit)
            afterPermitResume?()
            return
        }
        signalZeroIfNeeded()
    }

    private func validateGrantedPermit(
        _ permit: AdmissionPermit,
        deadline: ContinuousClock.Instant?
    ) throws {
        if Task.isCancelled {
            release(permit)
            throw CancellationError()
        }
        if let deadline, ContinuousClock.now >= deadline {
            release(permit)
            throw DeadlineMarker()
        }
    }

    private func expireWaiter(_ id: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        waiter.continuation.resume(throwing: DeadlineMarker())
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        waiter.timer?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func signalZeroIfNeeded() {
        guard activePermit == nil else { return }
        let continuations = zeroWaiters.values
        zeroWaiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancelZeroWaiter(_ id: UInt64) {
        guard let continuation = zeroWaiters.removeValue(forKey: id) else { return }
        continuation.resume()
    }
}

private struct PendingAdmissionWaiter {
    let continuation: CheckedContinuation<AdmissionPermit, Error>
    let timer: Task<Void, Never>?
}

internal struct SelfGeneratedReadinessProbe: Sendable {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        try self.init(
            root: FileManager.default.temporaryDirectory,
            leafName: UUID().uuidString,
            fileName: "probe.wav"
        )
    }

    init(root: URL, leafName: String, fileName: String) throws {
        // The temporary root is shared. Only this unique leaf is trusted.
        let directory = root.appendingPathComponent(leafName, isDirectory: true)
        let file = directory.appendingPathComponent(fileName, isDirectory: false)
        var createdDirectory = false
        do {
            guard directory.path.withCString({ mkdir($0, mode_t(0o700)) == 0 }) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            createdDirectory = true
            var directoryStatus = stat()
            guard directory.path.withCString({ lstat($0, &directoryStatus) }) == 0,
                  (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
                  (directoryStatus.st_mode & 0o777) == 0o700
            else {
                throw POSIXError(.EACCES)
            }

            let sampleRate = 16_000
            let frameCount = 1_600
            let dataSize = frameCount * 2
            var data = Data()
            data.append(contentsOf: Array("RIFF".utf8))
            appendLittleEndian(UInt32(36 + dataSize), to: &data)
            data.append(contentsOf: Array("WAVE".utf8))
            data.append(contentsOf: Array("fmt ".utf8))
            appendLittleEndian(UInt32(16), to: &data)
            appendLittleEndian(UInt16(1), to: &data)
            appendLittleEndian(UInt16(1), to: &data)
            appendLittleEndian(UInt32(sampleRate), to: &data)
            appendLittleEndian(UInt32(sampleRate * 2), to: &data)
            appendLittleEndian(UInt16(2), to: &data)
            appendLittleEndian(UInt16(16), to: &data)
            data.append(contentsOf: Array("data".utf8))
            appendLittleEndian(UInt32(dataSize), to: &data)

            for index in 0..<frameCount {
                let phase = Double(index) * 2.0 * Double.pi * 440.0 / Double(sampleRate)
                let sample = Int16((sin(phase) * 2_000.0).rounded())
                appendLittleEndian(UInt16(bitPattern: sample), to: &data)
            }
            try writePrivateFile(data, at: file, directory: directory)
        } catch {
            if createdDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
            throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "The readiness probe could not be created.")
        }
        self.directoryURL = directory
        self.fileURL = file
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func writePrivateFile(_ data: Data, at fileURL: URL, directory: URL) throws {
    var directoryStatus = stat()
    guard directory.path.withCString({ lstat($0, &directoryStatus) }) == 0,
          (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
          (directoryStatus.st_mode & 0o777) == 0o700
    else {
        throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "The readiness probe could not be created.")
    }

    let descriptor = fileURL.path.withCString {
        open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else {
        throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "The readiness probe could not be created.")
    }

    do {
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw POSIXError(.EACCES) }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { throw POSIXError(.EIO) }
            var offset = 0
            while offset < bytes.count {
                let result = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              (fileStatus.st_mode & 0o777) == 0o600,
              fileStatus.st_size == off_t(data.count)
        else {
            throw POSIXError(.EIO)
        }
        guard close(descriptor) == 0 else { throw POSIXError(.EIO) }
    } catch {
        close(descriptor)
        try? FileManager.default.removeItem(at: fileURL)
        throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "The readiness probe could not be created.")
    }
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
