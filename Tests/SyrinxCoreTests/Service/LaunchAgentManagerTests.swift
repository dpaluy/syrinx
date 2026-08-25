import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class LaunchAgentManagerTests: XCTestCase {
    func testPlistIsDeterministicSortedPrivateAndContainsNoSecret() throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let servicePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: "0.1.0-dev"
        )
        let configuration = try ServiceConfiguration(
            port: Port(5092),
            bearerSecret: nil
        )
        let first = ServicePlistBuilder.make(configuration: configuration, paths: servicePaths)
        let second = ServicePlistBuilder.make(configuration: configuration, paths: servicePaths)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(first.contains("<false/>"))
        XCTAssertFalse(first.contains("SuccessfulExit"))
        XCTAssertTrue(first.contains("<key>ThrottleInterval</key>"))
        XCTAssertTrue(first.contains("<key>Umask</key>"))
        XCTAssertTrue(first.contains("<string>serve</string>"))
        XCTAssertFalse(first.contains("SYRINX_API_KEY"))
        XCTAssertFalse(first.contains("secret"))
        XCTAssertTrue(first.contains(servicePaths.executable.path))
        XCTAssertTrue(first.contains(servicePaths.configuration.path))

        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(first.utf8),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, ServiceIdentity.label)
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 30)
        XCTAssertEqual(plist["Umask"] as? Int, 63)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments, [servicePaths.executable.path, "serve"])
        let variables = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: Any])
        XCTAssertEqual(variables["SYRINX_CONFIG_PATH"] as? String, servicePaths.configuration.path)
        XCTAssertEqual((variables["SYRINX_CONFIG_SHA256"] as? String)?.count, 64)
        XCTAssertEqual(variables["SYRINX_SERVICE_LAUNCH"] as? String, "1")
        XCTAssertEqual(variables["SYRINX_HOST"] as? String, "127.0.0.1")
        XCTAssertNil(variables["SYRINX_API_KEY"])
        XCTAssertEqual(plist["WorkingDirectory"] as? String, servicePaths.versionDirectory.path)
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/dev/null")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/dev/null")
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
    }

    func testManagedEnvironmentValuesAreStringsOnly() throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let paths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: "0.1.0-dev"
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(ServicePlistBuilder.make(configuration: ServiceConfiguration(), paths: paths).utf8),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: Any])
        XCTAssertEqual(Set(environment.keys), [
            "SYRINX_CONFIG_PATH", "SYRINX_CONFIG_SHA256", "SYRINX_HOST", "SYRINX_MODEL_ID",
            "SYRINX_PORT", "SYRINX_SERVICE_LAUNCH"
        ])
        XCTAssertTrue(environment.values.allSatisfy { $0 is String }, environment.description)
        XCTAssertEqual(environment["SYRINX_PORT"] as? String, String(ServiceConfiguration().port.value))

        var malformedPlist = plist
        var malformedEnvironment = try XCTUnwrap(malformedPlist["EnvironmentVariables"] as? [String: Any])
        malformedEnvironment["SYRINX_PORT"] = 5092
        malformedPlist["EnvironmentVariables"] = malformedEnvironment
        let malformed = try PropertyListSerialization.data(
            fromPropertyList: malformedPlist,
            format: .xml,
            options: 0
        )
        let manager = LaunchAgentManager(
            paths: paths,
            processRunner: fixture.process
        )
        try FileManager.default.createDirectory(
            at: paths.plist.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try malformed.write(to: paths.plist)
        chmod(paths.plist.path, mode_t(0o600))
        XCTAssertThrowsError(try manager.validateInstalledPlistIfPresent())
    }

    func testInstallCreatesPrivateManagedLogsBeforeBootstrap() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }

        let result = await fixture.commands.run(arguments: ["install", "--json"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        for log in [
            fixture.paths.logs.appendingPathComponent("service.stdout.log"),
            fixture.paths.logs.appendingPathComponent("service.stderr.log")
        ] {
            let mode = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue ?? 0, 0o600, log.path)
        }
        let bootstrapIndex = try XCTUnwrap(fixture.process.calls.firstIndex { $0.first == "bootstrap" })
        XCTAssertTrue(fixture.process.calls[..<bootstrapIndex].contains { $0.first == "print" })
    }

    func testUnsafeManagedLogIsRejectedBeforeBootstrap() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.paths.logs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let outside = fixture.root.appendingPathComponent("outside.log")
        try Data("outside".utf8).write(to: outside)
        chmod(outside.path, mode_t(0o600))
        let log = fixture.paths.logs.appendingPathComponent("service.stdout.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)

        let result = await fixture.commands.run(arguments: ["install", "--json"])

        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertFalse(fixture.process.calls.contains { $0.first == "bootstrap" })
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testLaunchctlUsesGuiDomainAndNeverUsesAUserShell() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let result = await fixture.commands.run(arguments: ["install", "--json"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let plist = fixture.home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
            .path
        XCTAssertTrue(fixture.process.calls.contains(["bootstrap", "gui/\(getuid())", plist]), "\(fixture.process.calls)")
        XCTAssertTrue(fixture.process.calls.contains { $0.first == "kickstart" && $0.contains("gui/\(getuid())/\(ServiceIdentity.label)") }, "\(fixture.process.calls)")
        XCTAssertFalse(fixture.process.calls.contains { $0.contains("sh") || $0.contains("-c") })
    }

    func testMalformedSymlinkAndHardLinkPlistsAreRejectedWithoutReplacement() async throws {
        let cases = ["malformed", "symlink", "hardlink"]
        for kind in cases {
            let fixture = try ServiceCommandFixture()
            defer { fixture.cleanup() }
            let launchAgents = fixture.home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: launchAgents,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let plist = launchAgents.appendingPathComponent("\(ServiceIdentity.label).plist")
            let prior = Data("prior-\(kind)".utf8)
            let source = fixture.root.appendingPathComponent("prior")
            try prior.write(to: source)
            chmod(source.path, mode_t(0o600))
            switch kind {
            case "malformed":
                try Data("<plist>".utf8).write(to: plist)
                chmod(plist.path, mode_t(0o600))
            case "symlink":
                try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: source)
            default:
                try FileManager.default.linkItem(at: source, to: plist)
            }

            let result = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(result.exitCode, 1, kind)
            XCTAssertTrue(result.stdout.contains("unsafe_path"), kind)
            XCTAssertEqual(try Data(contentsOf: source), prior, kind)
            XCTAssertTrue(fixture.process.calls.isEmpty, kind)
        }
    }

    func testLaunchctlTimeoutIsReturnedAsAStableFailure() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let servicePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: "0.1.0-dev"
        )
        let manager = LaunchAgentManager(
            paths: servicePaths,
            processRunner: TimeoutServiceProcessRunner()
        )

        do {
            try await manager.install(plist: ServicePlistBuilder.make(
                configuration: ServiceConfiguration(),
                paths: servicePaths
            ))
            XCTFail("expected launchctl timeout")
        } catch let error as LaunchAgentError {
            XCTAssertEqual(error.operation, "bootstrap")
            XCTAssertFalse(error.output.contains(fixture.root.path))
        }
    }

    func testEmptyAndMalformedLaunchctlOutputAreUnknown() async throws {
        for output in ["", "not a launchctl state"] {
            let fixture = try ServiceCommandFixture()
            defer { fixture.cleanup() }
            let installed = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(installed.exitCode, 0, installed.stderr)
            fixture.process.response = { arguments in
                if arguments.first == "print" {
                    return ServiceProcessResult(exitCode: 0, stdout: output)
                }
                return ServiceProcessResult(exitCode: 0)
            }
            let paths = ServicePaths(
                paths: fixture.paths,
                homeDirectory: fixture.home.path,
                executableURL: fixture.executable,
                version: BuildInfo.from(environment: ["HOME": fixture.home.path]).projectVersion
            )
            let status = try await LaunchAgentManager(
                paths: paths,
                processRunner: fixture.process
            ).status()
            XCTAssertEqual(status.status, .unknown, output)
        }
    }

    func testObservedMacOSLaunchctlPrintShapeProvesTheManagedService() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)

        let servicePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )
        let configurationData = try Data(contentsOf: servicePaths.configuration)
        let observedOutput = observedMacOSLaunchctlPrint(
            paths: servicePaths,
            configuration: ServiceConfiguration(),
            configurationDigest: ServiceConfigurationDigest.forData(configurationData)
        )
        fixture.process.response = { arguments in
            guard arguments.first == "print" else {
                return ServiceProcessResult(exitCode: 0)
            }
            return ServiceProcessResult(exitCode: 0, stdout: observedOutput)
        }

        let status = try await LaunchAgentManager(
            paths: servicePaths,
            processRunner: fixture.process
        ).status()

        XCTAssertEqual(status.status, .ready)
        XCTAssertEqual(status.processID, 123)
        XCTAssertTrue(status.isLoaded)
    }

    func testObservedLaunchctlFieldsFailClosedOnOmissionAliasDuplicateAndEnvironmentMutation() async throws {
        let zeroDigest = String(repeating: "0", count: 64)
        let mutations: [(String, (String) -> String)] = [
            ("missing stdout path", { $0.replacingOccurrences(of: "stdout path = ", with: "missing stdout path = ") }),
            ("missing properties", { $0.replacingOccurrences(of: "properties = runatload | inferred program\n", with: "") }),
            ("stdout alias", { $0.replacingOccurrences(of: "stdout path = ", with: "standard out path = ") }),
            ("duplicate spawn type", { $0.replacingOccurrences(of: "job state = running", with: "spawn type = interactive (4)\n        job state = running") }),
            ("wrong injected key", { $0.replacingOccurrences(of: "XPC_SERVICE_NAME => \(ServiceIdentity.label)", with: "XPC_SERVICE_NAME => rogue.label") }),
            ("unexpected injected key", { $0.replacingOccurrences(of: "OSLogRateLimit => 64", with: "UNEXPECTED_INJECTED_KEY => value\n            OSLogRateLimit => 64") }),
            ("configuration digest", { $0.replacingOccurrences(of: "SYRINX_CONFIG_SHA256 => ", with: "SYRINX_CONFIG_SHA256 => \(zeroDigest)\n            OLD_DIGEST => ") })
        ]

        for (name, mutate) in mutations {
            let fixture = try ServiceCommandFixture()
            let installed = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(installed.exitCode, 0, name)
            let output = mutate(fixtureLaunchctlOutput(fixture))
            fixture.process.response = { arguments in
                arguments.first == "print"
                    ? ServiceProcessResult(exitCode: 0, stdout: output)
                    : ServiceProcessResult(exitCode: 0)
            }
            let paths = ServicePaths(
                paths: fixture.paths,
                homeDirectory: fixture.home.path,
                executableURL: fixture.executable,
                version: BuildInfo.from(environment: [:]).projectVersion
            )

            let status = try await LaunchAgentManager(
                paths: paths,
                processRunner: fixture.process
            ).status()

            XCTAssertEqual(status.status, .unknown, name)
            fixture.cleanup()
        }
    }

    func testNestedLaunchctlFieldsAreIgnoredButTopLevelDuplicatesFailClosed() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)

        let nested = fixtureLaunchctlOutput(fixture).replacingOccurrences(
            of: "    properties = runatload | inferred program",
            with: """
                coalition = {
                    state = nested state
                    resources = {
                        path = nested path
                    }
                }

                properties = runatload | inferred program
            """
        )
        fixture.process.response = { arguments in
            arguments.first == "print"
                ? ServiceProcessResult(exitCode: 0, stdout: nested)
                : ServiceProcessResult(exitCode: 0)
        }
        let manager = LaunchAgentManager(
            paths: fixture.servicePathsForTesting,
            processRunner: fixture.process
        )
        let nestedStatus = try await manager.status()
        XCTAssertEqual(nestedStatus.status, .ready)

        let duplicate = nested.replacingOccurrences(
            of: "    type = LaunchAgent",
            with: "    type = LaunchAgent\n    type = LaunchAgent"
        )
        fixture.process.response = { arguments in
            arguments.first == "print"
                ? ServiceProcessResult(exitCode: 0, stdout: duplicate)
                : ServiceProcessResult(exitCode: 0)
        }
        let duplicateStatus = try await manager.status()
        XCTAssertEqual(duplicateStatus.status, .unknown)
    }

    func testLoadedStoppedStatePairDoesNotRequireOptionalRuntimeFields() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let output = fixtureLaunchctlOutput(fixture)
            .replacingOccurrences(of: "job state = running", with: "job state = exited")
            .replacingOccurrences(of: "state = running", with: "state = not running")
            .replacingOccurrences(of: "minimum runtime = 30\n", with: "")
            .replacingOccurrences(of: "base minimum runtime = 30\n", with: "")
            .replacingOccurrences(of: "pid = 123\n", with: "")
        fixture.process.response = { arguments in
            arguments.first == "print"
                ? ServiceProcessResult(exitCode: 0, stdout: output)
                : ServiceProcessResult(exitCode: 0)
        }
        let manager = LaunchAgentManager(
            paths: fixture.servicePathsForTesting,
            processRunner: fixture.process
        )
        let status = try await manager.status()
        XCTAssertEqual(status.status, .stopped)
        XCTAssertTrue(status.isLoaded)
        XCTAssertNil(status.processID)
    }

    func testUnsupportedLaunchctlStatePairIsUnknown() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let output = fixtureLaunchctlOutput(fixture)
            .replacingOccurrences(of: "job state = running", with: "job state = exited")
        fixture.process.response = { arguments in
            arguments.first == "print"
                ? ServiceProcessResult(exitCode: 0, stdout: output)
                : ServiceProcessResult(exitCode: 0)
        }
        let manager = LaunchAgentManager(
            paths: fixture.servicePathsForTesting,
            processRunner: fixture.process
        )
        let status = try await manager.status()
        XCTAssertEqual(status.status, .unknown)
    }

    func testLaunchctlStateParsingDistinguishesStoppedStartingAndReady() async throws {
        for (output, expected) in [
            ("state = exited\n", ServiceStatusKind.stopped),
            ("state = starting\n", ServiceStatusKind.starting),
            ("state = running\n", ServiceStatusKind.ready)
        ] {
            let fixture = try ServiceCommandFixture()
            defer { fixture.cleanup() }
            let installed = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(installed.exitCode, 0, installed.stderr)
            fixture.process.response = { arguments in
                if arguments.first == "print" {
                    let expectedOutput = fixtureLaunchctlOutput(fixture)
                    let actual = output == "state = starting\n"
                        ? expectedOutput
                            .replacingOccurrences(of: "state = running", with: "state = starting")
                            .replacingOccurrences(of: "job state = running", with: "job state = starting")
                        : output == "state = exited\n"
                            ? expectedOutput.replacingOccurrences(of: "state = running\n", with: "state = exited\n")
                            : expectedOutput
                    return ServiceProcessResult(exitCode: 0, stdout: actual)
                }
                return ServiceProcessResult(exitCode: 0)
            }
            let paths = ServicePaths(
                paths: fixture.paths,
                homeDirectory: fixture.home.path,
                executableURL: fixture.executable,
                version: BuildInfo.from(environment: ["HOME": fixture.home.path]).projectVersion
            )
            let status = try await LaunchAgentManager(
                paths: paths,
                processRunner: fixture.process
            ).status()
            XCTAssertEqual(status.status, expected, output)
        }
    }

    func testLoadedLabelWithoutTrustedManagedPlistIsNeverReady() async throws {
        let cases = ["missing", "symlink", "malformed", "unsafe-permissions", "identity-mismatch"]
        for kind in cases {
            let fixture = try ServiceCommandFixture()
            defer { fixture.cleanup() }
            let installed = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(installed.exitCode, 0, "initial install (kind): (installed.stderr)")

            let plist = ServicePaths(
                paths: fixture.paths,
                homeDirectory: fixture.home.path,
                executableURL: fixture.executable,
                version: BuildInfo.from(environment: ["HOME": fixture.home.path]).projectVersion
            ).plist
            switch kind {
            case "missing":
                try FileManager.default.removeItem(at: plist)
            case "symlink":
                try FileManager.default.removeItem(at: plist)
                let outside = fixture.root.appendingPathComponent("outside-plist")
                try Data("outside".utf8).write(to: outside)
                chmod(outside.path, mode_t(0o600))
                try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: outside)
            case "malformed":
                try Data("not a plist".utf8).write(to: plist)
                chmod(plist.path, mode_t(0o600))
            case "unsafe-permissions":
                chmod(plist.path, mode_t(0o644))
            case "identity-mismatch":
                let original = try String(contentsOf: plist, encoding: .utf8)
                let altered = original.replacingOccurrences(
                    of: ServiceIdentity.label,
                    with: "local.syrinx.untrusted"
                )
                try Data(altered.utf8).write(to: plist)
                chmod(plist.path, mode_t(0o600))
            default:
                XCTFail("unexpected case")
            }

            fixture.process.response = { arguments in
                if arguments.first == "print" {
                    return ServiceProcessResult(exitCode: 0, stdout: "state = running\npid = 123\n")
                }
                return ServiceProcessResult(exitCode: 0)
            }
            let result = await fixture.commands.run(arguments: ["status", "--json"])
            let object = try XCTUnwrap(serviceJSON(result.stdout), kind)
            XCTAssertEqual(result.exitCode, 1, kind)
            XCTAssertEqual(object["status"] as? String, "unknown", kind)
            XCTAssertFalse(result.stdout.contains(fixture.root.path), kind)
            XCTAssertFalse(fixture.process.calls.contains { $0.first == "lsof" }, kind)
        }
    }

    func testRogueLoadedDefinitionIsUnknownEvenWithHealthyPortOwner() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let rogue = fixtureLaunchctlOutput(fixture)
            .replacingOccurrences(of: fixture.executable.path, with: "/tmp/rogue-service")
            .replacingOccurrences(of: "state = running", with: "state = running")
        fixture.process.response = { arguments in
            if arguments.first == "print" {
                return ServiceProcessResult(exitCode: 0, stdout: rogue)
            }
            return ServiceProcessResult(exitCode: 0)
        }

        let result = await fixture.commands.run(arguments: ["status", "--json"])

        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertEqual(serviceJSON(result.stdout)?["status"] as? String, "unknown")
        XCTAssertFalse(fixture.process.calls.contains { $0.first == "lsof" })
    }

    func testDivergentManagedConfigurationRefusesLifecycleMutationBeforeLaunchctl() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let plist = fixture.home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
        let original = try String(contentsOf: plist, encoding: .utf8)
        let altered = original.replacingOccurrences(of: "<string>5092</string>", with: "<string>5093</string>")
        try Data(altered.utf8).write(to: plist)
        chmod(plist.path, mode_t(0o600))
        let before = fixture.process.calls.count

        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 1)
        XCTAssertEqual(serviceJSON(stopped.stdout)?["error_code"] as? String, "unsafe_path")
        XCTAssertEqual(fixture.process.calls.count, before)

        let started = await fixture.commands.run(arguments: ["start", "--json"])
        XCTAssertEqual(started.exitCode, 1)
        XCTAssertFalse(fixture.process.calls.dropFirst(before).contains { call in
            call.first == "bootstrap" || call.first == "kickstart" || call.first == "bootout"
        })
    }

    func testStopRefusesDivergentLoadedDefinitionBeforeBootout() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let rogue = fixtureLaunchctlOutput(fixture)
            .replacingOccurrences(of: "program = \(fixture.executable.path)", with: "program = /tmp/rogue-service")
        let before = fixture.process.calls.count
        fixture.process.response = { arguments in
            arguments.first == "print"
                ? ServiceProcessResult(exitCode: 0, stdout: rogue)
                : ServiceProcessResult(exitCode: 0)
        }
        let paths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )

        do {
            try await LaunchAgentManager(paths: paths, processRunner: fixture.process).stop()
            XCTFail("expected divergent loaded definition refusal")
        } catch let error as LaunchAgentError {
            XCTAssertEqual(error.operation, "stop")
        }

        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertEqual(calls, [["print", "gui/\(getuid())/\(ServiceIdentity.label)"]])
    }
}

