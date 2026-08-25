import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ServiceLifecycleTests: XCTestCase {
    func testInstallStatusRestartStopAndUninstallAreIdempotentAndRetainModels() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let modelFile = fixture.paths.data
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("user-model.marker", isDirectory: false)
        try FileManager.default.createDirectory(
            at: modelFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("retain".utf8).write(to: modelFile)
        chmod(modelFile.path, mode_t(0o600))

        let install = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(install.exitCode, 0, install.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.data.path))

        let status = await fixture.commands.run(arguments: ["status", "--json"])
        XCTAssertEqual(status.exitCode, 0, status.stderr)
        XCTAssertEqual(serviceJSON(status.stdout)?["status"] as? String, "ready")

        let restart = await fixture.commands.run(arguments: ["restart", "--json"])
        XCTAssertEqual(restart.exitCode, 0, restart.stderr)

        let stop = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stop.exitCode, 0, stop.stderr)
        XCTAssertEqual(serviceJSON(stop.stdout)?["status"] as? String, "stopped")

        let uninstall = await fixture.commands.run(arguments: ["uninstall", "--json"])
        XCTAssertEqual(uninstall.exitCode, 0, uninstall.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.data.appendingPathComponent("service").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.logs.path))

        let secondUninstall = await fixture.commands.run(arguments: ["uninstall", "--json"])
        XCTAssertEqual(secondUninstall.exitCode, 0, secondUninstall.stderr)
    }

    func testConcurrentInstallCommandsLeaveOneValidPlist() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }

        async let first = fixture.commands.run(arguments: ["install", "--json"])
        async let second = fixture.commands.run(arguments: ["install", "--json"])
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { $0.exitCode == 0 }, results.map { $0.stderr + $0.stdout }.joined())

        let plistURL = fixture.home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
        let data = try Data(contentsOf: plistURL)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        let mode = try FileManager.default.attributesOfItem(atPath: plistURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o077, 0)
    }

    func testDivergentCallerHomeUsesCanonicalManagedPathsForEveryLifecycleMutation() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)

        let alternateHome = fixture.root.appendingPathComponent("alternate-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alternateHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let canonicalPaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )
        let alternatePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: alternateHome.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )
        let preflight = ServicePreflightDependencies(
            signatureVerifier: ServiceSignatureVerifier { _ in },
            validateModel: { _, _ in },
            validateForegroundStartup: { _, _, _, _ in },
            availableDiskBytes: { _ in 1024 * 1024 * 1024 },
            portIsAvailable: { _ in true },
            minimumFreeBytes: 1
        )
        let alternate = ServiceCommands(
            environment: ["HOME": alternateHome.path],
            paths: fixture.paths,
            executableURL: fixture.executable,
            canonicalAuthorityHome: fixture.home.path,
            dependencies: ServiceCommandDependencies(
                processRunner: fixture.process,
                preflight: preflight,
                healthProbe: ClosureServiceHealthProbe { _, _ in .init(state: .ready) },
                portOwner: { _, _ in "pid:123" }
            )
        )

        let stopped = await alternate.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalPaths.plist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternatePaths.plist.path))

        let started = await alternate.run(arguments: ["start", "--json"])
        XCTAssertEqual(started.exitCode, 0, started.stderr)
        let restarted = await alternate.run(arguments: ["restart", "--json"])
        XCTAssertEqual(restarted.exitCode, 0, restarted.stderr)
        let replaced = await alternate.run(arguments: ["install", "--json"])
        XCTAssertEqual(replaced.exitCode, 0, replaced.stderr)

        let uninstalled = await alternate.run(arguments: ["uninstall", "--json"])
        XCTAssertEqual(uninstalled.exitCode, 0, uninstalled.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalPaths.plist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternatePaths.plist.path))

        let purged = await alternate.run(arguments: [
            "purge", "--confirm", ServiceIdentity.purgeConfirmationToken, "--json"
        ])
        XCTAssertEqual(purged.exitCode, 0, purged.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.data.path))
        XCTAssertFalse(fixture.process.calls.contains { $0.contains(alternatePaths.plist.path) })
        let canonicalPlistCalls = fixture.process.calls.filter { $0.contains(canonicalPaths.plist.path) }
        XCTAssertFalse(canonicalPlistCalls.isEmpty, fixture.process.calls.description)
    }

    func testStartAfterStopBootstrapsBeforeKickstart() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        let before = fixture.process.calls.count

        let started = await fixture.commands.run(arguments: ["start", "--json"])

        XCTAssertEqual(started.exitCode, 0, started.stderr)
        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertEqual(calls.map(\.first), ["print", "print", "bootstrap", "print", "kickstart", "print"])
    }

    func testStartWaitsForDelayedLaunchctlPublicationAndRestoresUnloadedStateOnFailure() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)

        state.delayedPublicationPrints = 2
        let started = await fixture.commands.run(arguments: ["start", "--json"])

        XCTAssertEqual(started.exitCode, 0, started.stderr)
        XCTAssertTrue(state.loaded)
        XCTAssertTrue(state.running)

        let failedState = RunAtLoadLaunchctlState()
        let failedFixture = try ServiceCommandFixture(processResponse: { arguments in
            failedState.response(arguments)
        })
        defer { failedFixture.cleanup() }
        failedState.definitionOutput = fixtureLaunchctlOutput(failedFixture)
        let failedInstall = await failedFixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(failedInstall.exitCode, 0, failedInstall.stderr)
        let failedStop = await failedFixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(failedStop.exitCode, 0, failedStop.stderr)
        failedState.failNextKickstart = true

        let failedStart = await failedFixture.commands.run(arguments: ["start", "--json"])

        XCTAssertEqual(failedStart.exitCode, 1, failedStart.stderr)
        XCTAssertFalse(failedState.loaded)
        XCTAssertFalse(failedState.running)
    }

    func testFailedStartFromLoadedStoppedRestoresLoadedStoppedWithoutBootout() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        state.publishLoadedStopped()
        state.failNextKickstart = true
        let priorStoppedPrints = state.loadedStoppedPrintCount
        let before = fixture.process.calls.count

        let failed = await fixture.commands.run(arguments: ["start", "--json"])

        XCTAssertEqual(failed.exitCode, 1, failed.stderr)
        XCTAssertTrue(state.loaded)
        XCTAssertFalse(state.running)
        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertFalse(calls.contains { $0.first == "bootout" }, calls.description)
        XCTAssertFalse(calls.contains { $0.first == "kill" }, calls.description)
        XCTAssertTrue(calls.contains { $0.first == "kickstart" }, calls.description)
        XCTAssertGreaterThan(state.loadedStoppedPrintCount, priorStoppedPrints)
    }

    func testLoadedStoppedRollbackPollsDelayedGracefulShutdown() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        state.publishLoadedStopped()
        state.failNextKickstart = true
        state.delayedStopPrints = 2
        let before = fixture.process.calls.count

        let failed = await fixture.commands.run(arguments: ["restart", "--json"])

        XCTAssertEqual(failed.exitCode, 1, failed.stderr)
        XCTAssertTrue(state.loaded)
        XCTAssertFalse(state.running)
        XCTAssertGreaterThanOrEqual(state.stopPollCount, 3)
        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertTrue(calls.contains { $0.first == "kill" }, calls.description)
        let restoreBootstrap = try XCTUnwrap(calls.lastIndex(where: { $0.first == "bootstrap" }))
        XCTAssertFalse(calls.dropFirst(restoreBootstrap + 1).contains { $0.first == "bootout" }, calls.description)
    }

    func testStableAbsenceCatchesLateLaunchctlPublicationBeforeCandidateCleanup() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        state.notFoundAfterBootstrapPrints = 1
        state.failNextKickstart = true

        let failed = await fixture.commands.run(arguments: ["start", "--json"])

        XCTAssertEqual(failed.exitCode, 1, failed.stderr)
        XCTAssertFalse(state.loaded)
        XCTAssertTrue(fixture.process.calls.contains { $0.first == "bootout" })
        XCTAssertGreaterThanOrEqual(state.notFoundPrintCount, 1)
    }

    func testStableAbsenceWaitsThroughLatePublicationAfterMoreThanThreeAbsentSamples() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        state.latePublicationAfterBootoutPrints = 4
        state.failNextKickstart = true

        let failed = await fixture.commands.run(arguments: ["start", "--json"])

        XCTAssertEqual(failed.exitCode, 1, failed.stderr)
        XCTAssertFalse(state.loaded, fixture.process.calls.description)
        XCTAssertFalse(state.running, fixture.process.calls.description)
        XCTAssertGreaterThanOrEqual(state.notFoundPrintCount, 4)
    }

    func testFailedReplacementRestoresManagedLogBytesAndModes() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)

        let stdout = fixture.paths.logs.appendingPathComponent("service.stdout.log")
        let stderr = fixture.paths.logs.appendingPathComponent("service.stderr.log")
        let priorStdout = Data("prior stdout\nBearer stdout-secret\n".utf8)
        let priorStderr = Data("prior stderr\nBearer stderr-secret\n".utf8)
        try priorStdout.write(to: stdout)
        try priorStderr.write(to: stderr)
        chmod(stdout.path, mode_t(0o600))
        chmod(stderr.path, mode_t(0o600))
        let stdoutMode = try FileManager.default.attributesOfItem(atPath: stdout.path)[.posixPermissions] as? NSNumber
        let stderrMode = try FileManager.default.attributesOfItem(atPath: stderr.path)[.posixPermissions] as? NSNumber
        fixture.process.response = { arguments in
            let result = state.response(arguments)
            if arguments.first == "kickstart", result.exitCode != 0 {
                try? Data("candidate stdout\n".utf8).write(to: stdout)
                try? Data("candidate stderr\n".utf8).write(to: stderr)
            }
            return result
        }
        state.failNextKickstart = true

        let failed = await fixture.commands.run(arguments: ["install", "--json"])

        XCTAssertEqual(failed.exitCode, 1, failed.stderr)
        XCTAssertEqual(try Data(contentsOf: stdout), priorStdout)
        XCTAssertEqual(try Data(contentsOf: stderr), priorStderr)
        XCTAssertEqual(
            try (FileManager.default.attributesOfItem(atPath: stdout.path)[.posixPermissions] as? NSNumber)?.intValue,
            stdoutMode?.intValue
        )
        XCTAssertEqual(
            try (FileManager.default.attributesOfItem(atPath: stderr.path)[.posixPermissions] as? NSNumber)?.intValue,
            stderrMode?.intValue
        )
        XCTAssertTrue(state.loaded)
        XCTAssertTrue(state.running)
    }

    func testNeverPublishedCandidateReturnsWithinFinitePublicationBudget() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        state.beginNeverPublishing()
        let manager = LaunchAgentManager(
            paths: fixture.servicePathsForTesting,
            processRunner: fixture.process
        )

        let started = ContinuousClock.now
        do {
            _ = try await manager.waitForLoaded(timeout: .milliseconds(100))
            XCTFail("expected a bounded publication timeout")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertGreaterThan(state.notFoundPrintCount, 0)
    }

    func testCancelledStartCleansPublishedCandidateAndLeavesItUnloaded() async throws {
        let fixture = try CancellationCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        fixture.runner.cancelOn = "kickstart"

        let task = Task { await fixture.commands.run(arguments: ["start", "--json"]) }
        fixture.cancellation.task = task
        let result = await task.value

        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "cancelled")
        XCTAssertFalse(fixture.runner.state.loaded)
        XCTAssertFalse(fixture.runner.state.running)
    }

    func testRestartFromStoppedBootstrapsBeforeKickstart() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        let before = fixture.process.calls.count

        let restarted = await fixture.commands.run(arguments: ["restart", "--json"])

        XCTAssertEqual(restarted.exitCode, 0, restarted.stderr)
        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertEqual(calls.map(\.first), ["print", "print", "print", "bootstrap", "print", "kickstart", "print"])
    }

    func testInstallCancellationAfterEachCandidateTransitionRestoresPriorRunningService() async throws {
        for transition in ["bootout", "bootstrap", "kickstart"] {
            let fixture = try CancellationCommandFixture()
            defer { fixture.cleanup() }
            let installed = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(installed.exitCode, 0, transition)
            let servicePaths = fixture.servicePaths
            let priorPlist = try Data(contentsOf: servicePaths.plist)
            let priorConfiguration = try Data(contentsOf: servicePaths.persistentConfiguration)
            fixture.runner.cancelOn = transition

            let task = Task { await fixture.commands.run(arguments: ["install", "--json"]) }
            fixture.cancellation.task = task
            let result = await task.value

            XCTAssertEqual(result.exitCode, 1, transition)
            XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "cancelled", result.stderr + result.stdout + transition + " calls=" + fixture.runner.calls.description)
            XCTAssertEqual(try Data(contentsOf: servicePaths.plist), priorPlist, transition)
            XCTAssertEqual(try Data(contentsOf: servicePaths.persistentConfiguration), priorConfiguration, transition)
            XCTAssertTrue(fixture.runner.state.loaded, transition)
            XCTAssertTrue(fixture.runner.state.running, transition)
            XCTAssertTrue(fixture.runner.calls.contains { $0.first == transition }, transition)
        }
    }

    func testInstallCancellationDuringHealthRestoresPriorRunningService() async throws {
        let fixture = try CancellationCommandFixture(cancelHealthOnCall: 2)
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let servicePaths = fixture.servicePaths
        let priorPlist = try Data(contentsOf: servicePaths.plist)
        let priorConfiguration = try Data(contentsOf: servicePaths.persistentConfiguration)

        let task = Task { await fixture.commands.run(arguments: ["install", "--json"]) }
        fixture.cancellation.task = task
        let result = await task.value

        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "cancelled")
        XCTAssertEqual(try Data(contentsOf: servicePaths.plist), priorPlist)
        XCTAssertEqual(try Data(contentsOf: servicePaths.persistentConfiguration), priorConfiguration)
        XCTAssertTrue(fixture.runner.state.loaded)
        XCTAssertTrue(fixture.runner.state.running)
    }

    func testRestartCancellationAfterEachCandidateTransitionRestoresPriorRunningService() async throws {
        for transition in ["bootout", "bootstrap", "kickstart"] {
            let fixture = try CancellationCommandFixture()
            defer { fixture.cleanup() }
            let installed = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(installed.exitCode, 0, installed.stderr + transition)
            fixture.runner.cancelOn = transition

            let task = Task { await fixture.commands.run(arguments: ["restart", "--json"]) }
            fixture.cancellation.task = task
            let result = await task.value

            XCTAssertEqual(result.exitCode, 1, transition)
            XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "cancelled", result.stderr + result.stdout + transition)
            XCTAssertTrue(fixture.runner.state.loaded, transition)
            XCTAssertTrue(fixture.runner.state.running, transition)
            XCTAssertTrue(fixture.runner.calls.contains { $0.first == transition }, transition)
        }
    }

    func testRestartCancellationDuringHealthRestoresPriorRunningService() async throws {
        let fixture = try CancellationCommandFixture(cancelHealthOnCall: 2)
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)

        let task = Task { await fixture.commands.run(arguments: ["restart", "--json"]) }
        fixture.cancellation.task = task
        let result = await task.value

        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "cancelled")
        XCTAssertTrue(fixture.runner.state.loaded)
        XCTAssertTrue(fixture.runner.state.running)
    }

    func testNormalUninstallRetainsExactPersistentConfigurationAndReinstallMaterializesRuntimeCopy() async throws {
        let fixture = try ServiceCommandFixture(environmentOverrides: [
            "SYRINX_PORT": "5093",
            "SYRINX_MODEL_ID": "retained-model"
        ])
        defer { fixture.cleanup() }

        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let servicePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: ["SYRINX_PORT": "5093"]).projectVersion
        )
        let fileSystem = ServiceFileSystem()
        let retained = try fileSystem.readBoundedPrivateData(
            servicePaths.persistentConfiguration,
            limit: 512 * 1024
        )
        XCTAssertEqual(retained, try fileSystem.readBoundedPrivateData(servicePaths.configuration, limit: 512 * 1024))

        let uninstalled = await fixture.commands.run(arguments: ["uninstall", "--json"])
        XCTAssertEqual(uninstalled.exitCode, 0, uninstalled.stderr)
        XCTAssertEqual(
            retained,
            try fileSystem.readBoundedPrivateData(servicePaths.persistentConfiguration, limit: 512 * 1024)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: servicePaths.configuration.path))

        let reinstalled = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(reinstalled.exitCode, 0, reinstalled.stderr)
        XCTAssertEqual(
            retained,
            try fileSystem.readBoundedPrivateData(servicePaths.persistentConfiguration, limit: 512 * 1024)
        )
        XCTAssertEqual(
            retained,
            try fileSystem.readBoundedPrivateData(servicePaths.configuration, limit: 512 * 1024)
        )
    }

    func testReinstallWithoutOriginalEnvironmentUsesRetainedConfiguration() async throws {
        let fixture = try ServiceCommandFixture(environmentOverrides: [
            "SYRINX_PORT": "5094",
            "SYRINX_MODEL_ID": "retained-without-environment"
        ])
        defer { fixture.cleanup() }

        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let servicePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )
        let fileSystem = ServiceFileSystem()
        let retained = try fileSystem.readBoundedPrivateData(
            servicePaths.persistentConfiguration,
            limit: 512 * 1024
        )
        let uninstalled = await fixture.commands.run(arguments: ["uninstall", "--json"])
        XCTAssertEqual(uninstalled.exitCode, 0, uninstalled.stderr)

        let preflight = ServicePreflightDependencies(
            signatureVerifier: ServiceSignatureVerifier { _ in },
            validateModel: { _, _ in },
                validateForegroundStartup: { _, _, _, _ in },
            availableDiskBytes: { _ in 1024 * 1024 * 1024 },
            portIsAvailable: { _ in true },
            minimumFreeBytes: 1
        )
        let replacement = ServiceCommands(
            environment: ["HOME": fixture.home.path],
            paths: fixture.paths,
            executableURL: fixture.executable,
            canonicalAuthorityHome: fixture.home.path,
            dependencies: ServiceCommandDependencies(
                processRunner: fixture.process,
                preflight: preflight,
                healthProbe: ClosureServiceHealthProbe { _, _ in .init(state: .ready) },
                portOwner: { _, _ in "pid:123" }
            )
        )

        let reinstalled = await replacement.run(arguments: ["install", "--json"])
        XCTAssertEqual(reinstalled.exitCode, 0, reinstalled.stderr)
        XCTAssertEqual(
            retained,
            try fileSystem.readBoundedPrivateData(servicePaths.persistentConfiguration, limit: 512 * 1024)
        )
        XCTAssertEqual(
            retained,
            try fileSystem.readBoundedPrivateData(servicePaths.configuration, limit: 512 * 1024)
        )
        let snapshot = try JSONDecoder().decode(ServiceConfigurationSnapshot.self, from: retained)
        XCTAssertEqual(snapshot.port, 5094)
        XCTAssertEqual(snapshot.modelID, "retained-without-environment")
        let plist = try fileSystem.readBoundedPrivateFile(servicePaths.plist, limit: 256 * 1024)
        XCTAssertTrue(plist.contains("<string>5094</string>"))
        XCTAssertTrue(plist.contains("retained-without-environment"))
    }

    func testReplacementInstallBootsOutPriorJobBeforeBootstrap() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let first = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        let priorCount = fixture.process.calls.count

        let replacement = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(replacement.exitCode, 0, replacement.stderr)
        let calls = Array(fixture.process.calls.dropFirst(priorCount))
        let bootout = try XCTUnwrap(calls.firstIndex(where: { $0.first == "bootout" }))
        let bootstrap = try XCTUnwrap(calls.firstIndex(where: { $0.first == "bootstrap" }))
        XCTAssertLessThan(bootout, bootstrap, calls.description)
    }

    func testFailedReplacementRestoresStoppedPriorJobWithoutKickstartingIt() async throws {
        let health = SequenceServiceHealthProbe([
            .init(state: .ready),
            .init(state: .timedOut),
            .init(state: .ready)
        ])
        let fixture = try ServiceCommandFixture(healthProbeOverride: health)
        defer { fixture.cleanup() }
        let first = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        let beforeReplacement = fixture.process.calls.count

        let failed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(failed.exitCode, 1)

        let calls = Array(fixture.process.calls.dropFirst(beforeReplacement))
        XCTAssertEqual(calls.filter { $0.first == "bootout" }.count, 1, calls.description)
        XCTAssertEqual(calls.filter { $0.first == "bootstrap" }.count, 1, calls.description)
        XCTAssertTrue(calls.last?.first == "print", calls.description)
        let cleanup = try XCTUnwrap(calls.firstIndex(where: { $0.first == "bootout" }))
        XCTAssertTrue(calls[..<cleanup].contains { $0.first == "kickstart" }, calls.description)
        XCTAssertFalse(calls.dropFirst(cleanup + 1).contains { $0.first == "kickstart" }, calls.description)
        XCTAssertFalse(calls.contains { $0.first == "kill" }, calls.description)
    }

    func testStoppedReplacementUsesRunAtLoadStateWithoutBootstrappingRollback() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)

        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let stopped = await fixture.commands.run(arguments: ["stop", "--json"])
        XCTAssertEqual(stopped.exitCode, 0, stopped.stderr)
        state.failNextBootstrap = true
        let before = fixture.process.calls.count

        let failed = await fixture.commands.run(arguments: ["install", "--json"])

        XCTAssertEqual(failed.exitCode, 1, failed.stderr)
        XCTAssertFalse(state.loaded)
        let calls = Array(fixture.process.calls.dropFirst(before))
        let target = "gui/\(getuid())/\(ServiceIdentity.label)"
        let plist = fixture.home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
            .path
        XCTAssertEqual(calls.prefix(3), [
            ["print", target],
            ["print", target],
            ["bootstrap", "gui/\(getuid())", plist]
        ])
        XCTAssertEqual(calls.filter { $0.first == "bootstrap" }.count, 1)
        XCTAssertFalse(calls.contains { $0.first == "kickstart" }, calls.description)
    }

    func testFailedRestartReturnsStableFailureWhenPriorRestorationIsNotVerified() async throws {
        let health = SequenceServiceHealthProbe([
            .init(state: .ready),
            .init(state: .timedOut),
            .init(state: .timedOut)
        ])
        let fixture = try ServiceCommandFixture(healthProbeOverride: health)
        defer { fixture.cleanup() }

        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let failed = await fixture.commands.run(arguments: ["restart", "--json"])

        XCTAssertEqual(failed.exitCode, 1, failed.stderr)
        XCTAssertEqual(serviceJSON(failed.stdout)?["error_code"] as? String, "launchctl_failed")
        XCTAssertTrue(failed.stdout.contains("prior service restoration was not verified"))
        XCTAssertGreaterThanOrEqual(fixture.process.calls.filter { $0.first == "kickstart" }.count, 2)
    }

    func testMissingPlistRefusesStopAndUninstallBeforeLaunchctlMutation() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let plist = fixture.home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
        try FileManager.default.removeItem(at: plist)
        let before = fixture.process.calls.count

        let result = await fixture.commands.run(arguments: ["uninstall", "--json"])

        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "unsafe_path")
        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertEqual(calls.first, ["print", "gui/\(getuid())/\(ServiceIdentity.label)"])
        XCTAssertFalse(calls.contains { $0.contains(plist.path) })
    }

    func testInstallRejectsLoadedOrphanLabelAndUninstallStopsExactTarget() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)

        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let plist = fixture.home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
        try FileManager.default.removeItem(at: plist)
        let beforeInstall = fixture.process.calls.count

        let rejected = await fixture.commands.run(arguments: ["install", "--json"])

        XCTAssertEqual(rejected.exitCode, 1, rejected.stderr)
        XCTAssertEqual(serviceJSON(rejected.stdout)?["error_code"] as? String, "launchctl_failed")
        XCTAssertEqual(serviceJSON(rejected.stdout)?["repair_command"] as? String, "syrinx service uninstall")
        XCTAssertEqual(
            Array(fixture.process.calls.dropFirst(beforeInstall)),
            [["print", "gui/\(getuid())/\(ServiceIdentity.label)"]]
        )

        let uninstalled = await fixture.commands.run(arguments: ["uninstall", "--json"])
        XCTAssertEqual(uninstalled.exitCode, 1, uninstalled.stderr)
        XCTAssertFalse(fixture.process.calls.contains([
            "bootout", "gui/\(getuid())/\(ServiceIdentity.label)"
        ]))
    }

    func testInstallRejectsUnknownPriorStateBeforeMutation() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }

        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let before = fixture.process.calls.count
        fixture.process.response = { arguments in
            if arguments.first == "print" {
                return ServiceProcessResult(exitCode: 0, stdout: "not a launchctl state")
            }
            return ServiceProcessResult(exitCode: 0)
        }

        let rejected = await fixture.commands.run(arguments: ["install", "--json"])

        XCTAssertEqual(rejected.exitCode, 1, rejected.stderr)
        XCTAssertEqual(serviceJSON(rejected.stdout)?["error_code"] as? String, "launchctl_failed")
        XCTAssertEqual(
            serviceJSON(rejected.stdout)?["repair_command"] as? String,
            "syrinx service status"
        )
        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertEqual(calls, [["print", "gui/\(getuid())/\(ServiceIdentity.label)"]])
    }

    func testAllLoadedDefinitionMutationsRefuseADivergentDefinitionWithoutLaunchctlMutation() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let rogue = fixtureLaunchctlOutput(fixture)
            .replacingOccurrences(of: "program = \(fixture.executable.path)", with: "program = /tmp/rogue-service")
        fixture.process.response = { arguments in
            arguments.first == "print"
                ? ServiceProcessResult(exitCode: 0, stdout: rogue)
                : ServiceProcessResult(exitCode: 0)
        }
        let before = fixture.process.calls.count
        let actions: [[String]] = [
            ["stop", "--json"],
            ["start", "--json"],
            ["restart", "--json"],
            ["uninstall", "--json"],
            ["purge", "--confirm", ServiceIdentity.purgeConfirmationToken, "--json"]
        ]

        for arguments in actions {
            let result = await fixture.commands.run(arguments: arguments)
            XCTAssertEqual(result.exitCode, 1, arguments.description)
        }

        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertFalse(calls.contains { call in
            ["bootout", "kill", "bootstrap", "kickstart"].contains(call.first)
        }, calls.description)
    }

    func testAllLoadedDefinitionMutationsRefuseMissingPlistWithoutLaunchctlMutation() async throws {
        let state = RunAtLoadLaunchctlState()
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            state.response(arguments)
        })
        defer { fixture.cleanup() }
        state.definitionOutput = fixtureLaunchctlOutput(fixture)
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let plist = fixture.home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
        try FileManager.default.removeItem(at: plist)
        let before = fixture.process.calls.count
        let actions: [[String]] = [
            ["stop", "--json"],
            ["start", "--json"],
            ["restart", "--json"],
            ["uninstall", "--json"],
            ["purge", "--confirm", ServiceIdentity.purgeConfirmationToken, "--json"]
        ]

        for arguments in actions {
            let result = await fixture.commands.run(arguments: arguments)
            XCTAssertEqual(result.exitCode, 1, arguments.description)
        }

        let calls = Array(fixture.process.calls.dropFirst(before))
        XCTAssertFalse(calls.contains { call in
            ["bootout", "kill", "bootstrap", "kickstart"].contains(call.first)
        }, calls.description)
    }

    func testInstallFailurePreservesPriorPlistAndConfigurationBytes() async throws {
        let health = SequenceServiceHealthProbe([
            .init(state: .ready),
            .init(state: .timedOut),
            .init(state: .ready)
        ])
        let fixture = try ServiceCommandFixture(healthProbeOverride: health)
        defer { fixture.cleanup() }
        let first = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        let servicePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: ["HOME": fixture.home.path]).projectVersion
        )
        let fileSystem = ServiceFileSystem()
        let priorPlist = try fileSystem.readBoundedPrivateData(servicePaths.plist, limit: 256 * 1024)
        let priorConfiguration = try fileSystem.readBoundedPrivateData(
            servicePaths.persistentConfiguration,
            limit: 512 * 1024
        )

        let failed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertEqual(priorPlist, try fileSystem.readBoundedPrivateData(servicePaths.plist, limit: 256 * 1024))
        XCTAssertEqual(
            priorConfiguration,
            try fileSystem.readBoundedPrivateData(servicePaths.persistentConfiguration, limit: 512 * 1024)
        )
        let bootstrapCalls = fixture.process.calls.filter { $0.first == "bootstrap" }
        XCTAssertGreaterThanOrEqual(bootstrapCalls.count, 2)
        XCTAssertEqual(fixture.process.calls.filter { $0.first == "bootout" }.count, 2)
    }

    func testHealthyUnrelatedListenerCannotSatisfyInstallReadiness() async throws {
        let fixture = try ServiceCommandFixture(portOwner: { _, _ in nil })
        defer { fixture.cleanup() }
        let result = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(serviceJSON(result.stdout)?["status"] as? String, "unhealthy")
        XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "health_timeout")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("Library/LaunchAgents/\(ServiceIdentity.label).plist").path
        ))
    }

    func testHealthTimeoutReturnsRedactedDiagnostics() async throws {
        let fixture = try ServiceCommandFixture(health: .init(state: .timedOut))
        defer { fixture.cleanup() }

        let result = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(serviceJSON(result.stdout)?["status"] as? String, "unhealthy")
        XCTAssertEqual(serviceJSON(result.stdout)?["repair_command"] as? String, "syrinx service status")
        XCTAssertFalse(result.stdout.contains(fixture.root.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("Library/LaunchAgents/\(ServiceIdentity.label).plist").path
        ))
    }

    func testStatusReturnsNonzeroForUnhealthyHealth() async throws {
        let probe = SequenceServiceHealthProbe([
            .init(state: .ready),
            .init(state: .timedOut)
        ])
        let fixture = try ServiceCommandFixture(healthProbeOverride: probe)
        defer { fixture.cleanup() }
        let installed = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(installed.exitCode, 0, installed.stderr)
        let status = await fixture.commands.run(arguments: ["status", "--json"])
        XCTAssertEqual(status.exitCode, 1)
        XCTAssertEqual(serviceJSON(status.stdout)?["status"] as? String, "unhealthy")
    }

    func testLaunchctlNonzeroIsBoundedAndRedacted() async throws {
        let fixture = try ServiceCommandFixture(processResponse: { arguments in
            if arguments.first == "kickstart" {
                return ServiceProcessResult(exitCode: 1, stderr: "failed /private/secret-location Bearer secret-token")
            }
            return ServiceProcessResult(exitCode: 0)
        })
        defer { fixture.cleanup() }

        let result = await fixture.commands.run(arguments: ["install"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("launchctl_failed"))
        XCTAssertFalse(result.stderr.contains(fixture.root.path))
        XCTAssertFalse(result.stderr.contains("secret-token"))
    }

    func testLogsArePrivateBoundedAndBearerRedacted() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let install = await fixture.commands.run(arguments: ["install"])
        XCTAssertEqual(install.exitCode, 0, install.stderr)

        let fileSystem = ServiceFileSystem()
        let log = fixture.paths.logs.appendingPathComponent("service.stdout.log")
        let content = Data((String(repeating: "x", count: 40_000) + " Bearer secret-token\n").utf8)
        try fileSystem.writePrivateFileAtomically(content, to: log)

        let result = await fixture.commands.run(arguments: ["logs"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains("secret-token"))
        XCTAssertFalse(result.stdout.contains(fixture.root.path))
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 66_000)
    }

    func testPurgeRefusesUnsafeLinksBeforeStoppingAndDeletesOnlyAfterExactConfirmation() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let install = await fixture.commands.run(arguments: ["install"])
        XCTAssertEqual(install.exitCode, 0, install.stderr)

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = fixture.paths.data.appendingPathComponent("escape", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let refused = await fixture.commands.run(arguments: [
            "purge", "--confirm", ServiceIdentity.purgeConfirmationToken, "--json"
        ])
        XCTAssertEqual(refused.exitCode, 1)
        XCTAssertTrue(refused.stdout.contains("unsafe_path"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.data.path))

        try FileManager.default.removeItem(at: link)
        let hardLinkSource = fixture.root.appendingPathComponent("hard-link-source")
        try Data("hard-link".utf8).write(to: hardLinkSource)
        let hardLink = fixture.paths.data.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: hardLinkSource, to: hardLink)
        let hardLinkRefused = await fixture.commands.run(arguments: [
            "purge", "--confirm", ServiceIdentity.purgeConfirmationToken, "--json"
        ])
        XCTAssertEqual(hardLinkRefused.exitCode, 1)
        XCTAssertTrue(hardLinkRefused.stdout.contains("unsafe_path"))
        try FileManager.default.removeItem(at: hardLink)
        try FileManager.default.removeItem(at: hardLinkSource)

        let marker = fixture.paths.data.appendingPathComponent("user-configuration.json")
        try Data("user".utf8).write(to: marker)
        chmod(marker.path, mode_t(0o600))
        let purged = await fixture.commands.run(arguments: [
            "purge", "--confirm", ServiceIdentity.purgeConfirmationToken, "--json"
        ])
        XCTAssertEqual(purged.exitCode, 0, purged.stderr)
        XCTAssertTrue((serviceJSON(purged.stdout)?["deleted"] as? [String])?.contains("all_product_data") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.data.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

private final class RunAtLoadLaunchctlState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loaded = false
    private(set) var running = false
    var failNextBootstrap = false
    var failNextKickstart = false
    var failNextBootout = false
    var delayedPublicationPrints = 0
    var delayedStopPrints = 0
    var notFoundAfterBootstrapPrints = 0
    var latePublicationAfterBootoutPrints = 0
    var neverPublishes = false
    private(set) var loadedStoppedPrintCount = 0
    private(set) var stopPollCount = 0
    private(set) var notFoundPrintCount = 0
    var definitionOutput: String?
    private var publicationPending = false
    private var stoppingPending = false

    func publishLoadedStopped() {
        lock.lock()
        loaded = true
        running = false
        publicationPending = false
        stoppingPending = false
        lock.unlock()
    }

    func beginNeverPublishing() {
        lock.lock()
        loaded = true
        running = false
        publicationPending = true
        neverPublishes = true
        lock.unlock()
    }

    func response(_ arguments: [String]) -> ServiceProcessResult {
        lock.lock()
        defer { lock.unlock() }
        switch arguments.first {
        case "bootstrap":
            if failNextBootstrap {
                failNextBootstrap = false
                return ServiceProcessResult(exitCode: 1, stderr: "bootstrap failed")
            }
            guard !loaded else {
                return ServiceProcessResult(exitCode: 113, stderr: "service is already loaded")
            }
            loaded = true
            if delayedPublicationPrints > 0 || notFoundAfterBootstrapPrints > 0 || neverPublishes {
                running = false
                publicationPending = true
            } else {
                running = true
            }
            return ServiceProcessResult(exitCode: 0)
        case "kickstart":
            if failNextKickstart {
                failNextKickstart = false
                return ServiceProcessResult(exitCode: 1, stderr: "kickstart failed")
            }
            guard loaded else {
                return ServiceProcessResult(exitCode: 113, stderr: "service is not loaded")
            }
            if delayedPublicationPrints > 0 {
                running = false
                publicationPending = true
            } else {
                running = true
            }
            return ServiceProcessResult(exitCode: 0)
        case "bootout":
            if failNextBootout {
                failNextBootout = false
                return ServiceProcessResult(exitCode: 1, stderr: "bootout failed")
            }
            if latePublicationAfterBootoutPrints > 0 {
                loaded = true
                running = false
                publicationPending = true
                notFoundAfterBootstrapPrints = latePublicationAfterBootoutPrints
                latePublicationAfterBootoutPrints = 0
                return ServiceProcessResult(exitCode: 0)
            }
            loaded = false
            running = false
            publicationPending = false
            stoppingPending = false
            return ServiceProcessResult(exitCode: 0)
        case "kill":
            guard loaded else {
                return ServiceProcessResult(exitCode: 113, stderr: "service is not loaded")
            }
            running = false
            if delayedStopPrints > 0 {
                stoppingPending = true
            } else {
                stoppingPending = false
            }
            return ServiceProcessResult(exitCode: 0)
        case "print":
            guard loaded else {
                return ServiceProcessResult(exitCode: 113, stderr: "service is not loaded")
            }
            if publicationPending, notFoundAfterBootstrapPrints > 0 {
                notFoundAfterBootstrapPrints -= 1
                notFoundPrintCount += 1
                return ServiceProcessResult(exitCode: 113, stderr: "service is not loaded yet")
            }
            if publicationPending, neverPublishes {
                notFoundPrintCount += 1
                return ServiceProcessResult(exitCode: 113, stderr: "service is not loaded yet")
            }
            if publicationPending {
                if delayedPublicationPrints > 0 {
                    delayedPublicationPrints -= 1
                    let output = definitionOutput ?? "state = running\npid = 123\n"
                    return ServiceProcessResult(
                        exitCode: 0,
                        stdout: output
                            .replacingOccurrences(of: "state = running", with: "state = starting")
                            .replacingOccurrences(of: "job state = running", with: "job state = starting")
                    )
                }
                publicationPending = false
                running = true
            }
            if stoppingPending {
                stopPollCount += 1
                if delayedStopPrints > 0 {
                    delayedStopPrints -= 1
                    let output = definitionOutput ?? "state = running\npid = 123\n"
                    return ServiceProcessResult(
                        exitCode: 0,
                        stdout: output
                            .replacingOccurrences(of: "state = running", with: "state = starting")
                            .replacingOccurrences(of: "job state = running", with: "job state = starting")
                    )
                }
                stoppingPending = false
            }
            if !running {
                loadedStoppedPrintCount += 1
            }
            let output = definitionOutput ?? "state = running\npid = 123\n"
            return running
                ? ServiceProcessResult(exitCode: 0, stdout: output)
                : ServiceProcessResult(
                    exitCode: 0,
                    stdout: output.replacingOccurrences(of: "state = running\n", with: "state = exited\n")
                        .replacingOccurrences(of: "job state = running\n", with: "job state = exited\n")
                        .replacingOccurrences(of: "pid = 123\n", with: "")
                )
        default:
            return ServiceProcessResult(exitCode: 0)
        }
    }
}

