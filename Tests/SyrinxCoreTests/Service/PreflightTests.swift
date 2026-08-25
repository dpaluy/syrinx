import Foundation
import XCTest
@testable import SyrinxCore

final class PreflightTests: XCTestCase {
    func testMissingModelHasOneStableRepairDiagnostic() async throws {
        let fixture = try ServiceCommandFixture(
            preflightOverride: ServicePreflightDependencies(
                signatureVerifier: ServiceSignatureVerifier { _ in },
                validateModel: { _, _ in throw TestPreflightFailure() },
                validateForegroundStartup: { _, _, _, _ in },
                availableDiskBytes: { _ in 1024 * 1024 * 1024 },
                portIsAvailable: { _ in true },
                minimumFreeBytes: 1
            )
        )
        defer { fixture.cleanup() }

        let result = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(result.exitCode, 1)
        let object = try XCTUnwrap(serviceJSON(result.stdout))
        XCTAssertEqual(object["message"] as? String, "the selected model is missing or corrupt")
        XCTAssertEqual(object["repair_command"] as? String, "syrinx models install --activate")
        XCTAssertFalse(result.stdout.contains(fixture.root.path))
        XCTAssertTrue(fixture.process.calls.allSatisfy { $0.first == "print" })
    }

    func testProductionModelPreflightRejectsAnUnsupportedConfiguredModelID() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let configuration = try ServiceConfiguration(
            modelID: ModelIdentifier("unsupported-configured-model")
        )

        do {
            try await validateProductionModel(paths: fixture.paths, configuration: configuration)
            XCTFail("expected unsupported configured model to fail closed")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testSignatureDiskPortForegroundAndSecretFailuresAreFailClosed() async throws {
        let failures: [(String, ServicePreflightDependencies)] = [
            (
                "signature",
                ServicePreflightDependencies(
                    signatureVerifier: ServiceSignatureVerifier { _ in throw TestPreflightFailure() },
                    validateModel: { _, _ in },
                    validateForegroundStartup: { _, _, _, _ in },
                    availableDiskBytes: { _ in 1024 * 1024 * 1024 },
                    portIsAvailable: { _ in true },
                    minimumFreeBytes: 1
                )
            ),
            (
                "disk",
                ServicePreflightDependencies(
                    signatureVerifier: ServiceSignatureVerifier { _ in },
                    validateModel: { _, _ in },
                    validateForegroundStartup: { _, _, _, _ in },
                    availableDiskBytes: { _ in 0 },
                    portIsAvailable: { _ in true },
                    minimumFreeBytes: 1
                )
            ),
            (
                "port",
                ServicePreflightDependencies(
                    signatureVerifier: ServiceSignatureVerifier { _ in },
                    validateModel: { _, _ in },
                    validateForegroundStartup: { _, _, _, _ in },
                    availableDiskBytes: { _ in 1024 * 1024 * 1024 },
                    portIsAvailable: { _ in false },
                    minimumFreeBytes: 1
                )
            ),
            (
                "foreground",
                ServicePreflightDependencies(
                    signatureVerifier: ServiceSignatureVerifier { _ in },
                    validateModel: { _, _ in },
                    validateForegroundStartup: { _, _, _, _ in throw TestPreflightFailure() },
                    availableDiskBytes: { _ in 1024 * 1024 * 1024 },
                    portIsAvailable: { _ in true },
                    minimumFreeBytes: 1
                )
            )
        ]

        for (name, dependencies) in failures {
            let fixture = try ServiceCommandFixture(preflightOverride: dependencies)
            defer { fixture.cleanup() }
            let result = await fixture.commands.run(arguments: ["install", "--json"])
            XCTAssertEqual(result.exitCode, 1, name)
            XCTAssertFalse(result.stdout.contains(fixture.root.path), name)
            XCTAssertTrue(fixture.process.calls.allSatisfy { $0.first == "print" }, name)
        }

        let secretFixture = try ServiceCommandFixture(
            environmentOverrides: ["SYRINX_API_KEY": "secret-value"]
        )
        defer { secretFixture.cleanup() }
        let secretResult = await secretFixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(secretResult.exitCode, 1)
        XCTAssertTrue(secretResult.stdout.contains("secret value cannot be copied") || secretResult.stdout.contains("invalid_secret_source"), secretResult.stdout)
        XCTAssertFalse(secretResult.stdout.contains("secret-value"))
        XCTAssertTrue(secretFixture.process.calls.allSatisfy { $0.first == "print" })
    }

    func testInvalidConfigurationIsRejectedBeforeAnyLaunchctlCommand() async throws {
        let fixture = try ServiceCommandFixture(
            environmentOverrides: ["SYRINX_PORT": "0"]
        )
        defer { fixture.cleanup() }

        let result = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("configuration_error"))
        XCTAssertTrue(fixture.process.calls.allSatisfy { $0.first == "print" })
    }

