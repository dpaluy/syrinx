import Foundation
import XCTest
@_spi(Testing) import SyrinxCore
@testable import SyrinxCore

final class RealFluidAudioRuntimeIntegrationTests: XCTestCase {
    func testVerifierRejectsMissingAndCorruptCopiedFilesBeforeRuntime() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SYRINX_REAL_MODEL_PATH"],
              !modelPath.isEmpty
        else {
            throw XCTSkip("set SYRINX_REAL_MODEL_PATH to run the verifier negative proof")
        }

        let source = URL(fileURLWithPath: modelPath, isDirectory: true)
        let copied = source.deletingLastPathComponent()
            .appendingPathComponent("syrinx-t10b-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copied)
        defer { try? FileManager.default.removeItem(at: copied) }

        let vocabulary = copied.appendingPathComponent("parakeet_vocab.json")
        try FileManager.default.removeItem(at: vocabulary)
        XCTAssertThrowsError(try ModelVerifier().verify(manifest: loadManifest(), at: copied)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .missingFile(relativePath: "parakeet_vocab.json"))
        }

        try FileManager.default.copyItem(
            at: source.appendingPathComponent("parakeet_vocab.json"),
            to: vocabulary
        )
        try Data(repeating: 0, count: 151_122).write(to: vocabulary)
        XCTAssertThrowsError(try ModelVerifier().verify(manifest: loadManifest(), at: copied)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .wrongHash(relativePath: "parakeet_vocab.json"))
        }

        print("VERIFIER_NEGATIVE missing=missingFile(parakeet_vocab.json) corrupt=wrongHash(parakeet_vocab.json) runtime_started=false network=not_used")
    }

    func testRealTranscribeExecutableRejectsRemovedModelPathFlagsWithoutLeak() throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SYRINX_REAL_MODEL_PATH"],
              let audioPath = ProcessInfo.processInfo.environment["SYRINX_REAL_AUDIO_PATH"],
              !modelPath.isEmpty,
              !audioPath.isEmpty
        else {
            throw XCTSkip("set SYRINX_REAL_MODEL_PATH and SYRINX_REAL_AUDIO_PATH to run the executable log redaction proof")
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executableCandidates = [
            repositoryRoot.appendingPathComponent(".build/debug/syrinx"),
            repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/syrinx")
        ]
        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("build the syrinx executable before running the subprocess proof")
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "transcribe",
            "--model-path", modelPath,
            "--probe", audioPath,
            audioPath
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stagingRoot = URL(fileURLWithPath: modelPath).deletingLastPathComponent().deletingLastPathComponent().path

        XCTAssertEqual(process.terminationStatus, 2)
        XCTAssertTrue(error.contains("usage: syrinx transcribe"))
        XCTAssertFalse(output.contains(modelPath))
        XCTAssertFalse(error.contains(modelPath))
        XCTAssertFalse(output.contains(stagingRoot))
        XCTAssertFalse(error.contains(stagingRoot))
        XCTAssertFalse(output.contains("FluidAudio."))
        XCTAssertFalse(error.contains("FluidAudio."))
        print("CLI_LOG_BOUNDARY subprocess_status=\(process.terminationStatus) stdout_path_leak=false stderr_path_leak=false third_party_logs=false")
    }

    func testRealNativeEngineUsesSelectedLeaseAndStaysOffline() async throws {
        let setup = try realEngineSetup()
        let storeRoot = setup.storeRoot
        let audioPath = setup.audioPath
        let paths = StandardPaths(data: storeRoot, cache: storeRoot, logs: storeRoot)
        let engine = try NativeTranscriptionEngine(paths: paths)

        await FluidAudioRuntimeTestingState.shared.reset()
        try await engine.start()
        let ready = await engine.isReady
        XCTAssertTrue(ready)
        let offlineModeEnabled = await FluidAudioRuntimeTestingState.shared.isOfflineModeEnabled()
        XCTAssertTrue(offlineModeEnabled)

        let result = try await engine.transcribe(
            TranscriptionRequest(audioFile: URL(fileURLWithPath: audioPath), deadline: 3_600)
        )
        XCTAssertEqual(result.modelID, ServiceConfiguration.defaultModelID)
        XCTAssertEqual(result.modelRevision, setup.selection.currentRevision)
        XCTAssertFalse(result.modelRevision.isEmpty)
        XCTAssertTrue(result.duration > 0)

        let drain = await engine.drain(timeout: .seconds(30))
        XCTAssertEqual(drain, .completed)
        let readyAfterDrain = await engine.isReady
        XCTAssertFalse(readyAfterDrain)
        let leases = try ModelRevisionLeaseManager(store: ModelStore(root: storeRoot))
        guard case .acquired(let lease) = try leases.tryAcquireExclusive(result.modelRevision) else {
            return XCTFail("engine lease remained held after drain")
        }
        lease.close()
        print("REAL_ENGINE model_revision=\(result.modelRevision) model_id=\(result.modelID) offline_control_enabled=\(offlineModeEnabled) network_interception=not_run drain=completed text_empty=\(result.text.isEmpty)")
    }

    private func realEngineSetup() throws -> (modelDirectory: URL, storeRoot: URL, audioPath: String, selection: SelectionState) {
        guard let modelPath = ProcessInfo.processInfo.environment["SYRINX_REAL_MODEL_PATH"],
              let audioPath = ProcessInfo.processInfo.environment["SYRINX_REAL_AUDIO_PATH"],
              !modelPath.isEmpty,
              !audioPath.isEmpty
        else {
            throw XCTSkip("set SYRINX_REAL_MODEL_PATH=<root>/models/revisions/<40-lowercase-hex>/parakeet-tdt-0.6b-v3 and SYRINX_REAL_AUDIO_PATH=<wav>")
        }

        let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true).standardizedFileURL
        let commitDirectory = modelDirectory.deletingLastPathComponent()
        let revisionsDirectory = commitDirectory.deletingLastPathComponent()
        let modelsDirectory = revisionsDirectory.deletingLastPathComponent()
        let storeRoot = modelsDirectory.deletingLastPathComponent()
        let commit = commitDirectory.lastPathComponent
        let validCommit = ModelStore.isValidImmutableCommit(commit)
        guard modelDirectory.lastPathComponent == ModelManifest.supportedRepositoryFolder,
              revisionsDirectory.lastPathComponent == "revisions",
              modelsDirectory.lastPathComponent == "models",
              validCommit,
              FileManager.default.fileExists(atPath: modelDirectory.path)
        else {
            throw XCTSkip("managed real-model setup required: SYRINX_REAL_MODEL_PATH=<root>/models/revisions/<40-lowercase-hex>/parakeet-tdt-0.6b-v3 SYRINX_REAL_AUDIO_PATH=<wav>")
        }

        let store = ModelStore(root: storeRoot)
        do {
            guard let installed = try store.readInstalled(),
                  let selection = try store.readSelection(),
                  installed.revisions.contains(where: { $0.immutableCommit == commit }),
                  selection.currentRevision == commit,
                  store.revisionURL(for: commit).standardizedFileURL.path == modelDirectory.path
            else {
                throw XCTSkip("managed real-model setup must select SYRINX_REAL_MODEL_PATH in installed.json and selection.json")
            }
            return (modelDirectory, storeRoot, audioPath, selection)
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("managed real-model setup could not be read. Install and activate the verified revision before setting SYRINX_REAL_MODEL_PATH")
        }
    }

    func testOfflineMissingModelReturnsTypedDiagnostic() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SYRINX_REAL_MODEL_PATH"],
              !modelPath.isEmpty
        else {
            throw XCTSkip("set SYRINX_REAL_MODEL_PATH to run the offline negative proof")
        }

        let parent = URL(fileURLWithPath: modelPath, isDirectory: true).deletingLastPathComponent()
        let missingRoot = parent.appendingPathComponent("syrinx-t10b-missing-\(UUID().uuidString)", isDirectory: true)
        let missingModel = missingRoot.appendingPathComponent(ModelManifest.supportedRepositoryFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: missingModel, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: missingRoot) }

        let controller = RuntimeController(loader: FluidAudioRuntimeLoader())
        let configuration = RuntimeStartConfiguration(
            modelDirectory: missingModel,
            readinessProbe: TranscriptionRequest(audioFile: URL(fileURLWithPath: "/dev/null"))
        )

        do {
            try await controller.start(configuration)
            XCTFail("missing model unexpectedly loaded")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .modelMissing)
            XCTAssertFalse(diagnostic.description.contains(modelPath))
            print("OFFLINE_NEGATIVE model_missing code=\(diagnostic.code.rawValue) network=blocked_by_offline_mode")
        }
    }

    func testRealFluidAudioRuntimeLoadsOnceAndReusesWarmManager() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SYRINX_REAL_MODEL_PATH"],
              let audioPath = ProcessInfo.processInfo.environment["SYRINX_REAL_AUDIO_PATH"],
              !modelPath.isEmpty,
              !audioPath.isEmpty
        else {
            throw XCTSkip("set SYRINX_REAL_MODEL_PATH and SYRINX_REAL_AUDIO_PATH to run the real runtime proof")
        }

        let manifest = try loadManifest()
        let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let audioFile = URL(fileURLWithPath: audioPath)
        XCTAssertEqual(modelDirectory.lastPathComponent, ModelManifest.supportedRepositoryFolder)
        try ModelVerifier().verify(manifest: manifest, at: modelDirectory)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)

        let metrics = FluidAudioRuntimeMetrics()
        let controller = RuntimeController(loader: FluidAudioRuntimeLoader(metrics: metrics))
        let configuration = RuntimeStartConfiguration(
            modelDirectory: modelDirectory,
            readinessProbe: TranscriptionRequest(audioFile: audioFile)
        )

        let started = ContinuousClock.now
        try await controller.start(configuration)
        let coldAndProbe = started.duration(to: .now)
        let firstStarted = ContinuousClock.now
        let first = try await controller.transcribe(TranscriptionRequest(audioFile: audioFile))
        let firstDuration = firstStarted.duration(to: .now)
        let secondStarted = ContinuousClock.now
        let second = try await controller.transcribe(TranscriptionRequest(audioFile: audioFile))
        let secondDuration = secondStarted.duration(to: .now)
        let snapshot = await metrics.snapshot()
        let drainStarted = ContinuousClock.now
        let drainResult = await controller.drain(timeout: .seconds(30))
        let shutdown = drainStarted.duration(to: .now)

        XCTAssertEqual(snapshot.loadCount, 1)
        XCTAssertEqual(snapshot.managerConstructionCount, 1)
        XCTAssertEqual(drainResult, .completed)
        XCTAssertEqual(first.modelID, ModelManifest.supportedModelID)
        XCTAssertEqual(second.modelID, ModelManifest.supportedModelID)
        XCTAssertFalse(first.text.isEmpty)
        XCTAssertFalse(second.text.isEmpty)

        func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }

        print("REAL_RUNTIME cold_and_probe_seconds=\(seconds(coldAndProbe)) first_post_ready_seconds=\(seconds(firstDuration)) second_warm_seconds=\(seconds(secondDuration)) shutdown_seconds=\(seconds(shutdown)) load_count=\(snapshot.loadCount) manager_count=\(snapshot.managerConstructionCount) readiness_text=\(first.text) first_text=\(first.text) second_text=\(second.text)")
    }

    private func loadManifest() throws -> ModelManifest {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try ModelManifest(data: Data(contentsOf: root.appendingPathComponent("ModelManifests/parakeet-tdt-0.6b-v3-int8.json")))
    }
}
