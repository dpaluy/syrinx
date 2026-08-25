import Foundation
import XCTest
@testable import SyrinxCore

final class ModelStoreTests: XCTestCase {
    func testMissingStateReturnsNil() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertNil(try fixture.store.readInstalled())
        XCTAssertNil(try fixture.store.readSelection())
    }

    func testValidInstalledStateIsRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let state = InstalledState(
            modelId: ModelManifest.supportedModelID,
            variantId: ModelManifest.supportedVariantID,
            revisions: [fixture.revision]
        )
        try AtomicStateWriter().write(state, to: fixture.store.installedURL)

        XCTAssertEqual(try fixture.store.readInstalled(), state)
    }

    func testMalformedStateIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        try Data("{not-json".utf8).write(to: fixture.store.installedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.store.installedURL.path)

        XCTAssertThrowsError(try fixture.store.readInstalled()) { error in
            XCTAssertEqual(error as? ModelStoreError, .malformedState)
        }
    }

    func testSymlinkAndWrongTypeStateAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.store.installedURL, withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.store.readInstalled()) { error in
            XCTAssertEqual(error as? ModelStoreError, .stateIsSymlink)
        }

        try FileManager.default.removeItem(at: fixture.store.installedURL)
        try FileManager.default.createDirectory(at: fixture.store.installedURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try fixture.store.readInstalled()) { error in
            XCTAssertEqual(error as? ModelStoreError, .stateIsNotRegular)
        }
    }

    func testUnsupportedSchemaAndInconsistentModelAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let unsupported = InstalledState(schemaVersion: 99, modelId: ModelManifest.supportedModelID, variantId: ModelManifest.supportedVariantID, revisions: [fixture.revision])
        try AtomicStateWriter().write(unsupported, to: fixture.store.installedURL)
        XCTAssertThrowsError(try fixture.store.readInstalled()) { error in
            XCTAssertEqual(error as? ModelStoreError, .unsupportedSchema(99))
        }

        let inconsistent = InstalledState(schemaVersion: 1, modelId: "other", variantId: ModelManifest.supportedVariantID, revisions: [fixture.revision])
        try AtomicStateWriter().write(inconsistent, to: fixture.store.installedURL)
        XCTAssertThrowsError(try fixture.store.readInstalled()) { error in
            XCTAssertEqual(error as? ModelStoreError, .inconsistentModelVariant)
        }
    }

    func testInvalidCommitIsRejectedWithoutExposingAPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let invalid = InstalledState(
            modelId: ModelManifest.supportedModelID,
            variantId: ModelManifest.supportedVariantID,
            revisions: [InstalledRevision(immutableCommit: "not-a-commit", modelId: ModelManifest.supportedModelID, variantId: ModelManifest.supportedVariantID, verifiedAt: fixture.date)]
        )
        try AtomicStateWriter().write(invalid, to: fixture.store.installedURL)

        XCTAssertThrowsError(try fixture.store.readInstalled()) { error in
            XCTAssertEqual(error as? ModelStoreError, .invalidCommit)
            XCTAssertFalse(String(describing: error).contains(fixture.root.path))
        }
    }

    func testNonPrivateStateIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        try Data("{}".utf8).write(to: fixture.store.installedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.store.installedURL.path)

        XCTAssertThrowsError(try fixture.store.readInstalled()) { error in
            XCTAssertEqual(error as? ModelStoreError, .stateIsNotPrivate)
        }
    }

    func testSelectionMustReferToInstalledRevision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let installed = InstalledState(modelId: ModelManifest.supportedModelID, variantId: ModelManifest.supportedVariantID, revisions: [fixture.revision])
        try AtomicStateWriter().write(installed, to: fixture.store.installedURL)
        let selection = SelectionState(modelId: ModelManifest.supportedModelID, variantId: ModelManifest.supportedVariantID, currentRevision: fixture.otherCommit, priorRevision: nil, verifiedAt: fixture.date)
        try AtomicStateWriter().write(selection, to: fixture.store.selectionURL)

        XCTAssertThrowsError(try fixture.store.readSelection()) { error in
            XCTAssertEqual(error as? ModelStoreError, .selectionNotInstalled)
        }
    }

    func testActivationPreservesPriorRevision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        _ = try fixture.store.recordVerifiedRevision(manifest: fixture.manifest, verifiedAt: fixture.date)
        _ = try fixture.store.recordVerifiedRevision(manifest: fixture.otherManifest, verifiedAt: fixture.date)
        _ = try fixture.store.activate(manifest: fixture.manifest, verifiedAt: fixture.date)

        let selection = try fixture.store.activate(manifest: fixture.otherManifest, verifiedAt: fixture.date)
        XCTAssertEqual(selection.currentRevision, fixture.otherCommit)
        XCTAssertEqual(selection.priorRevision, fixture.manifest.immutableCommit)
    }

    private struct Fixture {
        let root: URL
        let store: ModelStore
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let otherCommit = String(repeating: "b", count: 40)
        let manifest: ModelManifest
        let otherManifest: ModelManifest
        let revision: InstalledRevision

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-store-\(UUID().uuidString)")
            store = ModelStore(root: root)
            let files = [(relativePath: "Preprocessor.mlmodelc/metadata.json", data: Data("fixture".utf8))]
            manifest = ModelManifest(testFiles: files, baseURL: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve")
            otherManifest = ModelManifest(testFiles: files, baseURL: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve", immutableCommit: otherCommit)
            revision = InstalledRevision(immutableCommit: ModelManifest.supportedImmutableCommit, modelId: ModelManifest.supportedModelID, variantId: ModelManifest.supportedVariantID, verifiedAt: date)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
