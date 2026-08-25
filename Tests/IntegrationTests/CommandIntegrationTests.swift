import XCTest
@testable import SyrinxCore

final class CommandIntegrationTests: XCTestCase {
    func testCommandRunnerReturnsResultsWithoutExitingTheProcess() {
        let runner = CommandRunner(environment: [:])

        let version = runner.run(arguments: ["version"])
        let doctor = runner.run(arguments: ["doctor"])

        XCTAssertEqual(version.exitCode, 0)
        XCTAssertEqual(doctor.exitCode, 0)
        XCTAssertTrue(version.stdout.contains("Syrinx 0.1.0-dev"))
        XCTAssertTrue(doctor.stdout.contains("model status: missing"))
    }

    func testUnknownCommandIsAUserError() {
        let result = CommandRunner(environment: [:]).run(arguments: ["serve"])

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("unsupported command"))
    }
}