private func observedMacOSLaunchctlPrint(
    paths: ServicePaths,
    configuration: ServiceConfiguration,
    configurationDigest: String
) -> String {
    let environment = [
        "SYRINX_CONFIG_PATH => \(paths.configuration.path)",
        "SYRINX_CONFIG_SHA256 => \(configurationDigest)",
        "SYRINX_HOST => \(configuration.host.value)",
        "SYRINX_MODEL_ID => \(configuration.modelID.value)",
        "SYRINX_PORT => \(configuration.port.value)",
        "SYRINX_SERVICE_LAUNCH => 1",
        "OSLogRateLimit => 64",
        "XPC_SERVICE_NAME => \(ServiceIdentity.label)"
    ].joined(separator: "\n")
    return """
    gui/\(getuid())/\(ServiceIdentity.label) = {
        active count = 1
        path = \(paths.plist.path)
        type = LaunchAgent
        state = running

        program = \(paths.executable.path)
        arguments = {
            \(paths.executable.path)
            serve
        }

        working directory = \(paths.versionDirectory.path)
        stdout path = /dev/null
        stderr path = /dev/null
        environment = {
            \(environment)
        }

        domain = gui/\(getuid()) [100025]
        asid = 100025
        minimum runtime = 30
        base minimum runtime = 30
        exit timeout = 5
        runs = 1
        pid = 123
        last exit code = (never exited)

        spawn type = interactive (4)
        job state = running

        properties = runatload | inferred program
    }
    """
}

private struct TimeoutServiceProcessRunner: ServiceProcessRunner {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> ServiceProcessResult {
        throw ServiceProcessError.timedOut
    }
}
