import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ModelVerifierTests: XCTestCase {
    func testValidTreeIsVerifiedBySizeAndHash() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertNoThrow(try ModelVerifier().verify(files: fixture.expectations, at: fixture.root))
    }

    func testMissingFileIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Encoder.mlmodelc/model.mil"))

        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .missingFile(relativePath: "Encoder.mlmodelc/model.mil"))
        }
    }

    func testExtraFileIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("extra".utf8).write(to: fixture.root.appendingPathComponent("extra.txt"))

        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .extraFile(relativePath: "extra.txt"))
        }
    }

    func testUnexpectedDirectoryIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("unexpected"),
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .unexpectedDirectory(relativePath: "unexpected"))
        }
    }

    func testWrongSizeAndWrongHashAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try Data("wrong-size".utf8).write(to: first)

        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .wrongSize(relativePath: "Preprocessor.mlmodelc/metadata.json"))
        }

        let original = Data("metadata".utf8)
        try Data("metadatA".utf8).write(to: first)
        XCTAssertEqual(original.count, Data("metadatA".utf8).count)
        var changed = fixture.expectations
        changed[0] = ModelFileExpectation(
            relativePath: changed[0].relativePath,
            size: Int64(original.count),
            sha256: sha256(original)
        )
        XCTAssertThrowsError(try ModelVerifier().verify(files: changed, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .wrongHash(relativePath: "Preprocessor.mlmodelc/metadata.json"))
        }
    }

    func testSymlinksAreRejectedWithoutFollowingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("Encoder.mlmodelc/model.mil")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.root.appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        )

        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .symlink(relativePath: "Encoder.mlmodelc/model.mil"))
        }
    }

    func testNestedSymlinkAndRootSymlinkAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nested = fixture.root.appendingPathComponent("Encoder.mlmodelc/nested")
        try FileManager.default.createSymbolicLink(
            at: nested,
            withDestinationURL: fixture.root.appendingPathComponent("Preprocessor.mlmodelc")
        )
        var expectations = fixture.expectations
        expectations.append(ModelFileExpectation(relativePath: "Encoder.mlmodelc/nested/file", size: 1, sha256: String(repeating: "0", count: 64)))

        XCTAssertThrowsError(try ModelVerifier().verify(files: expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .symlink(relativePath: "Encoder.mlmodelc/nested"))
        }

        let rootLink = fixture.root.deletingLastPathComponent().appendingPathComponent("root-link")
        defer { try? FileManager.default.removeItem(at: rootLink) }
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: fixture.root)
        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: rootLink)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .rootIsSymlink)
        }
    }

    func testTraversalExpectationIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ModelVerifier().verify(
                files: [ModelFileExpectation(relativePath: "../outside", size: 1, sha256: String(repeating: "0", count: 64))],
                at: root
            )
        ) { error in
            XCTAssertEqual(error as? ModelManifestError, .invalidPath("../outside"))
        }
    }

    func testPathOutsideAllowedArtifactRootsIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ModelVerifier().verify(
                files: [ModelFileExpectation(relativePath: "README.md", size: 1, sha256: String(repeating: "0", count: 64))],
                at: root
            )
        ) { error in
            XCTAssertEqual(error as? ModelManifestError, .invalidPath("README.md"))
        }
    }

    func testUppercaseSHA256ExpectationIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expectation = fixture.expectations[0]
        let uppercase = expectation.sha256.uppercased()
        XCTAssertNotEqual(uppercase, expectation.sha256)
        var expectations = fixture.expectations
        expectations[0] = ModelFileExpectation(
            relativePath: expectation.relativePath,
            size: expectation.size,
            sha256: uppercase
        )

        XCTAssertThrowsError(try ModelVerifier().verify(files: expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelManifestError, .invalidSHA256(expectation.relativePath))
        }
    }

    func testHardLinkAliasIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("Encoder.mlmodelc/alias")
        let source = fixture.root.appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        XCTAssertEqual(link(source.path, alias.path), 0)
        var expectations = fixture.expectations
        expectations.append(ModelFileExpectation(
            relativePath: "Encoder.mlmodelc/alias",
            size: Int64(Data("metadata".utf8).count),
            sha256: sha256(Data("metadata".utf8))
        ))

        XCTAssertThrowsError(try ModelVerifier().verify(files: expectations, at: fixture.root)) { error in
            guard case .hardLink = error as? ModelVerifierError else {
                return XCTFail("expected a hard-link error, got \(error)")
            }
        }
    }

    func testSpecialFileIsRejectedWhenTheHostSupportsIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fifo = fixture.root.appendingPathComponent("Encoder.mlmodelc/fifo")
        guard mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0 else {
            throw XCTSkip("host does not permit FIFO fixtures")
        }
        var expectations = fixture.expectations
        expectations.append(ModelFileExpectation(relativePath: "Encoder.mlmodelc/fifo", size: 0, sha256: String(repeating: "0", count: 64)))

        XCTAssertThrowsError(try ModelVerifier().verify(files: expectations, at: fixture.root)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .specialFile(relativePath: "Encoder.mlmodelc/fifo"))
        }
    }

    func testAbsoluteRootAndMissingRootAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fileRoot = fixture.root.appendingPathComponent("file-root")
        try Data("root".utf8).write(to: fileRoot)
        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: fileRoot)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .rootIsNotDirectory)
        }

        let missing = fixture.root.appendingPathComponent("missing")
        XCTAssertThrowsError(try ModelVerifier().verify(files: fixture.expectations, at: missing)) { error in
            XCTAssertEqual(error as? ModelVerifierError, .rootMissing)
        }
    }

    func testOpenedFileIdentityMustMatchAndRemainStable() throws {
        let inspected = ModelVerifierEntryMetadata(
            device: 1,
            inode: 2,
            mode: 0o100644,
            fileType: ModelVerifierEntryMetadata.regularFileType,
            linkCount: 1,
            size: 5
        )
        let opened = ModelVerifierEntryMetadata(
            device: inspected.device,
            inode: 3,
            mode: inspected.mode,
            fileType: inspected.fileType,
            linkCount: inspected.linkCount,
            size: inspected.size
        )
        XCTAssertThrowsError(
            try ModelVerifier.validateOpenedFile(
                inspected: inspected,
                opened: opened,
                expectedSize: 5,
                relativePath: "Encoder.mlmodelc/model.mil"
            )
        ) { error in
            XCTAssertEqual(error as? ModelVerifierError, .raceDetected(relativePath: "Encoder.mlmodelc/model.mil"))
        }

        let final = ModelVerifierEntryMetadata(
            device: inspected.device,
            inode: inspected.inode,
            mode: inspected.mode ^ 1,
            fileType: inspected.fileType,
            linkCount: 1,
            size: inspected.size
        )
        XCTAssertThrowsError(
            try ModelVerifier.validateFinalFile(
                opened: inspected,
                final: final,
                expectedSize: 5,
                relativePath: "Encoder.mlmodelc/model.mil"
            )
        ) { error in
            XCTAssertEqual(error as? ModelVerifierError, .raceDetected(relativePath: "Encoder.mlmodelc/model.mil"))
        }

        let linked = ModelVerifierEntryMetadata(
            device: inspected.device,
            inode: inspected.inode,
            mode: inspected.mode,
            fileType: inspected.fileType,
            linkCount: 2,
            size: inspected.size
        )
        XCTAssertThrowsError(
            try ModelVerifier.validateFinalFile(
                opened: inspected,
                final: linked,
                expectedSize: 5,
                relativePath: "Encoder.mlmodelc/model.mil"
            )
        ) { error in
            XCTAssertEqual(error as? ModelVerifierError, .raceDetected(relativePath: "Encoder.mlmodelc/model.mil"))
        }
    }

    func testOpenedDirectoryIdentityMustMatchInspectedEntry() throws {
        let inspected = ModelVerifierEntryMetadata(
            device: 1,
            inode: 2,
            mode: 0o40755,
            fileType: ModelVerifierEntryMetadata.directoryFileType,
            linkCount: 2,
            size: 0
        )
        let opened = ModelVerifierEntryMetadata(
            device: 1,
            inode: 3,
            mode: inspected.mode,
            fileType: inspected.fileType,
            linkCount: inspected.linkCount,
            size: inspected.size
        )

        XCTAssertThrowsError(
            try ModelVerifier.validateOpenedDirectory(
                inspected: inspected,
                opened: opened,
                relativePath: "Encoder.mlmodelc"
            )
        ) { error in
            XCTAssertEqual(error as? ModelVerifierError, .raceDetected(relativePath: "Encoder.mlmodelc"))
        }
    }

    private struct Fixture {
        let root: URL
        let expectations: [ModelFileExpectation]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("syrinx-model-verifier-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files: [(String, Data)] = [
                ("Preprocessor.mlmodelc/metadata.json", Data("metadata".utf8)),
                ("Encoder.mlmodelc/model.mil", Data("model".utf8))
            ]
            for (relativePath, data) in files {
                let url = root.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url)
            }
            expectations = files.map { relativePath, data in
                ModelFileExpectation(
                    relativePath: relativePath,
                    size: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                )
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-model-verifier-\(UUID().uuidString)", isDirectory: true)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
