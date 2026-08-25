import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ModelStoreLockTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)

    func testGlobalLockSerializesIndependentProcesses() async throws {
        let fixture = try Fixture()
        let holder = try fixture.startHelper("global-hold", fixture.ready.path, fixture.release.path)
        defer {
            if holder.isRunning {
                fixture.terminate(holder)
            }
            fixture.remove()
        }
        try await fixture.waitForMarker(fixture.ready, process: holder)

        let blocked = try await fixture.runHelper("global-attempt", "0.15")
        XCTAssertEqual(blocked, 2)

        fixture.touch(fixture.release)
        try await fixture.waitForExit(holder)
        XCTAssertEqual(holder.terminationStatus, 0)
        let acquired = try await fixture.runHelper("global-attempt", "0.5")
        XCTAssertEqual(acquired, 0)
    }

    func testCancelledGlobalWaitReleasesItsDescriptor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try OSBackedModelStoreLock(store: fixture.store)
        let second = try OSBackedModelStoreLock(store: fixture.store)
        let entered = TestGate()
        let release = TestGate()
        let holder = Task {
            try await first.withLock {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()

        let waiting = Task {
            try await second.withLock { true }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }

        await release.open()
        _ = try await holder.value
        _ = try await second.withLock { true }
    }

    func testSharedLeasesCoexistAndExclusiveIsBusyUntilAllSharedLeasesExit() async throws {
        let fixture = try Fixture()
        let first = try fixture.startHelper("shared-hold", commit, fixture.ready.path, fixture.release.path)
        defer {
            if first.isRunning {
                fixture.terminate(first)
            }
            fixture.remove()
        }
        try await fixture.waitForMarker(fixture.ready, process: first)

        let shared = try await fixture.runHelper("shared-attempt", commit)
        XCTAssertEqual(shared, 0)
        let busy = try await fixture.runHelper("exclusive-attempt", commit)
        XCTAssertEqual(busy, 3)

        fixture.touch(fixture.release)
        try await fixture.waitForExit(first)
        XCTAssertEqual(first.terminationStatus, 0)
        let exclusive = try await fixture.runHelper("exclusive-attempt", commit)
        XCTAssertEqual(exclusive, 0)
    }

    func testSIGKILLReleasesGlobalAndRevisionLocks() async throws {
        let fixture = try Fixture()
        let holder = try fixture.startHelper("dual-hold", commit, fixture.ready.path, fixture.release.path)
        defer {
            if holder.isRunning {
                fixture.terminate(holder)
            }
            fixture.remove()
        }
        try await fixture.waitForMarker(fixture.ready, process: holder)
        XCTAssertTrue(kill(holder.processIdentifier, SIGKILL) == 0)
        try await fixture.waitForExit(holder)
        XCTAssertEqual(holder.terminationStatus, SIGKILL)

        let global = try await fixture.runHelper("global-attempt", "0.5")
        XCTAssertEqual(global, 0)
        let exclusive = try await fixture.runHelper("exclusive-attempt", commit)
        XCTAssertEqual(exclusive, 0)
    }

    func testLockFileAttacksFailClosedForBothAuthorities() async throws {
        let attacks: [(String, (URL, URL) throws -> Void)] = [
            ("symlink", { root, lock in
                try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: root.appendingPathComponent("outside"))
            }),
            ("hard-link", { root, lock in
                let source = root.appendingPathComponent("source.lock")
                try Data().write(to: source)
                try FileManager.default.linkItem(at: source, to: lock)
            }),
            ("directory", { _, lock in
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            }),
            ("fifo", { _, lock in
                guard mkfifo(lock.path, mode_t(0o600)) == 0 else { throw POSIXError(.EIO) }
            }),
            ("socket", { _, lock in
                let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
                guard socketDescriptor >= 0 else { throw POSIXError(.EIO) }
                defer { close(socketDescriptor) }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let path = lock.path
                let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
                guard path.utf8.count < pathCapacity else { throw POSIXError(.ENAMETOOLONG) }
                withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { pathPointer in
                        path.withCString { source in
                            _ = strncpy(pathPointer, source, pathCapacity - 1)
                        }
                    }
                }
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else { throw POSIXError(.EIO) }
                var socketInfo = stat()
                guard lstat(lock.path, &socketInfo) == 0,
                      (socketInfo.st_mode & S_IFMT) == S_IFSOCK
                else { throw POSIXError(.EIO) }
            })
        ]

        for authority in [LockAuthority.global, .revision] {
            for (name, attack) in attacks {
                try await assertLockAttack(
                    authority: authority,
                    name: name,
                    attack: attack
                )
            }
        }
    }

    func testDeviceNodeAttackIsRejectedOrExplicitlyUnavailable() async throws {
        for authority in [LockAuthority.global, .revision] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.store.prepareDirectories()
            let lock: URL
            switch authority {
            case .global:
                lock = fixture.store.locksDirectory.appendingPathComponent("selection.lock")
            case .revision:
                try FileManager.default.createDirectory(
                    at: fixture.store.locksDirectory.appendingPathComponent("revisions"),
                    withIntermediateDirectories: false
                )
                lock = fixture.store.locksDirectory
                    .appendingPathComponent("revisions/\(commit).lock")
            }
            let result = mknod(lock.path, mode_t(S_IFCHR) | mode_t(0o600), 0)
            if result != 0 {
                XCTAssertTrue(errno == EPERM || errno == EACCES || errno == ENOTSUP)
                continue
            }
            switch authority {
            case .global:
                let storeLock = try OSBackedModelStoreLock(store: fixture.store)
                do {
                    _ = try await storeLock.withLock(timeout: 0.01) { true }
                    XCTFail("expected device lock-file attack to fail closed")
                } catch let error as ModelStoreLockError {
                    XCTAssertEqual(error, .lockFileUnsafe)
                }
            case .revision:
                let manager = try ModelRevisionLeaseManager(store: fixture.store)
                XCTAssertThrowsError(try manager.tryAcquireShared(commit)) { error in
                    XCTAssertEqual(error as? ModelStoreLockError, .lockFileUnsafe)
                }
                XCTAssertThrowsError(try manager.tryAcquireExclusive(commit)) { error in
                    XCTAssertEqual(error as? ModelStoreLockError, .lockFileUnsafe)
                }
            }
        }
    }

    func testLockFileReplacementAfterPrecheckFailsClosedForBothAuthorities() async throws {
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let lockURL = fixture.store.locksDirectory.appendingPathComponent("selection.lock")
            let hook = ReplacementHook(lockURL: lockURL)
            let lock = try OSBackedModelStoreLock(store: fixture.store, preAcquireHook: hook.run)
            do {
                _ = try await lock.withLock(timeout: 0.1) { true }
                XCTFail("expected replaced global lock file to fail closed")
            } catch let error as ModelStoreLockError {
                XCTAssertEqual(error, .lockFileUnsafe)
            }
            XCTAssertTrue(hook.didReplace)
            let cleanLock = try OSBackedModelStoreLock(store: fixture.store)
            _ = try await cleanLock.withLock(timeout: 0.1) { true }
        }

        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let lockURL = fixture.store.locksDirectory
                .appendingPathComponent("revisions/\(commit).lock")
            let hook = ReplacementHook(lockURL: lockURL)
            let manager = try ModelRevisionLeaseManager(store: fixture.store, preAcquireHook: hook.run)
            do {
                _ = try manager.tryAcquireShared(commit)
                XCTFail("expected replaced revision lock file to fail closed")
            } catch let error as ModelStoreLockError {
                XCTAssertEqual(error, .lockFileUnsafe)
            }
            XCTAssertTrue(hook.didReplace)
            let cleanManager = try ModelRevisionLeaseManager(store: fixture.store)
            guard case .acquired(let lease) = try cleanManager.tryAcquireExclusive(commit) else {
                return XCTFail("replacement file remained locked")
            }
            lease.close()
        }
    }

    private func assertLockAttack(
        authority: LockAuthority,
        name: String,
        attack: (URL, URL) throws -> Void
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()

        switch authority {
        case .global:
            let storeLock = try OSBackedModelStoreLock(store: fixture.store)
            let lock = fixture.store.locksDirectory.appendingPathComponent("selection.lock")
            try attack(fixture.root, lock)
            do {
                _ = try await storeLock.withLock(timeout: 0.01) { true }
                XCTFail("expected acquisition failure for global \(name) attack")
            } catch {
                XCTAssertEqual(error as? ModelStoreLockError, .lockFileUnsafe)
                XCTAssertFalse(String(describing: error).contains(fixture.root.path))
            }
        case .revision:
            let manager = try ModelRevisionLeaseManager(store: fixture.store)
            let lock = fixture.store.locksDirectory
                .appendingPathComponent("revisions/\(commit).lock")
            try attack(fixture.root, lock)
            for operation in ["shared", "exclusive"] {
                do {
                    let result: ModelRevisionLeaseAcquisition
                    if operation == "shared" {
                        result = try manager.tryAcquireShared(commit)
                    } else {
                        result = try manager.tryAcquireExclusive(commit)
                    }
                    if case .acquired(let lease) = result {
                        lease.close()
                    }
                    XCTFail("expected acquisition failure for revision \(operation) \(name) attack")
                } catch {
                    XCTAssertEqual(error as? ModelStoreLockError, .lockFileUnsafe)
                    XCTAssertFalse(String(describing: error).contains(fixture.root.path))
                }
            }
        }
    }

    func testParentReplacementDoesNotRedirectAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lock = try OSBackedModelStoreLock(store: fixture.store)
        let manager = try ModelRevisionLeaseManager(store: fixture.store)
        let originalLocks = fixture.store.locksDirectory.appendingPathExtension("original")
        try FileManager.default.moveItem(at: fixture.store.locksDirectory, to: originalLocks)
        try FileManager.default.createSymbolicLink(at: fixture.store.locksDirectory, withDestinationURL: fixture.root.appendingPathComponent("outside"))
        defer {
            try? FileManager.default.removeItem(at: fixture.store.locksDirectory)
            try? FileManager.default.moveItem(at: originalLocks, to: fixture.store.locksDirectory)
        }

        _ = try await lock.withLock { true }
        let lease = try await manager.acquireShared(commit)
        lease.close()
        XCTAssertFalse(fixture.root.appendingPathComponent("outside/selection.lock").exists)
        XCTAssertFalse(fixture.root.appendingPathComponent("outside/revisions/\(commit).lock").exists)
    }

    func testDifferentCommitHashesUseIndependentLeaseAuthorities() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = try ModelRevisionLeaseManager(store: fixture.store)
        let otherCommit = String(repeating: "b", count: 40)
        guard case .acquired(let first) = try manager.tryAcquireShared(commit) else {
            return XCTFail("first shared lease was busy")
        }
        defer { first.close() }
        guard case .acquired(let second) = try manager.tryAcquireExclusive(otherCommit) else {
            return XCTFail("different revision lease was unexpectedly busy")
        }
        second.close()
        XCTAssertTrue(fixture.store.locksDirectory.appendingPathComponent("revisions/\(commit).lock").exists)
        XCTAssertTrue(fixture.store.locksDirectory.appendingPathComponent("revisions/\(otherCommit).lock").exists)
        XCTAssertFalse(fixture.store.locksDirectory.appendingPathComponent("revisions/(immutableCommit).lock").exists)
    }

    func testCancelledAndTimedOutWaitsDoNotAccumulateDescriptors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let holder = try OSBackedModelStoreLock(store: fixture.store)
        let entered = TestGate()
        let release = TestGate()
        let holding = Task {
            try await holder.withLock {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        let initial = openDescriptorCount()
        for _ in 0..<20 {
            let lock = try OSBackedModelStoreLock(store: fixture.store)
            let waiting = Task { try await lock.withLock(timeout: 1) { true } }
            try await Task.sleep(nanoseconds: 10_000_000)
            waiting.cancel()
            do { _ = try await waiting.value; XCTFail("expected cancellation") } catch is CancellationError {}
        }
        for _ in 0..<20 {
            let lock = try OSBackedModelStoreLock(store: fixture.store)
            do {
                _ = try await lock.withLock(timeout: 0.001) { true }
                XCTFail("expected timeout")
            } catch let error as ModelStoreLockError {
                XCTAssertEqual(error, .timedOut)
            }
        }
        XCTAssertEqual(openDescriptorCount(), initial)
        await release.open()
        _ = try await holding.value
    }

    func testNonFiniteAndOverflowingTimeoutsFailTypedWithoutTrapping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lock = try OSBackedModelStoreLock(store: fixture.store)
        for timeout in [0.0, -1.0, .nan, .infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            do {
                _ = try await lock.withLock(timeout: timeout) { true }
                XCTFail("expected invalid timeout: \(timeout)")
            } catch let error as ModelStoreLockError {
                XCTAssertEqual(error, .timedOut)
            }
        }
    }

    func testPublicInstallerInitializerUsesGlobalOSLockAcrossProcesses() async throws {
        let fixture = try Fixture()
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ModelManifests/parakeet-tdt-0.6b-v3-int8.json")
        let ready = fixture.root.appendingPathComponent("installer-ready")
        let release = fixture.root.appendingPathComponent("installer-release")
        let holder = try fixture.startHelper("installer-hold", manifestURL.path, ready.path, release.path)
        defer {
            if holder.isRunning {
                fixture.terminate(holder)
            }
            fixture.remove()
        }
        try await fixture.waitForMarker(ready, process: holder)
        let blocked = try await fixture.runHelper("global-attempt", "0.15")
        XCTAssertEqual(blocked, 2)
        fixture.touch(release)
        try await fixture.waitForExit(holder)
        XCTAssertEqual(holder.terminationStatus, 1)
    }

    func testLeaseCloseIsIdempotentAndCommitValidationIsShared() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = try ModelRevisionLeaseManager(store: fixture.store)
        let lease = try await manager.acquireShared(commit)
        lease.close()
        lease.close()
        switch try manager.tryAcquireExclusive(commit) {
        case .acquired(let exclusive): exclusive.close()
        case .busy: XCTFail("lease remained held after close")
        }
        XCTAssertThrowsError(try manager.tryAcquireExclusive("not-a-commit")) { error in
            XCTAssertEqual(error as? ModelStoreLockError, .invalidCommit)
        }
        XCTAssertTrue(ModelStore.isValidImmutableCommit(commit))
        XCTAssertFalse(ModelStore.isValidImmutableCommit("not-a-commit"))
    }

    private struct Fixture {
        let root: URL
        let store: ModelStore
        let ready: URL
        let release: URL

        init() throws {
            root = URL(fileURLWithPath: "/tmp/nl-\(UUID().uuidString.prefix(8))", isDirectory: true)
            store = ModelStore(root: root)
            ready = root.appendingPathComponent("ready")
            release = root.appendingPathComponent("release")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func startHelper(_ mode: String, _ arguments: String...) throws -> Process {
            try startHelper(mode, arguments: arguments)
        }

        private func startHelper(_ mode: String, arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = try helperURL()
            process.arguments = [mode, root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }

        func runHelper(_ mode: String, _ arguments: String...) async throws -> Int32 {
            let process = try startHelper(mode, arguments: arguments)
            try await waitForExit(process)
            return process.terminationStatus
        }

        func waitForMarker(_ marker: URL, process: Process) async throws {
            for _ in 0..<100 {
                if marker.exists { return }
                if !process.isRunning {
                    throw NSError(domain: "ModelStoreLockTests", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "helper exited before \(marker.lastPathComponent)"
                    ])
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            terminate(process)
            throw NSError(domain: "ModelStoreLockTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "helper marker timeout: \(marker.lastPathComponent)"
            ])
        }

        func waitForExit(_ process: Process, timeout: TimeInterval = 5) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !process.isRunning else {
                terminate(process)
                throw NSError(domain: "ModelStoreLockTests", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "helper exit timeout"
                ])
            }
        }

        func terminate(_ process: Process) {
            let pid = process.processIdentifier
            if process.isRunning {
                _ = kill(pid, SIGKILL)
            }
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result < 0 && errno == ECHILD) { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }

        func touch(_ url: URL) {
            _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        }

        func helperURL() throws -> URL {
            let bundle = Bundle(for: ModelStoreLockTests.self).bundleURL
            var directory = bundle.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("LockHelper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory = directory.deletingLastPathComponent()
            }
            throw NSError(
                domain: "ModelStoreLockTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "LockHelper not found near \(bundle.lastPathComponent)"]
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private func openDescriptorCount() -> Int {
    var count = 0
    for descriptor in 0..<getdtablesize() {
        if fcntl(descriptor, F_GETFD) >= 0 { count += 1 }
    }
    return count
}

private enum LockAuthority {
    case global
    case revision
}

private final class ReplacementHook: @unchecked Sendable {
    private let stateLock = NSLock()
    private let lockURL: URL
    private var replaced = false

    init(lockURL: URL) {
        self.lockURL = lockURL
    }

    var didReplace: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return replaced
    }

    func run() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !replaced else { return }
        precondition(unlink(lockURL.path) == 0)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        precondition(descriptor >= 0)
        close(descriptor)
        replaced = true
    }
}

private actor TestGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        openState = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if openState { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
