import Darwin
import Foundation

public enum ModelStoreLockError: Error, Equatable, Sendable, CustomStringConvertible {
    case rootMissing
    case directoryUnsafe
    case lockFileUnsafe
    case invalidCommit
    case busy
    case timedOut
    case systemFailure

    public var description: String {
        switch self {
        case .rootMissing:
            return "model store lock root is missing"
        case .directoryUnsafe:
            return "model store lock directory is unsafe"
        case .lockFileUnsafe:
            return "model store lock file is unsafe"
        case .invalidCommit:
            return "model revision lease has an invalid immutable commit"
        case .busy:
            return "model revision lease is busy"
        case .timedOut:
            return "model store lock acquisition timed out"
        case .systemFailure:
            return "model store lock operation failed"
        }
    }
}

public enum ModelRevisionLeaseAcquisition: Sendable {
    case acquired(ModelRevisionLease)
    case busy
}

internal typealias ModelStoreLockPreAcquireHook = @Sendable () -> Void

public final class ModelRevisionLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

public final class OSBackedModelStoreLock: ModelStoreLock, @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 60
    private static let retryNanoseconds: UInt64 = 20_000_000

    private let locksDirectory: PrivateDirectoryDescriptor
    private let preAcquireHook: ModelStoreLockPreAcquireHook?

    public convenience init(store: ModelStore) throws {
        try self.init(store: store, preAcquireHook: nil)
    }

    internal init(store: ModelStore, preAcquireHook: ModelStoreLockPreAcquireHook?) throws {
        self.preAcquireHook = preAcquireHook
        do {
            try store.prepareDirectories()
        } catch {
            throw ModelStoreLockError.rootMissing
        }
        locksDirectory = try DescriptorRelativeLockSupport.openStoreSubdirectory(store: store, child: "locks")
    }

    public func withLock<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withLock(timeout: Self.defaultTimeout, operation: operation)
    }

    public func withLock<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let descriptor = try await acquire(timeout: timeout)
        defer { descriptor.close() }
        return try await operation()
    }

    private func acquire(timeout: TimeInterval) async throws -> OwnedLockDescriptor {
        let timeoutNanoseconds = try Self.nanoseconds(for: timeout)
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = timeoutNanoseconds > UInt64.max - now ? UInt64.max : now + timeoutNanoseconds

        while true {
            try Task.checkCancellation()
            if let descriptor = try tryAcquire() {
                return descriptor
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ModelStoreLockError.timedOut }
            let remaining = deadline - now
            try await Task.sleep(nanoseconds: min(Self.retryNanoseconds, remaining))
        }
    }

    private static func nanoseconds(for timeout: TimeInterval) throws -> UInt64 {
        let nanoseconds = timeout * 1_000_000_000
        guard timeout.isFinite, timeout > 0, nanoseconds.isFinite,
              nanoseconds < Double(UInt64.max)
        else {
            throw ModelStoreLockError.timedOut
        }
        return UInt64(nanoseconds.rounded(.down))
    }

    private func tryAcquire() throws -> OwnedLockDescriptor? {
        let descriptor = try DescriptorRelativeLockSupport.openLockFile(
            directory: locksDirectory,
            name: "selection.lock",
            beforeLock: preAcquireHook
        )
        guard flock(descriptor.rawValue, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            descriptor.close()
            if error == EWOULDBLOCK || error == EAGAIN { return nil }
            throw ModelStoreLockError.systemFailure
        }
        do {
            try DescriptorRelativeLockSupport.validateLockFile(
                directory: locksDirectory,
                name: "selection.lock",
                descriptor: descriptor.rawValue
            )
        } catch {
            _ = flock(descriptor.rawValue, LOCK_UN)
            descriptor.close()
            throw error
        }
        return descriptor
    }
}

