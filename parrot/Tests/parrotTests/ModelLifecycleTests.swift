import XCTest
@testable import SyrinxClient

final class ModelLifecycleTests: XCTestCase {
    func testModelPreparationPublishesDownloadingDownloadedLoadingAndReady() async throws {
        let folder = URL(fileURLWithPath: "/tmp/syrinx-model")
        let loader = FakeWhisperKitModelLoader(folder: folder)
        let recorder = StateRecorder()
        let model = try XCTUnwrap(ModelRegistry.recommended())
        let transcriber = WhisperKitTranscriber(model: model, loader: loader) { state in
            recorder.append(state)
        }

        try await transcriber.prepare()

        XCTAssertEqual(recorder.values, [
            .checking,
            .downloading(progress: 0.25),
            .downloaded,
            .loading,
            .ready,
        ])
        let resolvedIDs = await loader.resolvedIDs
        let loadedFolders = await loader.loadedFolders
        XCTAssertEqual(resolvedIDs, [model.whisperKitID!])
        XCTAssertEqual(loadedFolders, [folder])
    }

    func testCachedModelStillPublishesDownloadedBeforeReady() async throws {
        let loader = FakeWhisperKitModelLoader(folder: URL(fileURLWithPath: "/tmp/cached"), reportsProgress: false)
        let recorder = StateRecorder()
        let model = try XCTUnwrap(ModelRegistry.recommended())
        let transcriber = WhisperKitTranscriber(model: model, loader: loader) { state in
            recorder.append(state)
        }

        try await transcriber.prepare()

        XCTAssertEqual(recorder.values, [.checking, .downloaded, .loading, .ready])
    }

    func testModelResolutionFailurePublishesFailedAndDoesNotLoad() async throws {
        let loader = FakeWhisperKitModelLoader(error: FakeLoaderError.failed)
        let recorder = StateRecorder()
        let model = try XCTUnwrap(ModelRegistry.recommended())
        let transcriber = WhisperKitTranscriber(model: model, loader: loader) { state in
            recorder.append(state)
        }

        do {
            try await transcriber.prepare()
            XCTFail("Expected model resolution failure")
        } catch {
            XCTAssertEqual(recorder.values.count, 3)
            XCTAssertEqual(recorder.values[0], .checking)
            XCTAssertEqual(recorder.values[1], .downloading(progress: 0.25))
            if case .failed = recorder.values[2] {
                // Expected.
            } else {
                XCTFail("Expected failed model state")
            }
            let loadedFolders = await loader.loadedFolders
            XCTAssertTrue(loadedFolders.isEmpty)
        }
    }
}

private enum FakeLoaderError: Error {
    case failed
}

private actor FakeWhisperKitModelLoader: WhisperKitModelLoader {
    let folder: URL
    let error: Error?
    let reportsProgress: Bool
    private(set) var resolvedIDs: [String] = []
    private(set) var loadedFolders: [URL] = []

    init(folder: URL = URL(fileURLWithPath: "/tmp/model"), reportsProgress: Bool = true) {
        self.folder = folder
        self.error = nil
        self.reportsProgress = reportsProgress
    }

    init(error: Error) {
        self.folder = URL(fileURLWithPath: "/tmp/model")
        self.error = error
        self.reportsProgress = true
    }

    func resolve(
        modelID: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        resolvedIDs.append(modelID)
        if reportsProgress {
            progress(0.25)
        }
        if let error { throw error }
        return folder
    }

    func load(modelFolder: URL) async throws -> any WhisperKitModelPipeline {
        loadedFolders.append(modelFolder)
        return FakeWhisperKitModelPipeline()
    }
}

private struct FakeWhisperKitModelPipeline: WhisperKitModelPipeline {
    func transcribe(_ audio: [Float]) async throws -> String { "transcript" }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [ModelLifecycleState] = []

    func append(_ value: ModelLifecycleState) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
