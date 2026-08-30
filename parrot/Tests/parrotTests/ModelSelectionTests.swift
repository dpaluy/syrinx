import XCTest
@testable import SyrinxClient

final class ModelSelectionTests: XCTestCase {
    func testRegistryIncludesServiceBackedParakeetWithoutChangingRecommendation() {
        let parakeet = ModelRegistry.find("parakeet-tdt-0.6b-v3")

        XCTAssertEqual(parakeet?.displayName, "Parakeet TDT 0.6B v3 (local service)")
        XCTAssertEqual(parakeet?.engine, .parakeet)
        XCTAssertNil(parakeet?.whisperKitID)
        XCTAssertEqual(parakeet?.sizeMB, 670)
        XCTAssertEqual(parakeet?.languages, ["en"])
        XCTAssertFalse(parakeet?.recommended ?? true)
        XCTAssertEqual(ModelRegistry.recommended()?.id, "whisper-base.en")
    }

    func testShippingModelsContainOnlyInProcessWhisperKitChoices() {
        XCTAssertFalse(ModelRegistry.inProcessWhisperKitModels.isEmpty)
        XCTAssertTrue(ModelRegistry.inProcessWhisperKitModels.allSatisfy {
            $0.engine == .whisperKit && $0.whisperKitID != nil
        })
        XCTAssertFalse(ModelRegistry.inProcessWhisperKitModels.contains {
            $0.id == "parakeet-tdt-0.6b-v3"
        })
    }

    func testPersistedShippingSelectionFallsBackToRecommendationWhenAbsentOrInvalid() {
        XCTAssertEqual(ModelRegistry.preferredInProcessModel(selectedID: nil)?.id, "whisper-base.en")
        XCTAssertEqual(
            ModelRegistry.preferredInProcessModel(selectedID: "whisper-small.en")?.id,
            "whisper-small.en"
        )
        XCTAssertEqual(
            ModelRegistry.preferredInProcessModel(selectedID: "parakeet-tdt-0.6b-v3")?.id,
            "whisper-base.en"
        )
        XCTAssertEqual(
            ModelRegistry.preferredInProcessModel(selectedID: "unknown")?.id,
            "whisper-base.en"
        )
    }

    func testFactoryDispatchesParakeetWithoutContactingService() throws {
        let model = try XCTUnwrap(ModelRegistry.find("parakeet-tdt-0.6b-v3"))
        let transcriber = try TranscriberFactory.make(model: model)

        XCTAssertTrue(transcriber is ParakeetTranscriber)
        XCTAssertEqual(transcriber.modelID, model.id)
    }

    func testWhisperKitFactoryIgnoresInvalidParakeetURL() throws {
        let whisperModels = ModelRegistry.shared.filter { $0.engine == .whisperKit }
        XCTAssertFalse(whisperModels.isEmpty)

        for model in whisperModels {
            let transcriber = try TranscriberFactory.make(
                model: model,
                parakeetURL: "https://remote.example:5092"
            )
            XCTAssertTrue(transcriber is WhisperKitTranscriber, model.id)
            XCTAssertEqual(transcriber.modelID, model.id)
        }
    }
}
