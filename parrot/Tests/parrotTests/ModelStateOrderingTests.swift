import XCTest
@testable import SyrinxClient

@MainActor
final class ModelStateOrderingTests: XCTestCase {
    func testOlderModelStatesCannotOverwriteNewerReadyOrFailedState() {
        let state = SettingsState(model: model, modelState: .checking)

        state.setModelState(.ready, sequence: 10)
        for olderState in [
            ModelLifecycleState.checking,
            .downloading(progress: 0.25),
            .loading,
            .failed("old failure"),
        ] {
            state.setModelState(olderState, sequence: 9)
        }
        XCTAssertEqual(state.modelState, .ready)

        state.setModelState(.failed("new failure"), sequence: 20)
        for olderState in [
            ModelLifecycleState.checking,
            .downloading(progress: nil),
            .loading,
            .ready,
        ] {
            state.setModelState(olderState, sequence: 19)
        }
        XCTAssertEqual(state.modelState, .failed("new failure"))
    }

    private let model = TranscriptionModel(
        id: "test-model",
        displayName: "Test model",
        engine: .whisperKit,
        whisperKitID: "test-model",
        sizeMB: 1,
        languages: ["en"],
        recommended: false
    )
}
