import Foundation
import Darwin
import XCTest
@_spi(Testing) import SyrinxCore
@testable import SyrinxCore

final class ModelCommandsTests: XCTestCase {
    func testUsageMatrixRejectsMalformedFormsBeforeDependenciesAreUsed() async throws {
        let invalid: [[String]] = [
            ["install", "--json", "--json"],
            ["install", "--unknown"],
            ["install", "extra"],
            ["list", "extra"],
            ["verify", "--revision", String(repeating: "A", count: 40)],
            ["verify", "--revision", "bad"],
            ["verify", "--revision"],
            ["path", "--revision", String(repeating: "a", count: 40), "--revision", String(repeating: "b", count: 40)],
            ["activate"],
            ["activate", String(repeating: "a", count: 40), String(repeating: "b", count: 40)],
            ["activate", String(repeating: "A", count: 40)],
            ["rollback", "--force"],
            ["gc", "--json", "--json"]
        ]

        for arguments in invalid {
            let result = await CommandRunner(environment: [:]).runAsync(arguments: ["models"] + arguments)
            XCTAssertEqual(result.exitCode, 2, arguments.description)
            XCTAssertFalse(result.stderr.isEmpty, arguments.description)
            XCTAssertTrue(result.stderr.hasPrefix("usage: syrinx models "), arguments.description)
        }
    }

    func testAsyncRunnerDoesNotUseSynchronousPlaceholderForModels() {
        let result = CommandRunner(environment: [:]).run(arguments: ["models", "list"])

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertFalse(result.stderr.contains("placeholder"))
        XCTAssertTrue(result.stderr.contains("async execution"))
    }

