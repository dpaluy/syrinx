import Foundation
import XCTest
@testable import SyrinxCore

final class ModelManifestTests: XCTestCase {
    func testGoldenManifestIsAcceptedAndHasTheRecordedDigest() throws {
        let manifest = try ModelManifest(data: goldenData())

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.modelId, ModelManifest.supportedModelID)
        XCTAssertEqual(manifest.variantId, ModelManifest.supportedVariantID)
        XCTAssertEqual(manifest.immutableCommit, ModelManifest.supportedImmutableCommit)
        XCTAssertEqual(manifest.files.count, 21)
        XCTAssertEqual(manifest.totalSize, 483_105_645)
        XCTAssertEqual(
            manifest.manifestContentDigest.hex,
            "3967d537c8ed54cc46586cdaa7eec5d61c9cb9ea7bf4d16039ffb773102326d9"
        )
    }

    func testDigestUsesCanonicalJSONRatherThanSourceFormatting() throws {
        var object = try goldenObject()
        let reformatted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )

        XCTAssertNoThrow(try ModelManifest(data: reformatted))

        object["manifestContentDigest"] = [
            "algorithm": "SHA-256",
            "hex": String(repeating: "0", count: 64),
            "procedure": "test",
            "selfExclusion": "test"
        ]
        XCTAssertThrowsError(try ModelManifest(data: JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? ModelManifestError, .invalidManifestDigest)
        }
    }

    func testValidatedDataInitializerIsTheManifestConstructionPath() throws {
        var object = try goldenObject()
        var digest = object["manifestContentDigest"] as! [String: Any]
        digest["hex"] = String(repeating: "0", count: 64)
        object["manifestContentDigest"] = digest
        let invalid = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try ModelManifest(data: invalid)) { error in
            XCTAssertEqual(error as? ModelManifestError, .invalidManifestDigest)
        }
    }

    func testRejectsEveryManifestSafetyAndCompatibilityFailure() throws {
        let cases: [(String, (inout [String: Any]) -> Void, ModelManifestError)] = [
            ("unknown schema", { $0["schemaVersion"] = 2 }, .unsupportedSchema(2)),
            ("wrong model", { $0["modelId"] = "other-model" }, .incompatibleModel),
            ("wrong commit", { $0["immutableCommit"] = String(repeating: "b", count: 40) }, .invalidImmutableCommit),
            ("wrong FluidAudio commit", { object in
                var compatibility = object["fluidAudioCompatibility"] as! [String: Any]
                compatibility["commit"] = String(repeating: "b", count: 40)
                object["fluidAudioCompatibility"] = compatibility
            }, .incompatibleFluidAudio),
            ("unsafe repository folder", { object in
                var staging = object["staging"] as! [String: Any]
                staging["repositoryFolder"] = "../outside"
                object["staging"] = staging
            }, .unsafeRepositoryFolder),
            ("absolute path", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "/absolute/file"
                object["files"] = files
            }, .invalidPath("/absolute/file")),
            ("empty path component", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "Decoder.mlmodelc//file"
                object["files"] = files
            }, .invalidPath("Decoder.mlmodelc//file")),
            ("dot segment", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "Decoder.mlmodelc/../file"
                object["files"] = files
            }, .invalidPath("Decoder.mlmodelc/../file")),
            ("backslash", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "Decoder.mlmodelc\\file"
                object["files"] = files
            }, .invalidPath("Decoder.mlmodelc\\file")),
            ("NUL", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "Decoder.mlmodelc/\u{0}file"
                object["files"] = files
            }, .invalidPath("Decoder.mlmodelc/\u{0}file")),
            ("outside allowed roots", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "README.md"
                object["files"] = files
            }, .invalidPath("README.md")),
            ("duplicate path", { object in
                var files = object["files"] as! [[String: Any]]
                files[1]["relativePath"] = files[0]["relativePath"]
                object["files"] = files
            }, .duplicatePath("Decoder.mlmodelc/analytics/coremldata.bin")),
            ("duplicate URL", { object in
                var files = object["files"] as! [[String: Any]]
                files[1]["url"] = files[0]["url"]
                object["files"] = files
            }, .duplicateURL),
            ("mutable URL", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["url"] = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/Decoder.mlmodelc/analytics/coremldata.bin"
                object["files"] = files
            }, .mutableOrWrongCommitURL("Decoder.mlmodelc/analytics/coremldata.bin")),
            ("invalid SHA-256", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["sha256"] = "not-a-sha256"
                object["files"] = files
            }, .invalidSHA256("Decoder.mlmodelc/analytics/coremldata.bin")),
            ("uppercase SHA-256", { object in
                var files = object["files"] as! [[String: Any]]
                let sha256 = files[0]["sha256"] as! String
                files[0]["sha256"] = sha256.uppercased()
                object["files"] = files
            }, .invalidSHA256("Decoder.mlmodelc/analytics/coremldata.bin")),
            ("invalid file size", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["size"] = -1
                object["files"] = files
            }, .invalidFileSize("Decoder.mlmodelc/analytics/coremldata.bin")),
            ("inconsistent file count", { object in
                var files = object["files"] as! [[String: Any]]
                files.removeLast()
                object["files"] = files
            }, .invalidFileCount(expected: 21, actual: 20)),
            ("inconsistent total", { $0["totalSize"] = 1 }, .invalidTotalSize(expected: 483_105_645, actual: 1)),
            ("invalid digest", { object in
                var digest = object["manifestContentDigest"] as! [String: Any]
                digest["hex"] = String(repeating: "0", count: 64)
                object["manifestContentDigest"] = digest
            }, .invalidManifestDigest)
        ]

        for (name, mutate, expectedError) in cases {
            var object = try goldenObject()
            mutate(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try ModelManifest(data: data), "case: \(name)") { error in
                XCTAssertEqual(error as? ModelManifestError, expectedError, "case: \(name)")
            }
        }
    }

    func testPublicErrorDescriptionsRedactAbsolutePaths() {
        let absolutePath = "/absolute/private-model/file.bin"

        XCTAssertFalse(ModelManifestError.invalidPath(absolutePath).description.contains(absolutePath))
        XCTAssertFalse(ModelVerifierError.symlink(relativePath: absolutePath).description.contains(absolutePath))
        XCTAssertFalse(ModelVerifierError.raceDetected(relativePath: absolutePath).description.contains(absolutePath))
    }

    private func goldenData() throws -> Data {
        try Data(contentsOf: manifestURL)
    }

    private func goldenObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: goldenData()) as? [String: Any])
    }

    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ModelManifests/parakeet-tdt-0.6b-v3-int8.json")
    }
}
