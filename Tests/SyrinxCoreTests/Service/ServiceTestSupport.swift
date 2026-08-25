import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class RecordingServiceProcessRunner: ServiceProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    private let stateful: Bool
    private var loaded = false
    var response: @Sendable ([String]) -> ServiceProcessResult

    init(
        stateful: Bool = false,
        response: @escaping @Sendable ([String]) -> ServiceProcessResult = { arguments in
        if arguments.first == "print" {
            return ServiceProcessResult(exitCode: 0, stdout: "state = running\n")
        }
        return ServiceProcessResult(exitCode: 0)
        }
    ) {
        self.stateful = stateful
        self.response = response
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> ServiceProcessResult {
        let statefulResult: ServiceProcessResult? = withLock {
            calls.append(arguments)
            guard stateful else { return nil }
            switch arguments.first {
            case "bootstrap":
                guard !loaded else {
                    return ServiceProcessResult(exitCode: 113, stderr: "service is already loaded")
                }
                loaded = true
                return ServiceProcessResult(exitCode: 0)
            case "kickstart":
                return loaded
                    ? ServiceProcessResult(exitCode: 0)
                    : ServiceProcessResult(exitCode: 113, stderr: "service is not loaded")
            case "bootout":
                loaded = false
                return ServiceProcessResult(exitCode: 0)
            case "kill":
                return loaded
                    ? ServiceProcessResult(exitCode: 0)
                    : ServiceProcessResult(exitCode: 113, stderr: "service is not loaded")
            case "print":
                guard loaded else {
                    return ServiceProcessResult(exitCode: 113, stderr: "service is not loaded")
                }
            default:
                break
            }
            return nil
        }
        if let statefulResult { return statefulResult }
        return response(arguments)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

struct ServiceCommandFixture {
    let root: URL
    let home: URL
    let paths: StandardPaths
    let executable: URL
    let process: RecordingServiceProcessRunner
    let commands: ServiceCommands

    var servicePathsForTesting: ServicePaths {
        ServicePaths(
            paths: paths,
            homeDirectory: home.path,
            executableURL: executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )
    }

    init(
        health: ServiceHealthResult = .init(state: .ready),
        processResponse: (@Sendable ([String]) -> ServiceProcessResult)? = nil,
        preflightOverride: ServicePreflightDependencies? = nil,
        healthProbeOverride: (any ServiceHealthProbe)? = nil,
        portOwner: @escaping @Sendable (Int, pid_t?) async -> String? = { _, _ in "pid:123" },
        environmentOverrides: [String: String] = [:]
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-service-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        paths = StandardPaths(homeDirectory: home.path)
        executable = root.appendingPathComponent("versions/0.1.0-dev/syrinx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        chmod(executable.path, mode_t(0o700))
        let plistPath = home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ServiceIdentity.label).plist")
        let servicePaths = ServicePaths(
            paths: paths,
            homeDirectory: home.path,
            executableURL: executable,
            version: BuildInfo.from(environment: environmentOverrides).projectVersion
        )
        let launchctlOutput = exactLaunchctlOutput(
            paths: servicePaths,
            configuration: (try? ServiceConfiguration.load(environment: environmentOverrides)) ?? ServiceConfiguration()
        )
        if let processResponse {
            process = RecordingServiceProcessRunner(response: processResponse)
        } else {
            process = RecordingServiceProcessRunner(stateful: true, response: { arguments in
                if arguments.first == "print",
                   !FileManager.default.fileExists(atPath: plistPath.path)
                {
                    return ServiceProcessResult(exitCode: 113, stderr: "service is not loaded")
                }
                if arguments.first == "print" {
                    return ServiceProcessResult(exitCode: 0, stdout: launchctlOutput)
                }
                return ServiceProcessResult(exitCode: 0)
            })
        }

        let preflight = preflightOverride ?? ServicePreflightDependencies(
            signatureVerifier: ServiceSignatureVerifier { _ in },
            validateModel: { _, _ in },
            validateForegroundStartup: { _, _, _, _ in },
            availableDiskBytes: { _ in 1024 * 1024 * 1024 },
            portIsAvailable: { _ in true },
            minimumFreeBytes: 1
        )
        var environment = ["HOME": home.path]
        environment.merge(environmentOverrides) { _, new in new }
        commands = ServiceCommands(
            environment: environment,
            paths: paths,
            executableURL: executable,
            canonicalAuthorityHome: home.path,
            dependencies: ServiceCommandDependencies(
                processRunner: process,
                preflight: preflight,
                healthProbe: healthProbeOverride ?? ClosureServiceHealthProbe { _, _ in health },
                portOwner: portOwner
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

func exactLaunchctlOutput(
    paths: ServicePaths,
    configuration: ServiceConfiguration
) -> String {
    let digest = (try? ServiceConfigurationDigest.forConfiguration(configuration))
        ?? String(repeating: "0", count: 64)
    let environment = [
        "SYRINX_CONFIG_PATH => \(paths.configuration.path)",
        "SYRINX_CONFIG_SHA256 => \(digest)",
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

func fixtureLaunchctlOutput(_ fixture: ServiceCommandFixture) -> String {
    exactLaunchctlOutput(
        paths: ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        ),
        configuration: ServiceConfiguration()
    )
}

final class SequenceServiceHealthProbe: ServiceHealthProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ServiceHealthResult]

    init(_ results: [ServiceHealthResult]) {
        self.results = results
    }

    func waitUntilReady(port: Int, timeout: Duration) async -> ServiceHealthResult {
        withLock {
            results.isEmpty ? .init(state: .timedOut) : results.removeFirst()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

func serviceJSON(_ value: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
}