    func testVersionPathEscapeIsRejectedBeforeAnyLaunchctlCommand() async throws {
        let fixture = try ServiceCommandFixture(
            environmentOverrides: ["SYRINX_PROJECT_VERSION": "../outside"]
        )
        defer { fixture.cleanup() }

        let result = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(serviceJSON(result.stdout)?["error_code"] as? String, "unsafe_path")
        XCTAssertTrue(fixture.process.calls.allSatisfy { $0.first == "print" })
    }

    func testForegroundReadinessUsesASeparateLoopbackProbePort() async throws {
        let probe = LockedProbePort()
        let fixture = try ServiceCommandFixture(
            preflightOverride: ServicePreflightDependencies(
                signatureVerifier: ServiceSignatureVerifier { _ in },
                validateModel: { _, _ in },
                validateForegroundStartup: { _, _, _, port in probe.value = port },
                availableDiskBytes: { _ in 1024 * 1024 * 1024 },
                portIsAvailable: { _ in true },
                allocateProbePort: { 60_001 },
                minimumFreeBytes: 1
            )
        )
        defer { fixture.cleanup() }
        let result = await fixture.commands.run(arguments: ["install", "--json"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(probe.value, 60_001)
        XCTAssertNotEqual(probe.value, 5_092)
    }

    func testForegroundProbeReceivesExactValidatedConfigurationAndSecretReference() async throws {
        let fixture = try ServiceCommandFixture()
        defer { fixture.cleanup() }
        let secretURL = fixture.root.appendingPathComponent("secret")
        try ServiceFileSystem().writePrivateFileAtomically(Data("probe-token".utf8), to: secretURL)
        chmod(secretURL.path, mode_t(0o600))
        let exact = try ServiceConfiguration(
            port: Port(6107),
            modelID: ModelIdentifier("retained-model"),
            maxUploadBytes: ByteLimit(1_007, key: "test-upload"),
            maxJobs: JobLimit(7, key: "test-jobs"),
            bearerSecretFile: secretURL.path
        )
        let servicePaths = ServicePaths(
            paths: fixture.paths,
            homeDirectory: fixture.home.path,
            executableURL: fixture.executable,
            version: BuildInfo.from(environment: [:]).projectVersion
        )
        let observed = PreflightConfigurationCapture()
        let dependencies = ServicePreflightDependencies(
            signatureVerifier: ServiceSignatureVerifier { _ in },
            validateModel: { _, configuration in observed.set(configuration) },
            validateForegroundStartup: { _, _, configuration, probePort in
                observed.set(configuration)
                XCTAssertEqual(probePort, 60_107)
            },
            availableDiskBytes: { _ in 1024 * 1024 * 1024 },
            portIsAvailable: { _ in true },
            allocateProbePort: { 60_107 },
            minimumFreeBytes: 1
        )
        let preflight = ServicePreflight(
            environment: [
                "SYRINX_PORT": "6108",
                "SYRINX_MODEL_ID": "stale-model",
                "SYRINX_MAX_UPLOAD_BYTES": "2",
                "SYRINX_MAX_JOBS": "1"
            ],
            paths: fixture.paths,
            servicePaths: servicePaths,
            configurationOverride: exact,
            dependencies: dependencies,
            fileSystem: ServiceFileSystem()
        )

        _ = try await preflight.run()

        XCTAssertEqual(observed.value?.port.value, 6107)
        XCTAssertEqual(observed.value?.modelID.value, "retained-model")
        XCTAssertEqual(observed.value?.maxUploadBytes.value, 1_007)
        XCTAssertEqual(observed.value?.maxJobs.value, 7)
        XCTAssertEqual(observed.value?.bearerSecretFile, secretURL.path)
        XCTAssertNil(observed.value?.bearerSecret)
        let childEnvironment = controlledServiceEnvironment(
            paths: fixture.paths,
            configuration: exact,
            portOverride: 60_107
        )
        XCTAssertEqual(childEnvironment["SYRINX_MODEL_ID"], "retained-model")
        XCTAssertEqual(childEnvironment["SYRINX_MAX_UPLOAD_BYTES"], "1007")
        XCTAssertEqual(childEnvironment["SYRINX_MAX_JOBS"], "7")
        XCTAssertEqual(childEnvironment["SYRINX_PORT"], "60107")
        XCTAssertEqual(childEnvironment["SYRINX_API_KEY_SOURCE"], "file")
        XCTAssertEqual(childEnvironment["SYRINX_API_KEY_FILE"], secretURL.path)
        XCTAssertNil(childEnvironment["SYRINX_API_KEY"])
    }
}

private struct TestPreflightFailure: Error {}

private final class LockedProbePort: @unchecked Sendable {
    var value: Int?
}

private final class PreflightConfigurationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ServiceConfiguration?

    func set(_ value: ServiceConfiguration) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: ServiceConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
