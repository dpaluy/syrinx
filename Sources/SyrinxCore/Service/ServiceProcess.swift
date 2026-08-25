import Darwin
import Foundation

public struct ServiceProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ServiceProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case cancelled
    case outputLimitExceeded
}

public protocol ServiceProcessRunner: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> ServiceProcessResult
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ value: Data) -> Bool {
        lock.lock()
        data.append(value)
        let exceeded = data.count > limit
        if exceeded {
            data = Data(data.prefix(limit))
        }
        lock.unlock()
        return !exceeded
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class ServiceProcessOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let stdout = BoundedOutput(limit: 64 * 1024)
    private let stderr = BoundedOutput(limit: 64 * 1024)
    private let readers = DispatchGroup()
    private let completion = DispatchSemaphore(value: 0)
    private let beforePIDPublication: (@Sendable () -> Void)?
    private var pid: pid_t?
    private var continuation: CheckedContinuation<ServiceProcessResult, Error>?
    private var finished = false
    private var stopRequested = false
    private var terminationStarted = false
    private var forcedError: ServiceProcessError?

    init(beforePIDPublication: (@Sendable () -> Void)? = nil) {
        self.beforePIDPublication = beforePIDPublication
    }

    func execute(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ServiceProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let shouldStop = stopRequested
            lock.unlock()

            guard !shouldStop else {
                finish(error: currentForcedError() ?? .cancelled)
                return
            }

            do {
                let spawned = try spawn(
                    executable: executable,
                    arguments: arguments,
                    environment: environment
                )
                beforePIDPublication?()
                lock.lock()
                pid = spawned.pid
                let stoppedDuringSpawn = stopRequested
                lock.unlock()
                if stoppedDuringSpawn, beginTermination() { terminateProcess() }
                startReaders(stdout: spawned.stdout, stderr: spawned.stderr)
                startWaiter(stdout: spawned.stdout, stderr: spawned.stderr)
            } catch {
                finish(error: ServiceProcessError.launchFailed)
            }
        }
    }

    func stop(error: ServiceProcessError = .cancelled) {
        lock.lock()
        stopRequested = true
        if forcedError == nil { forcedError = error }
        let processExists = pid != nil
        let shouldTerminate: Bool
        if processExists {
            shouldTerminate = !terminationStarted
            terminationStarted = true
        } else {
            shouldTerminate = false
        }
        lock.unlock()

        guard processExists, shouldTerminate else { return }

        terminateProcess()
        _ = completion.wait(timeout: .now() + 2.0)
    }

    private func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> (pid: pid_t, stdout: Int32, stderr: Int32) {
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            if stdoutPipe[0] >= 0 { close(stdoutPipe[0]) }
            if stdoutPipe[1] >= 0 { close(stdoutPipe[1]) }
            if stderrPipe[0] >= 0 { close(stderrPipe[0]) }
            if stderrPipe[1] >= 0 { close(stderrPipe[1]) }
            throw ServiceProcessError.launchFailed
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw ServiceProcessError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let actionResults: [Int32] = [
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[1])
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw ServiceProcessError.launchFailed
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw ServiceProcessError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
                  &attributes,
                  Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
              ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw ServiceProcessError.launchFailed
        }

        var childPID: pid_t = 0
        let values = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        let result: Int32 = withCStringArray([executable.path] + arguments) { argumentPointers in
            withCStringArray(values) { environmentPointers in
                executable.path.withCString { executablePath in
                    posix_spawn(
                        &childPID,
                        executablePath,
                        &actions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard result == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw ServiceProcessError.launchFailed
        }
        return (childPID, stdoutPipe[0], stderrPipe[0])
    }

    private func startReaders(stdout: Int32, stderr: Int32) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.read(stdout, into: self?.stdout)
            self?.readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.read(stderr, into: self?.stderr)
            self?.readers.leave()
        }
    }

    private func read(_ descriptor: Int32, into output: BoundedOutput?) {
        defer { close(descriptor) }
        guard let output else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                fail(.launchFailed)
                return
            }
            if !output.append(Data(buffer[0..<count])) {
                fail(.outputLimitExceeded)
                return
            }
        }
    }

    private func startWaiter(stdout: Int32, stderr: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            var waited: pid_t = -1
            repeat {
                waited = waitpid(self.currentPID, &status, 0)
            } while waited < 0 && errno == EINTR
            self.readers.wait()
            if waited < 0 {
                self.finish(error: .launchFailed)
            } else {
                self.finish(
                    result: ServiceProcessResult(
                        exitCode: Self.exitCode(status),
                        stdout: self.stdout.string,
                        stderr: self.stderr.string
                    )
                )
            }
        }
    }

    private var currentPID: pid_t {
        lock.lock()
        defer { lock.unlock() }
        return pid ?? -1
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return 1
    }

    private func fail(_ error: ServiceProcessError) {
        lock.lock()
        if forcedError == nil { forcedError = error }
        let alreadyFinished = finished
        lock.unlock()
        if !alreadyFinished, beginTermination() { terminateProcess() }
    }

    private func beginTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminationStarted else { return false }
        terminationStarted = true
        return true
    }

    private func terminateProcess() {
        lock.lock()
        let processID = pid
        lock.unlock()
        guard let processID else { return }
        _ = kill(-processID, SIGTERM)
        _ = kill(processID, SIGTERM)
        usleep(250_000)
        _ = kill(-processID, SIGKILL)
        _ = kill(processID, SIGKILL)
    }

    private func currentForcedError() -> ServiceProcessError? {
        lock.lock()
        defer { lock.unlock() }
        return forcedError
    }

    private func finish(
        result: ServiceProcessResult? = nil,
        error: ServiceProcessError? = nil
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let finalError = error ?? forcedError
        lock.unlock()

        if let finalError {
            continuation?.resume(throwing: finalError)
        } else if let result {
            continuation?.resume(returning: result)
        } else {
            continuation?.resume(throwing: ServiceProcessError.launchFailed)
        }
        completion.signal()
    }
}

