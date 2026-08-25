import Foundation
import Darwin
import XCTest
@testable import SyrinxCore

final class ServiceProcessTests: XCTestCase {
    func testNormalNonzeroExitIsNotReportedAsACrashSignal() async throws {
        let result = try await SystemServiceProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
            timeout: .seconds(2)
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertLessThan(result.exitCode, 128)
    }

    func testProcessOutputIsBoundedAndUsesDirectExecutableArguments() async throws {
        let runner = SystemServiceProcessRunner()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [String(repeating: "x", count: 100_000)],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                timeout: .seconds(2)
            )
            XCTFail("expected bounded output failure")
        } catch let error as ServiceProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testProcessTimeoutTerminatesAndReapsTheChild() async {
        let runner = SystemServiceProcessRunner()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                timeout: .milliseconds(50)
            )
            XCTFail("expected timeout")
        } catch let error as ServiceProcessError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testProcessCancellationTerminatesAndReapsTheChild() async throws {
        let runner = SystemServiceProcessRunner()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                timeout: .seconds(10)
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as ServiceProcessError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTimeoutKillsAndReapsAProcessDescendant() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = SystemServiceProcessRunner()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 10 & echo $! > \(pidFile.path); wait"],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                timeout: .milliseconds(100)
            )
            XCTFail("expected timeout")
        } catch let error as ServiceProcessError {
            XCTAssertEqual(error, .timedOut)
        }
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rawPID = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(rawPID))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCancellationBeforePIDPublicationTerminatesAndReapsTheProcessTree() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-race-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let barrier = ProcessLaunchBarrier()
        let runner = SystemServiceProcessRunner(beforePIDPublication: barrier.hook)
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 10 & echo $! > \(pidFile.path); wait"],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                timeout: .seconds(5)
            )
        }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        barrier.release.signal()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as ServiceProcessError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rawPID = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(rawPID))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

private final class ProcessLaunchBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func hook() {
        entered.signal()
        release.wait()
    }
}
