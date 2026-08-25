import Foundation

public struct RuntimeStartConfiguration: Equatable, Sendable {
    public let modelDirectory: URL
    public let modelID: String
    public let readinessProbe: TranscriptionRequest

    public init(
        modelDirectory: URL,
        modelID: String = ServiceConfiguration.defaultModelID,
        readinessProbe: TranscriptionRequest
    ) {
        self.modelDirectory = modelDirectory
        self.modelID = modelID
        self.readinessProbe = readinessProbe
    }
}

public enum RuntimeState: Equatable, Sendable {
    case cold
    case loading
    case ready
    case draining
    case failed(TranscriptionDiagnostic)
}

public enum DrainResult: Equatable, Sendable {
    case completed
    case timedOut
}

public protocol RuntimeLoader: Sendable {
    func load(configuration: RuntimeStartConfiguration) async throws -> any Transcriber
}

public typealias RuntimeReadinessCheck = @Sendable (
    any Transcriber,
    TranscriptionRequest
) async throws -> Void

/// Owns one warm transcription runtime and its lifecycle.
///
/// FluidAudio conversion and Core ML prediction use cooperative cancellation.
/// A drain timeout can therefore leave this actor in `draining` until the
/// active request returns. New requests remain rejected during that interval.
public actor RuntimeController {
    private let loader: any RuntimeLoader
    private var runtimeState: RuntimeState = .cold
    private var transcriber: (any Transcriber)?
    private var loadTask: Task<any Transcriber, Error>?
    private var acceptedConfiguration: RuntimeStartConfiguration?
    private var activeWork = 0

    public init(loader: any RuntimeLoader) {
        self.loader = loader
    }

    public var state: RuntimeState {
        runtimeState
    }

    public var isReady: Bool {
        if case .ready = runtimeState { return true }
        return false
    }

    public func start(
        _ configuration: RuntimeStartConfiguration,
        readinessCheck: RuntimeReadinessCheck? = nil
    ) async throws {
        switch runtimeState {
        case .ready:
            guard acceptedConfiguration == configuration else {
                throw configurationConflict()
            }
            return
        case .draining:
            throw TranscriptionDiagnostic(code: .draining, message: "runtime is draining")
        case .loading:
            guard acceptedConfiguration == configuration else {
                throw configurationConflict()
            }
        case .cold, .failed:
            acceptedConfiguration = configuration
        }

        let task: Task<any Transcriber, Error>
        if let existingTask = loadTask {
            task = existingTask
        } else {
            runtimeState = .loading
            let loader = self.loader
            task = Task {
                let loaded = try await loader.load(configuration: configuration)
                do {
                    if let readinessCheck {
                        try await readinessCheck(loaded, configuration.readinessProbe)
                    } else {
                        _ = try await loaded.transcribe(configuration.readinessProbe)
                    }
                } catch {
                    throw TranscriptionDiagnostic(
                        code: .readinessProbeFailed,
                        message: "readiness probe failed"
                    )
                }
                return loaded
            }
            loadTask = task
        }

        do {
            let loaded = try await task.value
            if runtimeState == .ready {
                return
            }
            guard runtimeState == .loading else {
                throw TranscriptionDiagnostic(code: .draining, message: "runtime is draining")
            }
            transcriber = loaded
            loadTask = nil
            runtimeState = .ready
        } catch let diagnostic as TranscriptionDiagnostic {
            if runtimeState == .loading {
                transcriber = nil
                loadTask = nil
                acceptedConfiguration = nil
                runtimeState = .failed(diagnostic)
            } else if runtimeState == .draining {
                loadTask = nil
                if activeWork == 0 {
                    releaseRuntime()
                }
            }
            throw diagnostic
        } catch {
            let diagnostic = TranscriptionDiagnostic(
                code: .modelLoadFailed,
                message: "model loading failed"
            )
            if runtimeState == .loading {
                transcriber = nil
                loadTask = nil
                acceptedConfiguration = nil
                runtimeState = .failed(diagnostic)
            } else if runtimeState == .draining {
                loadTask = nil
                if activeWork == 0 {
                    releaseRuntime()
                }
            }
            throw diagnostic
        }
    }

    /// Cancel only an in-flight load. The caller must still await the load
    /// task before it releases any model lease or runtime ownership.
    public func cancelLoading() {
        guard runtimeState == .loading else { return }
        runtimeState = .draining
        loadTask?.cancel()
    }

    /// Runs work against the loaded runtime without adding a second request
    /// admission boundary. The caller owns admission and drain ordering.
    func withLoadedTranscriber<Result: Sendable>(
        _ operation: @Sendable (any Transcriber) async throws -> Result
    ) async throws -> Result {
        guard runtimeState == .ready, let transcriber else {
            if case .draining = runtimeState {
                throw TranscriptionDiagnostic(code: .draining, message: "runtime is draining")
            }
            throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "runtime is not ready")
        }
        return try await operation(transcriber)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard runtimeState == .ready, let transcriber else {
            if case .draining = runtimeState {
                throw TranscriptionDiagnostic(code: .draining, message: "runtime is draining")
            }
            throw TranscriptionDiagnostic(
                code: .runtimeUnavailable,
                message: "runtime is not ready"
            )
        }
        guard activeWork == 0 else {
            throw TranscriptionDiagnostic(
                code: .admissionLimitReached,
                message: "only one transcription may run at a time"
            )
        }

        activeWork = 1
        do {
            let result = try await transcriber.transcribe(request)
            finishActiveWork()
            return result
        } catch {
            finishActiveWork()
            throw error
        }
    }

    public func drain(timeout: Duration) async -> DrainResult {
        switch runtimeState {
        case .cold:
            return .completed
        case .failed:
            releaseRuntime()
            return .completed
        case .loading:
            runtimeState = .draining
            loadTask?.cancel()
        case .ready:
            runtimeState = .draining
        case .draining:
            break
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while activeWork > 0 || loadTask != nil {
            if clock.now >= deadline {
                return .timedOut
            }
            try? await Task.sleep(for: .milliseconds(1))
        }

        releaseRuntime()
        return .completed
    }

    private func finishActiveWork() {
        activeWork = 0
        if case .draining = runtimeState {
            releaseRuntime()
        }
    }

    private func releaseRuntime() {
        transcriber = nil
        loadTask = nil
        acceptedConfiguration = nil
        activeWork = 0
        runtimeState = .cold
    }

    private func configurationConflict() -> TranscriptionDiagnostic {
        TranscriptionDiagnostic(
            code: .configurationConflict,
            message: "runtime is using a different configuration"
        )
    }
}
