import XCTest
@testable import SyrinxCore

final class ServiceCommandContractTests: XCTestCase {
    func testServiceCommandsAreAsyncOnly() async {
        let runner = CommandRunner(environment: [:])

        let synchronous = runner.run(arguments: ["service", "status"])
        XCTAssertEqual(synchronous.exitCode, 2)
        XCTAssertEqual(synchronous.stderr, "service commands require async execution\n")

        let invalid = await runner.runAsync(arguments: ["service", "status", "--invalid"])
        XCTAssertEqual(invalid.exitCode, 2)
        XCTAssertEqual(invalid.stderr, ServiceCommands.usage)
    }

    func testServiceParserAcceptsOnlyDeclaredActionsAndJSON() throws {
        for action in ServiceAction.allCases {
            var arguments = [action.rawValue]
            if action == .purge {
                arguments += ["--confirm", ServiceIdentity.purgeConfirmationToken]
            }
            arguments.append("--json")
            let parsed = try ServiceCommands.parse(arguments: arguments)
            XCTAssertEqual(parsed.action, action)
            XCTAssertTrue(parsed.json)
        }

        XCTAssertThrowsError(try ServiceCommands.parse(arguments: ["status", "--invalid"]))
        XCTAssertThrowsError(try ServiceCommands.parse(arguments: ["status", "--json", "--json"]))
    }

    func testPurgeRequiresTheExactConfirmationToken() throws {
        XCTAssertThrowsError(try ServiceCommands.parse(arguments: ["purge"]))
        XCTAssertThrowsError(try ServiceCommands.parse(arguments: ["purge", "--confirm", "wrong"]))

        let parsed = try ServiceCommands.parse(arguments: [
            "purge", "--confirm", ServiceIdentity.purgeConfirmationToken, "--json"
        ])
        XCTAssertEqual(parsed.action, .purge)
        XCTAssertTrue(parsed.json)
    }

    func testInvalidJSONPurgeConfirmationIsStableAndNonDestructive() async throws {
        let result = await CommandRunner(environment: [:]).runAsync(
            arguments: ["service", "purge", "--json"]
        )

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.isEmpty)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["error_code"] as? String, "purge_confirmation_required")
        XCTAssertTrue(result.stdout.contains("exact confirmation token"))
    }
}
