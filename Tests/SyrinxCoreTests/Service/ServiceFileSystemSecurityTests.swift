import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ServiceFileSystemSecurityTests: XCTestCase {
    func testAncestorReplacementDuringWriteCannotRedirectOutsideManagedTree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let moved = root.appendingPathComponent("managed-original", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let replacement = ReplacementOnce()
        let fileSystem = ServiceFileSystem(beforeOpeningComponent: { component in
            guard component == "managed", replacement.take() else { return }
            try? FileManager.default.moveItem(at: managed, to: moved)
            try? FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
        })

        XCTAssertThrowsError(
            try fileSystem.writePrivateFileAtomically(
                Data("candidate".utf8),
                to: managed.appendingPathComponent("configuration.json")
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("configuration.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testAncestorReplacementDuringDeletionCannotRedirectOutsideManagedTree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let moved = root.appendingPathComponent("managed-original", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: managed.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("nested/keep"))

        let replacement = ReplacementOnce()
        let fileSystem = ServiceFileSystem(beforeOpeningComponent: { component in
            guard component == "managed", replacement.take() else { return }
            try? FileManager.default.moveItem(at: managed, to: moved)
            try? FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
        })

        XCTAssertThrowsError(
            try fileSystem.removeTreeIfPresent(managed.appendingPathComponent("nested"))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("nested/keep").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("nested").path))
    }

    func testRejectsSymlinkAncestorBeforeWriting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let target = link.appendingPathComponent("configuration.json")
        XCTAssertThrowsError(try ServiceFileSystem().writePrivateFileAtomically(Data("secret".utf8), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("configuration.json").path))
    }

    func testRejectsReplacementSymlinkAtWriteTargetAndPreservesOutsideBytes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: false)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        let target = managed.appendingPathComponent("configuration.json")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)

        XCTAssertThrowsError(try ServiceFileSystem().writePrivateFileAtomically(Data("new".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testDescriptorRelativeDeletionRejectsSymlinkReplacementWithoutFollowingIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("keep"))
        try FileManager.default.createSymbolicLink(
            at: managed.appendingPathComponent("replacement"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try ServiceFileSystem().removeTreeIfPresent(managed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
    }

    func testExactReadsRejectOversizedPrivateFilesWithoutReturningSuffixes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = ServiceFileSystem()
        let target = root.appendingPathComponent("configuration.json")
        try fileSystem.writePrivateFileAtomically(Data("{\"value\":12345}".utf8), to: target)

        XCTAssertThrowsError(try fileSystem.readExactPrivateData(target, limit: 8))
        XCTAssertEqual(try Data(contentsOf: target), Data("{\"value\":12345}".utf8))
    }

    func testBoundedLogsHandleNewlineBoundaryInvalidUTF8AndBearerSplits() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = ServiceFileSystem()
        let log = root.appendingPathComponent("service.log")
        let content = Data("old Bearer split-secret\nnew record\n".utf8)
        try fileSystem.writePrivateFileAtomically(content, to: log)

        let value = try fileSystem.readBoundedLogFile(log, limit: 24)
        XCTAssertTrue(value.hasPrefix("[truncated]\n"))
        XCTAssertTrue(value.contains("new record\n"))
        XCTAssertFalse(value.contains("split-secret"))

        let exact = root.appendingPathComponent("exact.log")
        try fileSystem.writePrivateFileAtomically(Data("a\nb\n".utf8), to: exact)
        XCTAssertEqual(try fileSystem.readBoundedLogFile(exact, limit: 4), "a\nb\n")

        let invalid = root.appendingPathComponent("invalid.log")
        var invalidData = Data(String(repeating: "x", count: 30).utf8)
        invalidData.append(0x0A)
        invalidData.append(contentsOf: [0xFF, 0xFF, 0x0A, 0x6F, 0x6B, 0x0A])
        try fileSystem.writePrivateFileAtomically(invalidData, to: invalid)
        let invalidValue = try fileSystem.readBoundedLogFile(invalid, limit: 24)
        XCTAssertTrue(invalidValue.contains("\u{FFFD}"))

        let several = root.appendingPathComponent("several.log")
        try fileSystem.writePrivateFileAtomically(
            Data("oldest\nnewest-safe\nBearer boundary-secret\n".utf8),
            to: several
        )
        let severalValue = try fileSystem.readBoundedLogFile(several, limit: 35)
        XCTAssertEqual(severalValue, "[truncated]\nBearer <redacted>\n")
        XCTAssertFalse(severalValue.contains("boundary-secret"))

        let unterminated = root.appendingPathComponent("unterminated.log")
        try fileSystem.writePrivateFileAtomically(Data(String(repeating: "0", count: 30).utf8), to: unterminated)
        XCTAssertEqual(try fileSystem.readBoundedLogFile(unterminated, limit: 16), "[truncated]\n")
    }

    func testInPlaceRewriteDuringPrivateReadsFailsClosedForConfigSecretAndLogs() throws {
        for (name, read) in [
            ("configuration.json", "exact"),
            ("secret", "secret"),
            ("service.log", "log")
        ] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent(name)
            let original = Data("same-length-value".utf8)
            let replacement = Data("rewritten-value!!".utf8)
            XCTAssertEqual(original.count, replacement.count)
            try ServiceFileSystem().writePrivateFileAtomically(original, to: target)

            let fileSystem = ServiceFileSystem(afterOpeningPrivateRead: { _, descriptor in
                _ = replacement.withUnsafeBytes { bytes in
                    pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
                }
                var times = [
                    timeval(tv_sec: 1, tv_usec: 0),
                    timeval(tv_sec: 1, tv_usec: 0)
                ]
                _ = futimes(descriptor, &times)
            })

            XCTAssertThrowsError(
                try (read == "exact"
                    ? fileSystem.readExactPrivateData(target, limit: 1024)
                    : read == "secret"
                        ? fileSystem.readExactSecretData(target, limit: 1024)
                        : Data(fileSystem.readBoundedLogFile(target, limit: 1024).utf8))
            )
        }
    }

    func testManagedLogSnapshotHoldsTheSharedLockAcrossReadAndMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let original = Data("prior record\n".utf8)
        try ServiceFileSystem().writePrivateFileAtomically(original, to: log)

        let writerStarted = DispatchSemaphore(value: 0)
        let writerAttempted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let writer = ServiceLogWriter(paths: [log], limit: 4 * 1024)
        let fileSystem = ServiceFileSystem(afterOpeningPrivateRead: { _, _ in
            DispatchQueue.global().async {
                writerAttempted.signal()
                try? writer.append("concurrent record")
                writerFinished.signal()
            }
            writerStarted.signal()
            _ = writerAttempted.wait(timeout: .now() + .seconds(2))
            usleep(100_000)
        })

        let snapshot = try XCTUnwrap(
            try fileSystem.snapshotPrivateLogFileIfPresent(log, limit: 4 * 1024)
        )

        XCTAssertEqual(writerStarted.wait(timeout: .now()), .success)
        XCTAssertEqual(writerFinished.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(snapshot.data, original)
        XCTAssertEqual(snapshot.mode & 0o7777, 0o600)
        XCTAssertEqual(writerFinished.wait(timeout: .now() + .seconds(2)), .success)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("concurrent record\n"))
    }

    func testManagedLogSnapshotUsesThePostLockWriterBytesAndMode() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        try ServiceFileSystem().writePrivateFileAtomically(Data("before writer\n".utf8), to: log)

        let writerReadyForCallback = DispatchSemaphore(value: 0)
        let writerReadyForTest = DispatchSemaphore(value: 0)
        let writerRelease = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let snapshotFinished = DispatchSemaphore(value: 0)
        let writerFailed = LockedTestBool()
        let updated = Data("writer completed before snapshot\n".utf8)
        let fileSystem = ServiceFileSystem(beforeAcquiringPrivateReadLock: { _, _ in
            DispatchQueue.global().async {
                let descriptor = open(log.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
                    writerFailed.value = true
                    writerReadyForCallback.signal()
                    writerReadyForTest.signal()
                    writerFinished.signal()
                    if descriptor >= 0 { close(descriptor) }
                    return
                }
                defer {
                    _ = flock(descriptor, LOCK_UN)
                    close(descriptor)
                    writerFinished.signal()
                }
                guard ftruncate(descriptor, 0) == 0 else {
                    writerFailed.value = true
                    writerReadyForCallback.signal()
                    writerReadyForTest.signal()
                    return
                }
                let wrote = updated.withUnsafeBytes { bytes -> Bool in
                    guard let baseAddress = bytes.baseAddress else { return true }
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(
                            descriptor,
                            baseAddress.advanced(by: offset),
                            bytes.count - offset
                        )
                        guard count > 0 else { return false }
                        offset += count
                    }
                    return true
                }
                guard wrote, fchmod(descriptor, mode_t(0o400)) == 0, fsync(descriptor) == 0 else {
                    writerFailed.value = true
                    writerReadyForCallback.signal()
                    writerReadyForTest.signal()
                    return
                }
                writerReadyForCallback.signal()
                writerReadyForTest.signal()
                _ = writerRelease.wait(timeout: .now() + .seconds(2))
            }
            _ = writerReadyForCallback.wait(timeout: .now() + .seconds(2))
            _ = writerFinished.wait(timeout: .now() + .seconds(2))
        })

        let snapshotTask = Task {
            defer { snapshotFinished.signal() }
            return try fileSystem.snapshotPrivateLogFileIfPresent(log, limit: 4 * 1024)
        }

        XCTAssertEqual(writerReadyForTest.wait(timeout: .now() + .seconds(2)), .success)
        XCTAssertEqual(snapshotFinished.wait(timeout: .now()), .timedOut)
        writerRelease.signal()
        let snapshotValue = try await snapshotTask.value
        let snapshot = try XCTUnwrap(snapshotValue)

        XCTAssertFalse(writerFailed.value)
        XCTAssertEqual(snapshot.data, updated)
        XCTAssertEqual(snapshot.mode & 0o7777, 0o400)
    }

    func testManagedLogSnapshotRejectsDirectoryEntryReplacementAfterOpen() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let moved = root.appendingPathComponent("service.log.original")
        try ServiceFileSystem().writePrivateFileAtomically(Data("prior record\n".utf8), to: log)

        let fileSystem = ServiceFileSystem(afterOpeningPrivateRead: { _, _ in
            try? FileManager.default.moveItem(at: log, to: moved)
            try? Data("replacement record\n".utf8).write(to: log)
            chmod(log.path, mode_t(0o600))
        })

        XCTAssertThrowsError(
            try fileSystem.snapshotPrivateLogFileIfPresent(log, limit: 4 * 1024)
        )
        XCTAssertEqual(try Data(contentsOf: moved), Data("prior record\n".utf8))
        XCTAssertEqual(try Data(contentsOf: log), Data("replacement record\n".utf8))
    }

    func testSingleOwnerLogWriterSerializesConcurrentOutputWithinBound() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let fileSystem = ServiceFileSystem()
        let writer = ServiceLogWriter(
            fileSystem: fileSystem,
            paths: [log],
            limit: 8 * 1024
        )
        try writer.prepare()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try? writer.append("\(index) Bearer should-not-leak-\(index)")
                }
            }
        }

        let retained = try Data(contentsOf: log)
        XCTAssertLessThanOrEqual(retained.count, 8 * 1024)
        let text = String(decoding: retained, as: UTF8.self)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 100)
        XCTAssertFalse(text.contains("should-not-leak-"))
        for index in 0..<100 {
            XCTAssertTrue(text.contains("\(index) Bearer <redacted>\n"), "missing record \(index)")
        }
    }

    func testIndependentLogWritersUseTheSameOSLock() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let writerA = ServiceLogWriter(paths: [log], limit: 8 * 1024)
        let writerB = ServiceLogWriter(paths: [log], limit: 8 * 1024)
        try writerA.prepare()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { try writerA.append("writer-a-\(index)") }
                group.addTask { try writerB.append("writer-b-\(index)") }
            }
            try await group.waitForAll()
        }

        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: true).count, 100)
        for index in 0..<50 {
            XCTAssertTrue(text.contains("writer-a-\(index)\n"))
            XCTAssertTrue(text.contains("writer-b-\(index)\n"))
        }
    }

    func testLogWriterWaitsForASeparateProcessHoldingTheLogInodeLock() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let ready = root.appendingPathComponent("ready")
        let release = root.appendingPathComponent("release")
        let writer = ServiceLogWriter(paths: [log], limit: 4 * 1024)
        try writer.prepare()

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-MFcntl=:flock",
            "-e",
            "open(my $f, '+<', $ARGV[0]) or die; flock($f, LOCK_EX) or die; open(my $r, '>', $ARGV[1]) or die; close($r); sleep 1 while !-e $ARGV[2]",
            log.path,
            ready.path,
            release.path
        ]
        try holder.run()
        defer {
            try? Data().write(to: release)
            if holder.isRunning { holder.terminate() }
            holder.waitUntilExit()
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        let finished = LockedTestBool()
        let append = Task {
            try writer.append("after-external-lock")
            finished.value = true
        }
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertFalse(finished.value)
        try Data().write(to: release)
        try await append.value
        XCTAssertTrue(finished.value)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("after-external-lock\n"))
    }

    func testSingleOwnerLogWriterDropsWholeOldRecordsAtTheBound() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let writer = ServiceLogWriter(paths: [log], limit: 48)
        try writer.prepare()

        for index in 0..<10 {
            try writer.append("record-\(index) Bearer secret-\(index)")
        }

        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertLessThanOrEqual(text.utf8.count, 48)
        XCTAssertTrue(text.hasPrefix("[truncated]\n"))
        XCTAssertFalse(text.contains("secret-"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("record-0"))
        XCTAssertTrue(text.contains("record-9 Bearer <redacted>\n"))
    }

    func testSingleOwnerLogWriterRejectsReplacementSymlinkBeforeWriting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let outside = root.appendingPathComponent("outside.log")
        try Data("outside\n".utf8).write(to: outside)
        chmod(outside.path, mode_t(0o600))
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)

        let writer = ServiceLogWriter(paths: [log], limit: 128)
        XCTAssertThrowsError(try writer.append("Bearer secret"))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside\n".utf8))
    }

    func testSingleOwnerLogWriterSanitizesExistingBearerBeforeFirstRecord() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        try ServiceFileSystem().writePrivateFileAtomically(
            Data("old Bearer old-secret\n".utf8),
            to: log
        )

        let writer = ServiceLogWriter(paths: [log], limit: 128)
        try writer.prepare()

        let sanitized = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(sanitized.contains("old-secret"))
        XCTAssertTrue(sanitized.contains("Bearer <redacted>"))
    }

    func testLogRetentionRejectsReplacementSymlinkWithoutTouchingOutsideFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("service.log")
        let outside = root.appendingPathComponent("outside.log")
        try Data("outside\n".utf8).write(to: outside)
        chmod(outside.path, mode_t(0o600))
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)

        XCTAssertThrowsError(try ServiceFileSystem().trimPrivateLogFile(log, limit: 32))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside\n".utf8))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, mode_t(0o700))
        return root
    }
}

private final class LockedTestBool: @unchecked Sendable {
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
