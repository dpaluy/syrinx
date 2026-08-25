import Foundation
import XCTest
@testable import SyrinxCore

final class CommandContractTests: XCTestCase {
    func testTopLevelHelpListsEveryCommand() {
        let runner = CommandRunner(environment: [:])

        for arguments in [["--help"], ["help"]] {
            let result = runner.run(arguments: arguments)

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.stderr.isEmpty)
            for command in ["version", "doctor", "models", "transcribe", "serve", "service"] {
                XCTAssertTrue(result.stdout.contains(command), "missing \(command) from help")
            }
        }
    }

    func testServeIsAsyncOnlyAndSynchronousRunRemainsExplicit() async {
        let runner = CommandRunner(environment: [:])

        let synchronous = runner.run(arguments: ["serve"])
        XCTAssertEqual(synchronous.exitCode, 2)
        XCTAssertEqual(synchronous.stderr, "unsupported command: serve\n")

        let invalidAsync = await runner.runAsync(arguments: ["serve", "--invalid"])
        XCTAssertEqual(invalidAsync.exitCode, 2)
        XCTAssertEqual(invalidAsync.stderr, "usage: syrinx serve\n")
    }

    func testServiceIsAsyncOnlyAndSynchronousRunRemainsExplicit() async {
        let runner = CommandRunner(environment: [:])

        let synchronous = runner.run(arguments: ["service", "status"])
        XCTAssertEqual(synchronous.exitCode, 2)
        XCTAssertEqual(synchronous.stderr, "service commands require async execution\n")

        let invalidAsync = await runner.runAsync(arguments: ["service", "status", "--invalid"])
        XCTAssertEqual(invalidAsync.exitCode, 2)
        XCTAssertEqual(invalidAsync.stderr, ServiceCommands.usage)
    }

    func testVersionJSONContainsEveryRequiredBuildField() throws {
        let result = CommandRunner(environment: ["SYRINX_COMMIT": "contract-commit"])
            .run(arguments: ["version", "--json"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["project_version"] as? String, "0.1.0-dev")
        XCTAssertEqual(object["commit"] as? String, "contract-commit")
        XCTAssertEqual(object["build_target"] as? String, "arm64-apple-macosx14.0")
        XCTAssertEqual(object["build_date"] as? String, "unknown")
        XCTAssertEqual(object["swift_version"] as? String, "6.0")
        XCTAssertEqual(object["fluid_audio"] as? String, "v0.15.5@19600a485baa4998812e4654b70d2bab8f2c9949")
        XCTAssertEqual(object["reproducible_build_status"] as? String, "not-configured")
    }

    func testDoctorJSONContainsDiagnosticsAndDoesNotRequireAInstalledModel() throws {
        let result = CommandRunner(environment: [:]).run(arguments: ["doctor", "--json"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )

        for key in [
            "platform", "architecture", "data_path", "cache_path", "log_path", "host", "port",
            "max_upload_bytes", "max_duration_seconds", "max_jobs", "shutdown_timeout_seconds",
            "port_available", "port_message", "writable_paths", "model_status"
        ] {
            XCTAssertNotNil(object[key], "missing JSON key \(key)")
        }

        XCTAssertEqual(object["host"] as? String, "127.0.0.1")
        XCTAssertEqual(object["port"] as? Int, 5092)
        XCTAssertNotNil(object["port_available"] as? Bool)
        XCTAssertEqual(object["model_status"] as? String, "missing")
    }
}