    func testListIsEmptyWithoutStateAndSortsCurrentAndPriorRevisions() async throws {
        let empty = try Fixture()
        defer { empty.remove() }
        let emptyResult = await (try empty.runner()).runAsync(arguments: ["models", "list", "--json"])
        XCTAssertEqual(emptyResult.exitCode, 0)
        XCTAssertEqual(emptyResult.stdout, "{\"model_id\":\"parakeet-tdt-0.6b-v3\",\"revisions\":[],\"variant_id\":\"int8\"}\n")

        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = String(repeating: "b", count: 40)
        let second = String(repeating: "a", count: 40)
        try fixture.writeInstalled([fixture.revision(first), fixture.revision(second)])
        try fixture.writeSelection(current: first, prior: second)

        let result = await (try fixture.runner()).runAsync(arguments: ["models", "list", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stdout,
            "{\"model_id\":\"parakeet-tdt-0.6b-v3\",\"revisions\":[{\"current\":false,\"immutable_commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"prior\":true,\"verified_at\":\"1970-01-01T00:00:01Z\"},{\"current\":true,\"immutable_commit\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"prior\":false,\"verified_at\":\"1970-01-01T00:00:01Z\"}],\"variant_id\":\"int8\"}\n"
        )
    }

    func testVerifyAndPathUseFullVerifierWithoutNetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let revision = String(repeating: "a", count: 40)
        try fixture.writeInstalled([fixture.revision(revision)])
        try fixture.writeSelection(current: revision, prior: nil)
        try fixture.writeTree(revision: revision, data: Data("good".utf8))

        let verify = await (try fixture.runner()).runAsync(arguments: ["models", "verify", "--json"])
        XCTAssertEqual(verify.exitCode, 0)
        XCTAssertTrue(verify.stdout.contains("\"valid\":true"))

        let path = await (try fixture.runner()).runAsync(arguments: ["models", "path", "--json"])
        XCTAssertEqual(path.exitCode, 0)
        XCTAssertTrue(path.stdout.contains("\"immutable_commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""))
        let pathObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(path.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(pathObject["path"] as? String, fixture.store.revisionURL(for: revision).path)

        try Data("bad".utf8).write(to: fixture.store.revisionURL(for: revision).appendingPathComponent("Preprocessor.mlmodelc/metadata.json"))
        let invalid = await (try fixture.runner()).runAsync(arguments: ["models", "verify", "--revision", revision, "--json"])
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertTrue(invalid.stdout.contains("\"valid\":false"))
        XCTAssertFalse(invalid.stdout.contains(fixture.root.path))
    }

    func testInstallAlwaysInstallsWithoutActivationThenActivates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = RecordingInstaller(commit: fixture.commit)
        let lifecycle = RecordingLifecycle()
        let dependencies = try fixture.dependencies(installer: installer, lifecycle: lifecycle)
        let command = ModelCommands(dependencies: dependencies)

        let result = await command.run(arguments: ["install", "--activate", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let calls = await installer.calls
        XCTAssertEqual(calls, [false])
        let activations = await lifecycle.activations
        XCTAssertEqual(activations, [fixture.commit])
        XCTAssertEqual(
            result.stdout,
            "{\"activated\":true,\"immutable_commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"preflight\":{\"attribution\":\"test\",\"available_bytes\":2000000,\"immutable_commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"license_identifier\":\"CC-BY-4.0\",\"model_id\":\"parakeet-tdt-0.6b-v3\",\"remaining_bytes\":4,\"required_bytes\":4,\"safety_allowance\":0,\"source_repository\":\"FluidInference\\/parakeet-tdt-0.6b-v3-coreml\",\"total_bytes\":4,\"variant_id\":\"int8\"}}\n"
        )

        let human = await command.run(arguments: ["install"])
        XCTAssertEqual(human.exitCode, 0)
        XCTAssertTrue(human.stdout.contains("preflight: total 4 bytes, remaining 4 bytes, required 4 bytes, available 2000000 bytes"))
        XCTAssertTrue(human.stdout.contains("source: FluidInference/parakeet-tdt-0.6b-v3-coreml"))
        XCTAssertTrue(human.stdout.contains("license: CC-BY-4.0"))
        XCTAssertTrue(human.stdout.contains("attribution: test"))
        XCTAssertFalse(human.stdout.contains("Preprocessor"))
        XCTAssertFalse(human.stdout.contains("weights"))
    }

    func testRealInstallerCommandSupportsSuccessResumeAndBoundedFailure() async throws {
        let success = try Fixture()
        defer { success.remove() }
        let successClient = FixtureDownloadClient(specs: [
            .init(status: 200, headers: ["content-length": "4"], chunks: [Data("good".utf8)])
        ])
        let successLifecycle = try ModelLifecycleCoordinator(testingManifest: success.manifest, store: success.store)
        let successCommand = ModelCommands(
            dependencies: ModelCommandDependencies(
                manifest: success.manifest,
                store: success.store,
                factories: ModelCommandFactories(
                    makeInstaller: {
                        ModelInstaller(
                            unvalidatedManifestForTesting: success.manifest,
                            store: success.store,
                            downloadClient: successClient,
                            diskSpaceProvider: FixedDiskSpaceProvider(bytes: 2_000_000),
                            diskSafetyAllowance: ModelInstaller.defaultDiskSafetyAllowance
                        )
                    },
                    makeLifecycle: { successLifecycle }
                ),
                now: { Date(timeIntervalSince1970: 1) }
            )
        )
        let successResult = await successCommand.run(arguments: ["install", "--activate", "--json"])
        XCTAssertEqual(successResult.exitCode, 0)
        XCTAssertEqual(try success.store.readSelection()?.currentRevision, success.commit)

        let resume = try Fixture()
        defer { resume.remove() }
        let partialFile = resume.store.downloadsDirectory
            .appendingPathComponent("\(resume.commit).partial")
            .appendingPathComponent(ModelManifest.supportedRepositoryFolder)
            .appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try FileManager.default.createDirectory(at: partialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("go".utf8).write(to: partialFile)
        let resumeClient = FixtureDownloadClient(specs: [
            .init(
                status: 206,
                headers: ["content-length": "2", "content-range": "bytes 2-3/4"],
                chunks: [Data("od".utf8)]
            )
        ])
        let resumeCommand = ModelCommands(
            dependencies: ModelCommandDependencies(
                manifest: resume.manifest,
                store: resume.store,
                factories: ModelCommandFactories(
                    makeInstaller: {
                        ModelInstaller(
                            unvalidatedManifestForTesting: resume.manifest,
                            store: resume.store,
                            downloadClient: resumeClient,
                            diskSpaceProvider: FixedDiskSpaceProvider(
                                bytes: ModelInstaller.defaultDiskSafetyAllowance + 3
                            ),
                            diskSafetyAllowance: ModelInstaller.defaultDiskSafetyAllowance
                        )
                    },
                    makeLifecycle: { try ModelLifecycleCoordinator(testingManifest: resume.manifest, store: resume.store) }
                ),
                now: { Date(timeIntervalSince1970: 1) }
            )
        )
        let resumeResult = await resumeCommand.run(arguments: ["install", "--json"])
        XCTAssertEqual(resumeResult.exitCode, 0)
        XCTAssertEqual(
            resumeResult.stdout,
            "{\"activated\":false,\"immutable_commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"preflight\":{\"attribution\":\"test\",\"available_bytes\":1048579,\"immutable_commit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"license_identifier\":\"CC-BY-4.0\",\"model_id\":\"parakeet-tdt-0.6b-v3\",\"remaining_bytes\":2,\"required_bytes\":1048578,\"safety_allowance\":1048576,\"source_repository\":\"FluidInference\\/parakeet-tdt-0.6b-v3-coreml\",\"total_bytes\":4,\"variant_id\":\"int8\"}}\n"
        )
        let resumeRequests = await resumeClient.requests
        XCTAssertEqual(resumeRequests.first?.rangeStart, 2)
        XCTAssertEqual(try Data(contentsOf: resume.store.revisionURL(for: resume.commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")), Data("good".utf8))

        let failure = try Fixture()
        defer { failure.remove() }
        let failureClient = FixtureDownloadClient(specs: [
            .init(status: 200, headers: ["content-length": "4"], chunks: [Data("go".utf8)])
        ])
        let failureLifecycle = RecordingLifecycle()
        let failureCommand = ModelCommands(
            dependencies: ModelCommandDependencies(
                manifest: failure.manifest,
                store: failure.store,
                installer: ModelInstaller(
                    unvalidatedManifestForTesting: failure.manifest,
                    store: failure.store,
                    downloadClient: failureClient,
                    diskSpaceProvider: FixedDiskSpaceProvider(bytes: 2_000_000),
                    diskSafetyAllowance: ModelInstaller.defaultDiskSafetyAllowance
                ),
                lifecycle: failureLifecycle,
                now: { Date(timeIntervalSince1970: 1) }
            )
        )
        let failureResult = await failureCommand.run(arguments: ["install", "--activate", "--json"])
        XCTAssertEqual(failureResult.exitCode, 1)
        XCTAssertEqual(failureResult.stdout, "{\"error\":\"model download response ended before the expected size\"}\n")
        XCTAssertNil(try failure.store.readSelection())
        let failureActivations = await failureLifecycle.activations
        XCTAssertTrue(failureActivations.isEmpty)
    }

    func testInsufficientPreflightSpaceRejectsBeforeInstallerOrActivation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = RecordingInstaller(commit: fixture.commit, preflightFailure: .diskFull)
        let lifecycle = RecordingLifecycle()
        let dependencies = ModelCommandDependencies(
            manifest: fixture.manifest,
            store: fixture.store,
            installer: installer,
            lifecycle: lifecycle,
            now: { Date(timeIntervalSince1970: 1) }
        )
        let result = await ModelCommands(dependencies: dependencies).run(arguments: ["install", "--activate", "--json"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "{\"error\":\"model download or state write ran out of disk space\"}\n")
        let installerCalls = await installer.calls
        XCTAssertTrue(installerCalls.isEmpty)
        let lifecycleCalls = await lifecycle.activations
        XCTAssertTrue(lifecycleCalls.isEmpty)
    }

    func testProductionFactoryIsLazyAndOnlyInstallCreatesInstaller() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let counters = FactoryCounters()
        let lifecycle = RecordingLifecycle()
        let factories = ModelCommandFactories(
            makeInstaller: {
                counters.incrementInstaller()
                return RecordingInstaller(
                    commit: fixture.commit,
                    preflightHook: { counters.incrementInstallerPreflight() }
                )
            },
            makeLifecycle: {
                counters.incrementLifecycle()
                return lifecycle
            }
        )
        let dependencies = ModelCommandDependencies(
            manifest: fixture.manifest,
            store: fixture.store,
            factories: factories,
            now: { Date(timeIntervalSince1970: 1) }
        )
        let command = ModelCommands(dependencies: dependencies)

        _ = await command.run(arguments: ["list"])
        _ = await command.run(arguments: ["verify"])
        _ = await command.run(arguments: ["path", "--revision", fixture.commit])
        _ = await command.run(arguments: ["gc"])
        let installerCount = counters.installerCount
        XCTAssertEqual(installerCount, 0)
        let lifecycleCount = counters.lifecycleCount
        XCTAssertEqual(lifecycleCount, 1)

        let install = await command.run(arguments: ["install", "--activate"])
        XCTAssertEqual(install.exitCode, 0)
        XCTAssertEqual(counters.installerCount, 1)
        XCTAssertEqual(counters.lifecycleCount, 2)
        XCTAssertEqual(counters.installerPreflightCount, 1)
    }

    func testLifecycleCommandsDelegateAndEncodeBusyAndUnsafeGCResults() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = RecordingInstaller(commit: fixture.commit)
        let lifecycle = RecordingLifecycle()
        await lifecycle.gcResult(
            ModelGarbageCollectionResult(
                deleted: [fixture.second, fixture.commit],
                skipped: [.unsafe(fixture.third), .busy(fixture.commit)]
            )
        )
        let command = ModelCommands(dependencies: try fixture.dependencies(installer: installer, lifecycle: lifecycle))

        let activate = await command.run(arguments: ["activate", fixture.commit, "--json"])
        XCTAssertEqual(activate.exitCode, 0)
        let activations = await lifecycle.activations
        XCTAssertEqual(activations, [fixture.commit])

        let rollback = await command.run(arguments: ["rollback", "--json"])
        XCTAssertEqual(rollback.exitCode, 0)
        let rollbackCount = await lifecycle.rollbackCount
        XCTAssertEqual(rollbackCount, 1)

        let gc = await command.run(arguments: ["gc", "--json"])
        XCTAssertEqual(gc.exitCode, 0)
        XCTAssertTrue(gc.stdout.contains("\"deleted\":[\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"]"))
        XCTAssertTrue(gc.stdout.contains("\"reason\":\"busy\""))
        XCTAssertTrue(gc.stdout.contains("\"reason\":\"unsafe\""))
    }

    func testEveryModelCommandHasConciseHumanOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.commit)])
        try fixture.writeSelection(current: fixture.commit, prior: nil)
        try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))

        let installer = RecordingInstaller(commit: fixture.commit)
        let lifecycle = RecordingLifecycle()
        let command = ModelCommands(dependencies: try fixture.dependencies(installer: installer, lifecycle: lifecycle))

        let install = await command.run(arguments: ["install"])
        XCTAssertEqual(install.exitCode, 0)
        XCTAssertTrue(install.stdout.contains("activated: no"))
        XCTAssertFalse(install.stdout.contains("weights"))

        let list = await command.run(arguments: ["list"])
        XCTAssertEqual(list.exitCode, 0)
        XCTAssertTrue(list.stdout.contains("current"))

        let verify = await command.run(arguments: ["verify", "--revision", fixture.commit])
        XCTAssertEqual(verify.exitCode, 0)
        XCTAssertTrue(verify.stdout.contains("verified"))

        let path = await command.run(arguments: ["path", "--revision", fixture.commit])
        XCTAssertEqual(path.exitCode, 0)
        XCTAssertEqual(path.stdout, fixture.store.revisionURL(for: fixture.commit).path + "\n")

        let activate = await command.run(arguments: ["activate", fixture.commit])
        XCTAssertEqual(activate.exitCode, 0)
        XCTAssertTrue(activate.stdout.contains("current: \(fixture.commit)"))

        let rollback = await command.run(arguments: ["rollback"])
        XCTAssertEqual(rollback.exitCode, 0)
        XCTAssertTrue(rollback.stdout.contains("current:"))

        let gc = await command.run(arguments: ["gc"])
        XCTAssertEqual(gc.exitCode, 0)
        XCTAssertTrue(gc.stdout.isEmpty)
    }

    func testNonInstallCommandsDoNotCallTheInstaller() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.commit)])
        try fixture.writeSelection(current: fixture.commit, prior: nil)
        try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
        let installer = RecordingInstaller(commit: fixture.commit)
        let lifecycle = RecordingLifecycle()
        let command = ModelCommands(dependencies: try fixture.dependencies(installer: installer, lifecycle: lifecycle))

        _ = await command.run(arguments: ["list"])
        _ = await command.run(arguments: ["verify"])
        _ = await command.run(arguments: ["path"])
        _ = await command.run(arguments: ["activate", fixture.commit])
        _ = await command.run(arguments: ["rollback"])
        _ = await command.run(arguments: ["gc"])

        let calls = await installer.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testNonInstallCommandsMakeNoDownloadClientCalls() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.commit)])
        try fixture.writeSelection(current: fixture.commit, prior: nil)
        try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))

        let client = CountingDownloadClient()
        let installer = ModelInstaller(
            unvalidatedManifestForTesting: fixture.manifest,
            store: fixture.store,
            downloadClient: client
        )
        let lifecycle = RecordingLifecycle()
        let command = ModelCommands(
            dependencies: try fixture.dependencies(installer: installer, lifecycle: lifecycle)
        )

        _ = await command.run(arguments: ["list"])
        _ = await command.run(arguments: ["verify"])
        _ = await command.run(arguments: ["path"])
        _ = await command.run(arguments: ["activate", fixture.commit])
        _ = await command.run(arguments: ["rollback"])
        _ = await command.run(arguments: ["gc"])

        let count = await client.count
        XCTAssertEqual(count, 0)
    }

    func testCommandLevelVerificationRejectsWrongHashMissingExtraSymlinkAndHardLink() async throws {
        let mutations: [(String, (Fixture) throws -> Void)] = [
            ("wrong hash", { fixture in
                try fixture.writeTree(revision: fixture.commit, data: Data("bad".utf8))
            }),
            ("missing entry", { fixture in }),
            ("extra entry", { fixture in
                try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
                let extra = fixture.store.revisionURL(for: fixture.commit).appendingPathComponent("extra.bin")
                try Data("extra".utf8).write(to: extra)
            }),
            ("symlink", { fixture in
                try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
                let file = fixture.modelFile(revision: fixture.commit)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.root.appendingPathComponent("outside"))
            }),
            ("hard link", { fixture in
                try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
                let file = fixture.modelFile(revision: fixture.commit)
                let outside = fixture.root.appendingPathComponent("hard-link-source")
                try Data("good".utf8).write(to: outside)
                try FileManager.default.removeItem(at: file)
                guard link(outside.path, file.path) == 0 else { throw NSError(domain: "test", code: 1) }
            })
        ]

        for (name, mutate) in mutations {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.writeInstalled([fixture.revision(fixture.commit)])
            try fixture.writeSelection(current: fixture.commit, prior: nil)
            if name != "missing entry" {
                try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
            }
            try mutate(fixture)
            let command = ModelCommands(dependencies: try fixture.dependencies(installer: RecordingInstaller(commit: fixture.commit), lifecycle: RecordingLifecycle()))

            let json = await command.run(arguments: ["verify", "--revision", fixture.commit, "--json"])
            XCTAssertEqual(json.exitCode, 1, name)
            XCTAssertTrue(json.stdout.contains("\"valid\":false"), name)
            XCTAssertFalse(json.stdout.contains(fixture.root.path), name)

            let human = await command.run(arguments: ["verify", "--revision", fixture.commit])
            XCTAssertEqual(human.exitCode, 1, name)
            XCTAssertEqual(human.stderr, "model verification failed\n", name)
            XCTAssertFalse(human.stderr.contains(fixture.root.path), name)
        }
    }

    func testPathCurrentExplicitAndFailureContracts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.commit), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.commit, prior: fixture.second)
        try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
        try fixture.writeTree(revision: fixture.second, data: Data("good".utf8))
        let command = ModelCommands(dependencies: try fixture.dependencies(installer: RecordingInstaller(commit: fixture.commit), lifecycle: RecordingLifecycle()))

        let current = await command.run(arguments: ["path", "--json"])
        XCTAssertEqual(current.exitCode, 0)
        XCTAssertTrue(current.stdout.contains("\"immutable_commit\":\"\(fixture.commit)\""))
        let explicit = await command.run(arguments: ["path", "--revision", fixture.second, "--json"])
        XCTAssertEqual(explicit.exitCode, 0)
        XCTAssertTrue(explicit.stdout.contains("\"immutable_commit\":\"\(fixture.second)\""))

        let missingSelection = try Fixture()
        defer { missingSelection.remove() }
        try missingSelection.writeInstalled([missingSelection.revision(missingSelection.commit)])
        try missingSelection.writeTree(revision: missingSelection.commit, data: Data("good".utf8))
        let missingSelectionCommand = ModelCommands(dependencies: try missingSelection.dependencies(installer: RecordingInstaller(commit: missingSelection.commit), lifecycle: RecordingLifecycle()))
        let missingSelectionJSON = await missingSelectionCommand.run(arguments: ["path", "--json"])
        XCTAssertEqual(missingSelectionJSON.exitCode, 1)
        XCTAssertEqual(missingSelectionJSON.stdout, "{\"error\":\"model selection is unavailable\"}\n")
        let missingSelectionHuman = await missingSelectionCommand.run(arguments: ["path"])
        XCTAssertEqual(missingSelectionHuman.exitCode, 1)
        XCTAssertEqual(missingSelectionHuman.stderr, "model selection is unavailable\n")
        XCTAssertFalse(missingSelectionHuman.stderr.contains(missingSelection.root.path))

        let uninstalled = await command.run(arguments: ["path", "--revision", fixture.third, "--json"])
        XCTAssertEqual(uninstalled.exitCode, 1)
        XCTAssertEqual(uninstalled.stdout, "{\"error\":\"model revision is not installed\"}\n")

        try Data("bad".utf8).write(to: fixture.modelFile(revision: fixture.commit))
        let corrupt = await command.run(arguments: ["path", "--json"])
        XCTAssertEqual(corrupt.exitCode, 1)
        XCTAssertEqual(corrupt.stdout, "{\"error\":\"model revision failed verification\"}\n")
        XCTAssertFalse(corrupt.stdout.contains(fixture.root.path))
    }

    func testListRejectsMalformedAndInconsistentState() async throws {
        let malformedInstalled = try Fixture()
        defer { malformedInstalled.remove() }
        try AtomicStateWriter().write(Data("not-json".utf8), to: malformedInstalled.store.installedURL)
        let malformedInstalledResult = await (try malformedInstalled.runner()).runAsync(arguments: ["models", "list", "--json"])
        XCTAssertEqual(malformedInstalledResult.exitCode, 1)
        XCTAssertEqual(malformedInstalledResult.stdout, "{\"error\":\"model store state is malformed\"}\n")

        let malformedSelection = try Fixture()
        defer { malformedSelection.remove() }
        try malformedSelection.writeInstalled([malformedSelection.revision(malformedSelection.commit)])
        try AtomicStateWriter().write(Data("not-json".utf8), to: malformedSelection.store.selectionURL)
        let malformedSelectionResult = await (try malformedSelection.runner()).runAsync(arguments: ["models", "list", "--json"])
        XCTAssertEqual(malformedSelectionResult.exitCode, 1)
        XCTAssertEqual(malformedSelectionResult.stdout, "{\"error\":\"model store state is malformed\"}\n")

        let inconsistent = try Fixture()
        defer { inconsistent.remove() }
        try inconsistent.writeInstalled([inconsistent.revision(inconsistent.commit)])
        try inconsistent.writeSelection(current: inconsistent.commit, prior: inconsistent.second)
        let inconsistentResult = await (try inconsistent.runner()).runAsync(arguments: ["models", "list", "--json"])
        XCTAssertEqual(inconsistentResult.exitCode, 1)
        XCTAssertEqual(inconsistentResult.stdout, "{\"error\":\"model selection is not installed\"}\n")

        let sameCurrentPrior = try Fixture()
        defer { sameCurrentPrior.remove() }
        try sameCurrentPrior.writeInstalled([sameCurrentPrior.revision(sameCurrentPrior.commit)])
        try sameCurrentPrior.writeSelection(current: sameCurrentPrior.commit, prior: sameCurrentPrior.commit)
        let sameResult = await (try sameCurrentPrior.runner()).runAsync(arguments: ["models", "list", "--json"])
        XCTAssertEqual(sameResult.exitCode, 1)
        XCTAssertEqual(sameResult.stdout, "{\"error\":\"model store state has inconsistent model metadata\"}\n")
    }

    func testCancellationMapsToOneStablePublicErrorForInstallAndLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cancelledInstall = ModelCommands(
            dependencies: ModelCommandDependencies(
                manifest: fixture.manifest,
                store: fixture.store,
                installer: CancellationInstaller(error: .cancellation),
                lifecycle: RecordingLifecycle(),
            )
        )
        let installResult = await cancelledInstall.run(arguments: ["install", "--json"])
        XCTAssertEqual(installResult.exitCode, 1)
        XCTAssertEqual(installResult.stdout, "{\"error\":\"model command was cancelled\"}\n")

        let typedCancelledInstall = ModelCommands(
            dependencies: ModelCommandDependencies(
                manifest: fixture.manifest,
                store: fixture.store,
                installer: CancellationInstaller(error: .typedInstallerCancellation),
                lifecycle: RecordingLifecycle(),
            )
        )
        let typedResult = await typedCancelledInstall.run(arguments: ["install", "--json"])
        XCTAssertEqual(typedResult.exitCode, 1)
        XCTAssertEqual(typedResult.stdout, "{\"error\":\"model command was cancelled\"}\n")

        let cancelledLifecycle = ModelCommands(
            dependencies: ModelCommandDependencies(
                manifest: fixture.manifest,
                store: fixture.store,
                installer: RecordingInstaller(commit: fixture.commit),
                lifecycle: CancellationLifecycle(),
            )
        )
        let lifecycleResult = await cancelledLifecycle.run(arguments: ["rollback", "--json"])
        XCTAssertEqual(lifecycleResult.exitCode, 1)
        XCTAssertEqual(lifecycleResult.stdout, "{\"error\":\"model command was cancelled\"}\n")
    }

    func testDownloadTransportDetailsAreRedactedInHumanAndJSONErrors() async throws {
        let detail = "/private/tmp/model \"secret-token\"\nAuthorization: Bearer token-like-value"
        let human = ModelCommands.failureResult(ModelDownloadClientError.transport(detail), json: false)
        XCTAssertEqual(human.exitCode, 1)
        XCTAssertEqual(human.stderr, "model download connection was lost\n")
        XCTAssertFalse(human.stderr.contains(detail))
        XCTAssertFalse(human.stderr.contains("secret-token"))
        XCTAssertFalse(human.stderr.contains("token-like-value"))

        let json = ModelCommands.failureResult(ModelDownloadClientError.transport(detail), json: true)
        XCTAssertEqual(json.exitCode, 1)
        XCTAssertEqual(json.stdout, "{\"error\":\"model download connection was lost\"}\n")
        XCTAssertFalse(json.stdout.contains(detail))
        XCTAssertFalse(json.stdout.contains("secret-token"))
        XCTAssertFalse(json.stdout.contains("token-like-value"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)))
    }

    func testConcurrentCommandProcessesActivateThroughTheCommandBoundary() async throws {
        for _ in 0..<4 {
            let fixture = try Fixture()
            try fixture.writeInstalled([fixture.revision(fixture.commit), fixture.revision(fixture.second), fixture.revision(fixture.third)])
            try fixture.writeSelection(current: fixture.commit, prior: nil)
            try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
            try fixture.writeTree(revision: fixture.second, data: Data("good".utf8))
            try fixture.writeTree(revision: fixture.third, data: Data("good".utf8))

            let holderReady = fixture.root.appendingPathComponent("holder-ready")
            let holderRelease = fixture.root.appendingPathComponent("holder-release")
            let holder = try startGlobalLockHolder(root: fixture.root, ready: holderReady, release: holderRelease)
            var first: ModelCommandHelperProcess?
            var second: ModelCommandHelperProcess?
            do {
                try await waitForMarker(holderReady, process: holder)
                first = try startModelCommandHelper(root: fixture.root, commit: fixture.second)
                second = try startModelCommandHelper(root: fixture.root, commit: fixture.third)
                try await Task.sleep(for: .milliseconds(100))
                FileManager.default.createFile(atPath: holderRelease.path, contents: Data())
                try await waitForProcess(holder)
                try await waitForProcess(try XCTUnwrap(first).process)
                try await waitForProcess(try XCTUnwrap(second).process)
            } catch {
                if holder.isRunning { terminate(holder) }
                if let firstProcess = first?.process, firstProcess.isRunning { terminate(firstProcess) }
                if let secondProcess = second?.process, secondProcess.isRunning { terminate(secondProcess) }
                throw error
            }
            let firstHelper = try XCTUnwrap(first)
            let secondHelper = try XCTUnwrap(second)
            let firstOutput = try readBoundedOutput(at: firstHelper.stdoutURL)
            let secondOutput = try readBoundedOutput(at: secondHelper.stdoutURL)
            let firstError = try readBoundedOutput(at: firstHelper.stderrURL)
            let secondError = try readBoundedOutput(at: secondHelper.stderrURL)
            XCTAssertEqual(
                firstHelper.process.terminationStatus,
                0,
                "first helper output: \(String(decoding: firstOutput, as: UTF8.self)), error: \(String(decoding: firstError, as: UTF8.self))"
            )
            XCTAssertEqual(
                secondHelper.process.terminationStatus,
                0,
                "second helper output: \(String(decoding: secondOutput, as: UTF8.self)), error: \(String(decoding: secondError, as: UTF8.self))"
            )
            XCTAssertTrue(String(data: firstOutput, encoding: .utf8)?.contains("current_revision") == true)
            XCTAssertTrue(String(data: secondOutput, encoding: .utf8)?.contains("current_revision") == true)
            let selection = try XCTUnwrap(try fixture.store.readSelection())
            XCTAssertTrue([fixture.second, fixture.third].contains(selection.currentRevision))
            if selection.currentRevision == fixture.second {
                XCTAssertEqual(selection.priorRevision, fixture.third)
            } else {
                XCTAssertEqual(selection.priorRevision, fixture.second)
            }
            fixture.remove()
        }
    }

    private func startGlobalLockHolder(root: URL, ready: URL, release: URL) throws -> Process {
        let process = Process()
        process.executableURL = try modelCommandHelperURL()
        process.arguments = ["global-hold", root.path, ready.path, release.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func waitForMarker(_ marker: URL, process: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard process.isRunning, ContinuousClock.now < deadline else {
                if process.isRunning { terminate(process) }
                throw NSError(domain: "ModelCommandsTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "model command lock helper timed out"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct ModelCommandHelperProcess {
        let process: Process
        let stdoutURL: URL
        let stderrURL: URL
    }

    private func startModelCommandHelper(root: URL, commit: String) throws -> ModelCommandHelperProcess {
        let process = Process()
        process.executableURL = try modelCommandHelperURL()
        process.arguments = ["model-activate", root.path, commit]
        let stdoutURL = root.appendingPathComponent("helper-\(UUID().uuidString).stdout")
        let stderrURL = root.appendingPathComponent("helper-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()
        return ModelCommandHelperProcess(process: process, stdoutURL: stdoutURL, stderrURL: stderrURL)
    }

    private func waitForProcess(_ process: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                process.terminate()
                let terminateDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                while process.isRunning && ContinuousClock.now < terminateDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning {
                    terminate(process)
                    let killDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                    while process.isRunning && ContinuousClock.now < killDeadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
                throw NSError(domain: "ModelCommandsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "model command helper timed out"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func terminate(_ process: Process) {
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private func readBoundedOutput(at url: URL) throws -> Data {
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 4096) ?? Data()
    }

    private func modelCommandHelperURL() throws -> URL {
        let bundle = Bundle(for: ModelCommandsTests.self).bundleURL
        var directory = bundle.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("LockHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        throw NSError(domain: "ModelCommandsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "LockHelper not found"])
    }

    func testCommandRunnerAcceptsEveryExactFormAndUsesInjectedStandardDataPath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.commit)])
        try fixture.writeSelection(current: fixture.commit, prior: nil)
        try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
        let runner = try fixture.runner()
        let forms = [
            ["models", "install"],
            ["models", "list"],
            ["models", "verify"],
            ["models", "verify", "--revision", fixture.commit],
            ["models", "path"],
            ["models", "path", "--revision", fixture.commit],
            ["models", "activate", fixture.commit],
            ["models", "rollback"],
            ["models", "gc"]
        ]
        for form in forms {
            let result = await runner.runAsync(arguments: form)
            XCTAssertEqual(result.exitCode, 0, form.description)
        }
        let path = await runner.runAsync(arguments: ["models", "path", "--json"])
        let pathObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(path.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(pathObject["path"] as? String, fixture.store.revisionURL(for: fixture.commit).path)

        let productionRunner = CommandRunner(
            environment: [:],
            paths: StandardPaths(data: fixture.root, cache: fixture.root, logs: fixture.root)
        )
        let productionList = await productionRunner.runAsync(arguments: ["models", "list", "--json"])
        XCTAssertEqual(productionList.exitCode, 0)
        XCTAssertTrue(productionList.stdout.contains("\"model_id\":\"parakeet-tdt-0.6b-v3\""))
    }

    func testActivateRollbackAndGCUseTheTransactionalLifecycleCoordinator() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.commit), fixture.revision(fixture.second), fixture.revision(fixture.third)])
        try fixture.writeSelection(current: fixture.second, prior: fixture.commit)
        try fixture.writeTree(revision: fixture.commit, data: Data("good".utf8))
        try fixture.writeTree(revision: fixture.second, data: Data("good".utf8))
        try fixture.writeTree(revision: fixture.third, data: Data("good".utf8))

        let lifecycle = try ModelLifecycleCoordinator(testingManifest: fixture.manifest, store: fixture.store)
        let commands = ModelCommands(
            dependencies: try fixture.dependencies(
                installer: RecordingInstaller(commit: fixture.commit),
                lifecycle: lifecycle
            )
        )

        let activation = await commands.run(arguments: ["activate", fixture.third, "--json"])
        XCTAssertEqual(activation.exitCode, 0)
        XCTAssertEqual(try fixture.store.readSelection()?.currentRevision, fixture.third)

        let rollback = await commands.run(arguments: ["rollback", "--json"])
        XCTAssertEqual(rollback.exitCode, 0)
        XCTAssertEqual(try fixture.store.readSelection()?.currentRevision, fixture.second)

        let gc = await commands.run(arguments: ["gc", "--json"])
        XCTAssertEqual(gc.exitCode, 0)
        XCTAssertTrue(gc.stdout.contains(fixture.commit))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.commit).deletingLastPathComponent().path))
    }

    private struct Fixture {
        let root: URL
        let store: ModelStore
        let manifest: ModelManifest
        let commit = String(repeating: "a", count: 40)
        let second = String(repeating: "b", count: 40)
        let third = String(repeating: "c", count: 40)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-model-commands-\(UUID().uuidString)")
            manifest = ModelManifest(
                testingFiles: [("Preprocessor.mlmodelc/metadata.json", Data("good".utf8))],
                baseURL: "http://fixture.invalid/model",
                immutableCommit: String(repeating: "a", count: 40)
            )
            store = ModelStore(root: root)
            try store.prepareDirectories()
        }

        func dependencies(
            installer: any ModelCommandInstalling,
            lifecycle: any ModelCommandLifecycle
        ) throws -> ModelCommandDependencies {
            ModelCommandDependencies(
                manifest: manifest,
                store: store,
                installer: installer,
                lifecycle: lifecycle,
                now: { Date(timeIntervalSince1970: 1) }
            )
        }

        func runner() throws -> CommandRunner {
            let installer = RecordingInstaller(commit: commit)
            let lifecycle = RecordingLifecycle()
            let commands = ModelCommands(dependencies: try dependencies(installer: installer, lifecycle: lifecycle))
            return CommandRunner(environment: [:], paths: StandardPaths(data: root, cache: root, logs: root), modelCommands: commands)
        }

        func revision(_ commit: String) -> InstalledRevision {
            InstalledRevision(
                immutableCommit: commit,
                modelId: manifest.modelId,
                variantId: manifest.variantId,
                verifiedAt: Date(timeIntervalSince1970: 1)
            )
        }

        func writeInstalled(_ revisions: [InstalledRevision]) throws {
            try AtomicStateWriter().write(
                InstalledState(modelId: manifest.modelId, variantId: manifest.variantId, revisions: revisions),
                to: store.installedURL
            )
        }

        func writeSelection(current: String, prior: String?) throws {
            try AtomicStateWriter().write(
                SelectionState(modelId: manifest.modelId, variantId: manifest.variantId, currentRevision: current, priorRevision: prior, verifiedAt: Date(timeIntervalSince1970: 1)),
                to: store.selectionURL
            )
        }

        func writeTree(revision: String, data: Data) throws {
            let file = store.revisionURL(for: revision).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }

        func modelFile(revision: String) -> URL {
            store.revisionURL(for: revision).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor RecordingInstaller: ModelCommandInstalling {
    let commit: String
    let preflightFailure: ModelInstallerError?
    let preflightHook: (@Sendable () -> Void)?
    var calls: [Bool] = []

    init(
        commit: String,
        preflightFailure: ModelInstallerError? = nil,
        preflightHook: (@Sendable () -> Void)? = nil
    ) {
        self.commit = commit
        self.preflightFailure = preflightFailure
        self.preflightHook = preflightHook
    }

    func preflight() async throws -> ModelInstallPreflight {
        preflightHook?()
        if let preflightFailure { throw preflightFailure }
        return ModelInstallPreflight(
            totalBytes: 4,
            remainingBytes: 4,
            safetyAllowance: 0,
            requiredBytes: 4,
            availableBytes: 2_000_000
        )
    }

    func install(activate: Bool, verifiedAt: Date) async throws -> ModelInstallResult {
        calls.append(activate)
        return ModelInstallResult(immutableCommit: commit, activated: activate)
    }
}

private enum CancellationInstallerError: Sendable {
    case cancellation
    case typedInstallerCancellation
}

private struct CancellationInstaller: ModelCommandInstalling {
    let error: CancellationInstallerError

    func preflight() async throws -> ModelInstallPreflight {
        ModelInstallPreflight(
            totalBytes: 4,
            remainingBytes: 4,
            safetyAllowance: 0,
            requiredBytes: 4,
            availableBytes: 2_000_000
        )
    }

    func install(activate: Bool, verifiedAt: Date) async throws -> ModelInstallResult {
        switch error {
        case .cancellation:
            throw CancellationError()
        case .typedInstallerCancellation:
            throw ModelInstallerError.cancelled
        }
    }
}

private struct CancellationLifecycle: ModelCommandLifecycle {
    func activate(immutableCommit: String, verifiedAt: Date) async throws -> SelectionState {
        throw CancellationError()
    }

    func rollback(verifiedAt: Date) async throws -> SelectionState {
        throw CancellationError()
    }

    func garbageCollect() async throws -> ModelGarbageCollectionResult {
        throw CancellationError()
    }
}

private actor CountingDownloadClient: ModelDownloadClient {
    var count = 0

    func response(for request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        count += 1
        throw URLError(.cancelled)
    }
}

private actor FixtureDownloadClient: ModelDownloadClient {
    struct Spec: Sendable {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]
    }

    var specs: [Spec]
    var requests: [ModelDownloadRequest] = []

    init(specs: [Spec]) { self.specs = specs }

    func response(for request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        requests.append(request)
        guard !specs.isEmpty else { throw URLError(.badServerResponse) }
        let spec = specs.removeFirst()
        let body = ModelDownloadBody { sink in
            for chunk in spec.chunks {
                try await sink.push(chunk)
            }
        }
        return ModelDownloadResponse(statusCode: spec.status, headers: spec.headers, body: body)
    }
}