private final class CancellationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTask: Task<CommandResult, Never>?

    var task: Task<CommandResult, Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedTask
        }
        set {
            lock.lock()
            storedTask = newValue
            lock.unlock()
        }
    }

    func cancelCurrentTask() async {
        while true {
            if let task {
                task.cancel()
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class CancellationLaunchctlRunner: ServiceProcessRunner, @unchecked Sendable {
    let state = RunAtLoadLaunchctlState()
    let cancellation: CancellationControl
    private let lock = NSLock()
    private var storedCancelOn: String?
    private var storedCalls: [[String]] = []

    init(cancellation: CancellationControl) {
        self.cancellation = cancellation
    }

    var cancelOn: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedCancelOn
        }
        set {
            lock.lock()
            storedCancelOn = newValue
            lock.unlock()
        }
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> ServiceProcessResult {
        try Task.checkCancellation()
        let shouldCancel = record(arguments: arguments)

        let result = state.response(arguments)
        if shouldCancel {
            await cancellation.cancelCurrentTask()
            throw ServiceProcessError.cancelled
        }
        try Task.checkCancellation()
        return result
    }

    private func record(arguments: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedCalls.append(arguments)
        let shouldCancel = storedCancelOn == arguments.first
        if shouldCancel { storedCancelOn = nil }
        return shouldCancel
    }
}

private final class CancellationOnCallHealthProbe: ServiceHealthProbe, @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnCall: Int
    private let cancellation: CancellationControl
    private var callCount = 0

    init(cancelOnCall: Int, cancellation: CancellationControl) {
        self.cancelOnCall = cancelOnCall
        self.cancellation = cancellation
    }

    func waitUntilReady(port: Int, timeout: Duration) async -> ServiceHealthResult {
        let shouldCancel = nextCallCancels()
        if shouldCancel {
            await cancellation.cancelCurrentTask()
            return ServiceHealthResult(state: .timedOut)
        }
        return ServiceHealthResult(state: .ready)
    }

    private func nextCallCancels() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount == cancelOnCall
    }
}

