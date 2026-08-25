import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ServiceLifecycleLockTests: XCTestCase {
    func testLifecycleLockIsBlockedByASeparateOSProcess() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".lock")
        let ready = root.appendingPathComponent("ready")
        let release = root.appendingPathComponent("release")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        helper.arguments = [
            "-c",
            "import fcntl,os,sys,time; fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); fcntl.flock(fd,fcntl.LOCK_EX); open(sys.argv[2],'w').close(); exec('while not os.path.exists(sys.argv[3]):\\n time.sleep(0.01)')",
            path.path,
            ready.path,
            release.path
        ]
        try helper.run()
        defer {
            try? Data().write(to: release)
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
        }

        for _ in 0..<50 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let lock = ServiceLifecycleLock(path: path, fileSystem: ServiceFileSystem(), timeout: .milliseconds(50))
        do {
            _ = try await lock.withLock { 1 }
            XCTFail("expected cross-process lock timeout")
        } catch let error as ServiceLifecycleLockError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testOSLockSerializesSeparateLockInstancesAndTimesOut() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = ServiceFileSystem()
        let path = root.appendingPathComponent(".lock")
        let first = ServiceLifecycleLock(path: path, fileSystem: fileSystem, timeout: .seconds(2))
        let second = ServiceLifecycleLock(path: path, fileSystem: fileSystem, timeout: .milliseconds(50))

        let holder = Task {
            try await first.withLock {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        do {
            _ = try await second.withLock { 1 }
            XCTFail("expected lock timeout")
        } catch let error as ServiceLifecycleLockError {
            XCTAssertEqual(error, .timedOut)
        }
        _ = try await holder.value
    }

    func testWaitingLockCancellationIsFiniteAndReleasesAfterHolder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = ServiceFileSystem()
        let path = root.appendingPathComponent(".lock")
        let first = ServiceLifecycleLock(path: path, fileSystem: fileSystem, timeout: .seconds(2))
        let second = ServiceLifecycleLock(path: path, fileSystem: fileSystem, timeout: .seconds(2))
        let holder = Task {
            try await first.withLock {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let waiter = Task {
            try await second.withLock { 1 }
        }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("expected cancellation")
        } catch let error as ServiceLifecycleLockError {
            XCTAssertEqual(error, .cancelled)
        }
        holder.cancel()
        _ = try? await holder.value
    }

    func testLockRejectsSymlinkAndHardLinkReplacement() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = ServiceFileSystem()
        let path = root.appendingPathComponent(".lock")
        let outside = root.appendingPathComponent("outside")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        let lock = ServiceLifecycleLock(path: path, fileSystem: fileSystem, timeout: .milliseconds(20))
        do {
            _ = try await lock.withLock { 1 }
            XCTFail("expected symlink rejection")
        } catch let error as ServiceLifecycleLockError {
            XCTAssertEqual(error, .unsafeLock)
        }

        try FileManager.default.removeItem(at: path)
        try FileManager.default.linkItem(at: outside, to: path)
        do {
            _ = try await lock.withLock { 1 }
            XCTFail("expected hard-link rejection")
        } catch let error as ServiceLifecycleLockError {
            XCTAssertEqual(error, .unsafeLock)
        }
    }

    func testLockPathReplacementAfterOpenFailsClosedWithoutOverlappingCriticalSections() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".lock")
        let moved = root.appendingPathComponent(".lock-old")
        let replacement = ReplacementOnce()
        let fileSystem = ServiceFileSystem(afterOpeningPrivateLock: { url, _ in
            guard replacement.take() else { return }
            try? FileManager.default.moveItem(at: url, to: moved)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [
                .posixPermissions: 0o600
            ])
        })
        let firstEntered = LockedBool()
        do {
            _ = try await ServiceLifecycleLock(
                path: path,
                fileSystem: fileSystem,
                timeout: .milliseconds(100)
            ).withLock {
                firstEntered.value = true
                return 1
            }
            XCTFail("expected lock identity replacement failure")
        } catch let error as ServiceLifecycleLockError {
            XCTAssertEqual(error, .unsafeLock)
        }
        XCTAssertFalse(firstEntered.value)

        let secondEntered = LockedBool()
        _ = try await ServiceLifecycleLock(
            path: path,
            fileSystem: ServiceFileSystem(),
            timeout: .milliseconds(100)
        ).withLock {
            secondEntered.value = true
            return 1
        }
        XCTAssertTrue(secondEntered.value)
    }

    func testDeletingLockPathDuringPurgeLikeCriticalSectionCannotSplitAuthority() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".lock")
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = LockedBool()
        let secondEntered = LockedBool()
        let first = ServiceLifecycleLock(path: path, fileSystem: ServiceFileSystem(), timeout: .seconds(2))
        let second = ServiceLifecycleLock(path: path, fileSystem: ServiceFileSystem(), timeout: .milliseconds(150))

        let firstTask = Task {
            try await first.withLock {
                firstEntered.signal()
                try? FileManager.default.removeItem(at: path)
                while !releaseFirst.value {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)

        do {
            _ = try await second.withLock {
                secondEntered.value = true
                return 1
            }
            XCTFail("expected the stable authority to remain held")
        } catch let error as ServiceLifecycleLockError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertFalse(secondEntered.value)
        releaseFirst.value = true
        _ = try? await firstTask.value
    }

    func testSeparateProcessReplacementCannotSplitStableAuthority() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(".lock")
        let moved = root.appendingPathComponent(".lock-old")
        let trigger = root.appendingPathComponent("replace")
        let replacementReady = root.appendingPathComponent("replacement-ready")
        let release = root.appendingPathComponent("release")
        let contenderEntered = root.appendingPathComponent("contender-entered")
        let contenderTimedOut = root.appendingPathComponent("contender-timed-out")

        let replacement = Process()
        replacement.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        replacement.arguments = [
            "-c",
            "import os,sys,time; exec('while not os.path.exists(sys.argv[3]):\\n time.sleep(0.01)'); os.rename(sys.argv[1],sys.argv[2]); fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); os.close(fd); open(sys.argv[4],'w').close(); exec('while not os.path.exists(sys.argv[5]):\\n time.sleep(0.01)')",
            path.path,
            moved.path,
            trigger.path,
            replacementReady.path,
            release.path
        ]
        try replacement.run()
        defer {
            try? Data().write(to: release)
            if replacement.isRunning { replacement.terminate() }
            replacement.waitUntilExit()
        }

        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = LockedBool()
        let first = ServiceLifecycleLock(path: path, fileSystem: ServiceFileSystem(), timeout: .seconds(2))
        let firstTask = Task {
            try await first.withLock {
                firstEntered.signal()
                try Data().write(to: trigger)
                while !releaseFirst.value {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: replacementReady.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementReady.path))

        let contender = Process()
        contender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        contender.arguments = [
            "-c",
            "import fcntl,os,sys,time; fd=os.open(os.path.dirname(sys.argv[1]),os.O_RDONLY|os.O_DIRECTORY); deadline=time.time()+0.3; acquired=False; exec('while time.time() < deadline:\\n try:\\n  fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); acquired=True; break\\n except BlockingIOError:\\n  time.sleep(0.01)'); open(sys.argv[2] if acquired else sys.argv[3],'w').close()",
            path.path,
            contenderEntered.path,
            contenderTimedOut.path
        ]
        try contender.run()
        contender.waitUntilExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: contenderEntered.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: contenderTimedOut.path))

        releaseFirst.value = true
        _ = try? await firstTask.value
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, mode_t(0o700))
        return root
    }
}

private final class ReplacementOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var replaced = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !replaced else { return false }
        replaced = true
        return true
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
