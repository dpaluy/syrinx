import Darwin
import Foundation

enum ServiceLifecycleLockError: Error, Equatable, Sendable {
    case unsafeLock
    case timedOut
    case cancelled
}

private final class LocalLifecycleLockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var semaphores: [String: DispatchSemaphore] = [:]

    func acquire(path: String, timeout: Duration) async throws {
        let semaphore = semaphore(for: path)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if Task.isCancelled { throw ServiceLifecycleLockError.cancelled }
            if tryAcquire(semaphore) { return }
            guard ContinuousClock.now < deadline else {
                throw ServiceLifecycleLockError.timedOut
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw ServiceLifecycleLockError.cancelled
            }
        }
    }

    private func semaphore(for path: String) -> DispatchSemaphore {
        lock.lock()
        let semaphore = semaphores[path] ?? {
            let value = DispatchSemaphore(value: 1)
            semaphores[path] = value
            return value
        }()
        lock.unlock()
        return semaphore
    }

    private func tryAcquire(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    func release(path: String) {
        lock.lock()
        let semaphore = semaphores[path]
        lock.unlock()
        semaphore?.signal()
    }
}

private let localLifecycleLockRegistry = LocalLifecycleLockRegistry()

final class ServiceLifecycleLockHandle: @unchecked Sendable {
    private let path: URL
    private let fileSystem: ServiceFileSystem
    private let descriptor: Int32
    private let authorityPath: URL
    private let authorityDescriptor: Int32

    init(
        path: URL,
        fileSystem: ServiceFileSystem,
        descriptor: Int32,
        authorityPath: URL,
        authorityDescriptor: Int32
    ) {
        self.path = path
        self.fileSystem = fileSystem
        self.descriptor = descriptor
        self.authorityPath = authorityPath
        self.authorityDescriptor = authorityDescriptor
    }

    func verify() throws {
        guard verifyAuthority(),
              (try? fileSystem.privateLockIdentityMatches(path, descriptor: descriptor)) == true else {
            throw ServiceLifecycleLockError.unsafeLock
        }
    }

    private func verifyAuthority() -> Bool {
        (try? fileSystem.directoryIdentityMatches(authorityPath, descriptor: authorityDescriptor)) == true
    }

    func transition<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try verify()
        do {
            let result = try await operation()
            try verify()
            return result
        } catch {
            try verify()
            throw error
        }
    }

    func finalTransition<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard verifyAuthority() else { throw ServiceLifecycleLockError.unsafeLock }
        return try await operation()
    }

    func recoveryTransition<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try ServiceRecoveryContext.consume()
        guard verifyAuthority() else { throw ServiceLifecycleLockError.unsafeLock }
        let result = try await operation()
        try ServiceRecoveryContext.consume()
        guard verifyAuthority() else { throw ServiceLifecycleLockError.unsafeLock }
        return result
    }
}

struct ServiceLifecycleLock: Sendable {
    let path: URL
    let fileSystem: ServiceFileSystem
    let timeout: Duration

    init(
        path: URL,
        fileSystem: ServiceFileSystem,
        timeout: Duration = .seconds(15)
    ) {
        self.path = path
        self.fileSystem = fileSystem
        self.timeout = timeout
    }

    func withLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withLock { _ in try await operation() }
    }

    func withLock<T: Sendable>(
        _ operation: @Sendable (ServiceLifecycleLockHandle) async throws -> T
    ) async throws -> T {
        let authorityPath = path.deletingLastPathComponent().standardizedFileURL.path
        try await localLifecycleLockRegistry.acquire(path: authorityPath, timeout: timeout)
        defer { localLifecycleLockRegistry.release(path: authorityPath) }

        let authority = try openAuthorityDescriptor()
        defer { close(authority) }
        try await acquire(authority)
        defer { _ = flock(authority, LOCK_UN) }

        let descriptor = try openDescriptor()
        defer { close(descriptor) }

        try await acquire(descriptor)
        guard (try? fileSystem.privateLockIdentityMatches(path, descriptor: descriptor)) == true else {
            _ = flock(descriptor, LOCK_UN)
            throw ServiceLifecycleLockError.unsafeLock
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let handle = ServiceLifecycleLockHandle(
            path: path,
            fileSystem: fileSystem,
            descriptor: descriptor,
            authorityPath: path.deletingLastPathComponent(),
            authorityDescriptor: authority
        )
        return try await operation(handle)
    }

    private func acquire(_ descriptor: Int32) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if Task.isCancelled {
                throw ServiceLifecycleLockError.cancelled
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw ServiceLifecycleLockError.unsafeLock
            }
            guard ContinuousClock.now < deadline else {
                throw ServiceLifecycleLockError.timedOut
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw ServiceLifecycleLockError.cancelled
            }
        }
    }

    private func openAuthorityDescriptor() throws -> Int32 {
        do {
            return try fileSystem.openLifecycleAuthority(path)
        } catch {
            throw ServiceLifecycleLockError.unsafeLock
        }
    }

    private func openDescriptor() throws -> Int32 {
        do {
            return try fileSystem.openPrivateLock(path)
        } catch {
            throw ServiceLifecycleLockError.unsafeLock
        }
    }
}