private struct CancellationCommandFixture {
    let root: URL
    let home: URL
    let paths: StandardPaths
    let executable: URL
    let servicePaths: ServicePaths
    let cancellation: CancellationControl
    let runner: CancellationLaunchctlRunner
    let commands: ServiceCommands

    init(cancelHealthOnCall: Int? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-cancellation-(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        paths = StandardPaths(homeDirectory: home.path)
        executable = root.appendingPathComponent("versions/0.1.0-dev/syrinx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        chmod(executable.path, mode_t(0o700))
        servicePaths = ServicePaths(
            paths: paths,
            homeDirectory: home.path,
            executableURL: executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )
        cancellation = CancellationControl()
        runner = CancellationLaunchctlRunner(cancellation: cancellation)
        runner.state.definitionOutput = exactLaunchctlOutput(
            paths: servicePaths,
            configuration: ServiceConfiguration()
        )
        let healthProbe: any ServiceHealthProbe
        if let cancelHealthOnCall {
            healthProbe = CancellationOnCallHealthProbe(
                cancelOnCall: cancelHealthOnCall,
                cancellation: cancellation
            )
        } else {
            healthProbe = ClosureServiceHealthProbe { _, _ in ServiceHealthResult(state: .ready) }
        }
        let preflight = ServicePreflightDependencies(
            signatureVerifier: ServiceSignatureVerifier { _ in },
            validateModel: { _, _ in },
            validateForegroundStartup: { _, _, _, _ in },
            availableDiskBytes: { _ in 1024 * 1024 * 1024 },
            portIsAvailable: { _ in true },
            minimumFreeBytes: 1
        )
        commands = ServiceCommands(
            environment: ["HOME": home.path],
            paths: paths,
            executableURL: executable,
            canonicalAuthorityHome: home.path,
            dependencies: ServiceCommandDependencies(
                processRunner: runner,
                preflight: preflight,
                healthProbe: healthProbe,
                portOwner: { _, _ in "pid:123" }
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