public struct SystemServiceProcessRunner: ServiceProcessRunner {
    private let beforePIDPublication: (@Sendable () -> Void)?

    public init() {
        beforePIDPublication = nil
    }

    init(beforePIDPublication: (@Sendable () -> Void)?) {
        self.beforePIDPublication = beforePIDPublication
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> ServiceProcessResult {
        try Task.checkCancellation()
        let operation = ServiceProcessOperation(beforePIDPublication: beforePIDPublication)
        let task = Task {
            try await operation.execute(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        }

        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: ServiceProcessResult.self) { group in
                    group.addTask { try await task.value }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw ServiceProcessError.timedOut
                    }
                    do {
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    } catch let error as ServiceProcessError {
                        operation.stop(error: error)
                        group.cancelAll()
                        throw error
                    } catch {
                        operation.stop(error: .cancelled)
                        group.cancelAll()
                        throw error
                    }
                }
            } catch is CancellationError {
                operation.stop(error: .cancelled)
                throw ServiceProcessError.cancelled
            }
        } onCancel: {
            operation.stop(error: .cancelled)
            task.cancel()
        }
    }
}

final class ForegroundServiceProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private let environment: [String: String]
    private var pid: pid_t?

    init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    var isRunning: Bool {
        lock.lock()
        let processID = pid
        lock.unlock()
        guard let processID else { return false }
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    var processID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    func start() throws {
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw ServiceProcessError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let outputResult = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, path, O_WRONLY, mode_t(0o600))
        }
        let errorResult = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, path, O_WRONLY, mode_t(0o600))
        }
        guard outputResult == 0, errorResult == 0 else {
            throw ServiceProcessError.launchFailed
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ServiceProcessError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
                  &attributes,
                  Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
              ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw ServiceProcessError.launchFailed
        }

        var childPID: pid_t = 0
        let values = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        let result: Int32 = withCStringArray([executable.path, "serve"]) { argumentPointers in
            withCStringArray(values) { environmentPointers in
                executable.path.withCString { executablePath in
                    posix_spawn(
                        &childPID,
                        executablePath,
                        &actions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        guard result == 0 else { throw ServiceProcessError.launchFailed }
        lock.lock()
        pid = childPID
        lock.unlock()
    }

    func stopAndReap() {
        lock.lock()
        let processID = pid
        lock.unlock()
        guard let processID else { return }

        _ = kill(-processID, SIGTERM)
        _ = kill(processID, SIGTERM)
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID { clearPID(); return }
            if result < 0 && errno == ECHILD { clearPID(); return }
            usleep(10_000)
        }
        _ = kill(-processID, SIGKILL)
        _ = kill(processID, SIGKILL)
        var status: Int32 = 0
        repeat {} while waitpid(processID, &status, 0) < 0 && errno == EINTR
        clearPID()
    }

    private func clearPID() {
        lock.lock()
        pid = nil
        lock.unlock()
    }
}

private func withCStringArray<T>(
    _ values: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
) rethrows -> T {
    var pointers = values.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers {
            if let pointer { free(pointer) }
        }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

public struct ServiceSignatureVerifier: Sendable {
    private let verifyClosure: @Sendable (URL) async throws -> Void

    public init(verify: @escaping @Sendable (URL) async throws -> Void) {
        verifyClosure = verify
    }

    func verify(executable: URL) async throws {
        try await verifyClosure(executable)
    }
}

struct CodesignServiceSignatureVerifier: Sendable {
    let processRunner: any ServiceProcessRunner

    func verify(executable: URL) async throws {
        let result: ServiceProcessResult
        do {
            result = try await processRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--strict", "--verbose=2", executable.path],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
                timeout: .seconds(5)
            )
        } catch {
            throw ServiceProcessError.launchFailed
        }
        guard result.exitCode == 0 else { throw ServiceProcessError.launchFailed }
    }
}