public final class ModelRevisionLeaseManager: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 60
    private static let retryNanoseconds: UInt64 = 20_000_000

    private let revisionsDirectory: PrivateDirectoryDescriptor
    private let preAcquireHook: ModelStoreLockPreAcquireHook?

    public convenience init(store: ModelStore) throws {
        try self.init(store: store, preAcquireHook: nil)
    }

    internal init(store: ModelStore, preAcquireHook: ModelStoreLockPreAcquireHook?) throws {
        self.preAcquireHook = preAcquireHook
        do {
            try store.prepareDirectories()
        } catch {
            throw ModelStoreLockError.rootMissing
        }
        let locks = try DescriptorRelativeLockSupport.openStoreSubdirectory(store: store, child: "locks")
        do {
            revisionsDirectory = try DescriptorRelativeLockSupport.openOrCreateSubdirectory(
                parent: locks.rawValue,
                name: "revisions"
            )
        } catch {
            locks.close()
            throw error
        }
        locks.close()
    }

    public func acquireShared(_ immutableCommit: String) async throws -> ModelRevisionLease {
        guard ModelStore.isValidImmutableCommit(immutableCommit) else {
            throw ModelStoreLockError.invalidCommit
        }
        let timeoutNanoseconds = UInt64(Self.defaultTimeout * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            try Task.checkCancellation()
            switch try tryAcquireShared(immutableCommit) {
            case .acquired(let lease):
                return lease
            case .busy:
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw ModelStoreLockError.timedOut }
                try await Task.sleep(nanoseconds: min(Self.retryNanoseconds, deadline - now))
            }
        }
    }

    public func tryAcquireShared(_ immutableCommit: String) throws -> ModelRevisionLeaseAcquisition {
        try acquire(immutableCommit, operation: LOCK_SH | LOCK_NB)
    }

    public func tryAcquireExclusive(_ immutableCommit: String) throws -> ModelRevisionLeaseAcquisition {
        try acquire(immutableCommit, operation: LOCK_EX | LOCK_NB)
    }

    private func acquire(
        _ immutableCommit: String,
        operation: Int32
    ) throws -> ModelRevisionLeaseAcquisition {
        guard ModelStore.isValidImmutableCommit(immutableCommit) else {
            throw ModelStoreLockError.invalidCommit
        }
        let descriptor = try DescriptorRelativeLockSupport.openLockFile(
            directory: revisionsDirectory,
            name: "\(immutableCommit).lock",
            beforeLock: preAcquireHook
        )
        guard flock(descriptor.rawValue, operation) == 0 else {
            let error = errno
            descriptor.close()
            if error == EWOULDBLOCK || error == EAGAIN { return .busy }
            throw ModelStoreLockError.systemFailure
        }
        do {
            try DescriptorRelativeLockSupport.validateLockFile(
                directory: revisionsDirectory,
                name: "\(immutableCommit).lock",
                descriptor: descriptor.rawValue
            )
        } catch {
            _ = flock(descriptor.rawValue, LOCK_UN)
            descriptor.close()
            throw error
        }
        return .acquired(ModelRevisionLease(descriptor: descriptor.release()))
    }
}

private final class OwnedLockDescriptor: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    var rawValue: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return descriptor ?? -1
    }

    func release() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else { return -1 }
        self.descriptor = nil
        return descriptor
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        _ = Darwin.close(descriptor)
    }

    deinit {
        close()
    }
}

private final class PrivateDirectoryDescriptor: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(_ rawValue: Int32) {
        descriptor = rawValue
    }

    var rawValue: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return descriptor ?? -1
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        _ = Darwin.close(descriptor)
    }

    deinit {
        close()
    }
}

private enum DescriptorRelativeLockSupport {
    static func openStoreSubdirectory(store: ModelStore, child: String) throws -> PrivateDirectoryDescriptor {
        let root = open(store.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            throw errno == ENOENT ? ModelStoreLockError.rootMissing : ModelStoreLockError.directoryUnsafe
        }
        let rootDescriptor = PrivateDirectoryDescriptor(root)
        guard isPrivateDirectory(root) else {
            rootDescriptor.close()
            throw ModelStoreLockError.directoryUnsafe
        }
        do {
            return try openOrCreateSubdirectory(parent: rootDescriptor.rawValue, name: child)
        } catch {
            rootDescriptor.close()
            throw error
        }
    }

    static func openOrCreateSubdirectory(parent: Int32, name: String) throws -> PrivateDirectoryDescriptor {
        var inspected = stat()
        if fstatat(parent, name, &inspected, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ModelStoreLockError.directoryUnsafe }
            guard mkdirat(parent, name, mode_t(0o700)) == 0 || errno == EEXIST else {
                throw ModelStoreLockError.directoryUnsafe
            }
            guard fstatat(parent, name, &inspected, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ModelStoreLockError.directoryUnsafe
            }
        }
        guard (inspected.st_mode & S_IFMT) == S_IFDIR,
              (inspected.st_mode & 0o077) == 0
        else {
            throw ModelStoreLockError.directoryUnsafe
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelStoreLockError.directoryUnsafe }
        let result = PrivateDirectoryDescriptor(descriptor)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_dev == inspected.st_dev,
              opened.st_ino == inspected.st_ino,
              (opened.st_mode & 0o077) == 0
        else {
            result.close()
            throw ModelStoreLockError.directoryUnsafe
        }
        return result
    }

    static func openLockFile(
        directory: PrivateDirectoryDescriptor,
        name: String,
        beforeLock: ModelStoreLockPreAcquireHook? = nil
    ) throws -> OwnedLockDescriptor {
        let descriptor = openat(
            directory.rawValue,
            name,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw ModelStoreLockError.lockFileUnsafe }
        let result = OwnedLockDescriptor(descriptor)
        do {
            try validateLockFile(directory: directory, name: name, descriptor: descriptor)
            beforeLock?()
        } catch {
            result.close()
            throw error
        }
        return result
    }

    static func validateLockFile(
        directory: PrivateDirectoryDescriptor,
        name: String,
        descriptor: Int32
    ) throws {
        var named = stat()
        var opened = stat()
        guard fstatat(directory.rawValue, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(descriptor, &opened) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              (opened.st_mode & S_IFMT) == S_IFREG,
              named.st_nlink == 1,
              opened.st_nlink == 1,
              (named.st_mode & 0o077) == 0,
              (opened.st_mode & 0o077) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino
        else {
            throw ModelStoreLockError.lockFileUnsafe
        }
    }

    private static func isPrivateDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFDIR &&
            (info.st_mode & 0o077) == 0
    }
}