private final class FactoryCounters: @unchecked Sendable {
    private let lock = NSLock()
    var installerCount = 0
    var installerPreflightCount = 0
    var lifecycleCount = 0

    func incrementInstaller() { lock.lock(); installerCount += 1; lock.unlock() }
    func incrementInstallerPreflight() { lock.lock(); installerPreflightCount += 1; lock.unlock() }
    func incrementLifecycle() { lock.lock(); lifecycleCount += 1; lock.unlock() }
}

private actor RecordingLifecycle: ModelCommandLifecycle {
    var activations: [String] = []
    var rollbackCount = 0
    var result = ModelGarbageCollectionResult(deleted: [], skipped: [])

    func activate(immutableCommit: String, verifiedAt: Date) async throws -> SelectionState {
        activations.append(immutableCommit)
        return SelectionState(
            modelId: ModelManifest.supportedModelID,
            variantId: ModelManifest.supportedVariantID,
            currentRevision: immutableCommit,
            priorRevision: nil,
            verifiedAt: verifiedAt
        )
    }

    func rollback(verifiedAt: Date) async throws -> SelectionState {
        rollbackCount += 1
        return SelectionState(
            modelId: ModelManifest.supportedModelID,
            variantId: ModelManifest.supportedVariantID,
            currentRevision: String(repeating: "a", count: 40),
            priorRevision: nil,
            verifiedAt: verifiedAt
        )
    }

    func garbageCollect() async throws -> ModelGarbageCollectionResult { result }

    func gcResult(_ result: ModelGarbageCollectionResult) { self.result = result }
}
