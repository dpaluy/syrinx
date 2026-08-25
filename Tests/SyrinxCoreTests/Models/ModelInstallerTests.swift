import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ModelInstallerTests: XCTestCase {
    func testFresh200StreamsAndCommitsWithoutActivation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])])
        let installer = try fixture.installer(client: client)

        let result = try await installer.install()

        XCTAssertEqual(result, ModelInstallResult(immutableCommit: fixture.commit, activated: false))
        XCTAssertTrue(fixture.store.revisionURL(for: fixture.commit).path.hasSuffix("/\(ModelManifest.supportedRepositoryFolder)"))
        XCTAssertNotNil(try fixture.store.readInstalled())
        XCTAssertNil(try fixture.store.readSelection())
        let freshRequests = await client.requests()
        XCTAssertEqual(freshRequests.first?.rangeStart, nil)
    }

    func testResumeUsesExactRangeAndCommits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let partialRoot = fixture.store.downloadsDirectory.appendingPathComponent("\(fixture.commit).partial/\(ModelManifest.supportedRepositoryFolder)")
        try FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        let partialFile = partialRoot.appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try FileManager.default.createDirectory(at: partialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: partialFile)
        let client = FixtureClient(specs: [.init(status: 206, headers: ["content-length": "3", "content-range": "bytes 3-5/6"], chunks: [Data("def".utf8)])])

        _ = try await fixture.installer(client: client).install()

        let requests = await client.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].rangeStart, 3)
        XCTAssertEqual(try Data(contentsOf: fixture.store.revisionURL(for: fixture.commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")), Data("abcdef".utf8))
    }

    func test200ToRangeSafelyRestartsFromZero() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let partialRoot = fixture.store.downloadsDirectory.appendingPathComponent("\(fixture.commit).partial/\(ModelManifest.supportedRepositoryFolder)")
        let partialFile = partialRoot.appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try FileManager.default.createDirectory(at: partialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: partialFile)
        let client = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])])

        _ = try await fixture.installer(client: client).install()

        XCTAssertEqual(try Data(contentsOf: fixture.store.revisionURL(for: fixture.commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")), Data("abcdef".utf8))
    }

    func testInvalidRangeAndWrongLengthLeaveStateUnchanged() async throws {
        let cases: [(status: Int, headers: [String: String], error: ModelInstallerError)] = [
            (206, ["content-length": "3", "content-range": "bytes 2-5/6"], .invalidContentRange),
            (200, ["content-length": "5"], .wrongContentLength)
        ]
        for item in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makePartial(prefix: Data("abc".utf8))
            let client = FixtureClient(specs: [.init(status: item.status, headers: item.headers, chunks: [Data("def".utf8)])])

            do {
                _ = try await fixture.installer(client: client).install()
                XCTFail("expected \(item.error)")
            } catch let error as ModelInstallerError {
                XCTAssertEqual(error, item.error)
            }
            XCTAssertNil(try fixture.store.readInstalled())
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.commit).path))
        }
    }

    func testTruncationOverrunHashMismatchAndCancellationDoNotCommit() async throws {
        let specs: [(FixtureClient.Spec, ModelInstallerError)] = [
            (.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abc".utf8)]), .truncatedResponse),
            (.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdefg".utf8)]), .responseOverrun),
            (.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdeg".utf8)]), .hashMismatch)
        ]
        for (spec, expected) in specs {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let client = FixtureClient(specs: [spec])
            do {
                _ = try await fixture.installer(client: client).install()
                XCTFail("expected \(expected)")
            } catch let error as ModelInstallerError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertNil(try fixture.store.readInstalled())
        }

        let cancelledFixture = try Fixture()
        defer { cancelledFixture.remove() }
        let cancelledClient = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)], failure: .disconnected)])
        do {
            _ = try await cancelledFixture.installer(client: cancelledClient).install()
            XCTFail("expected connection loss")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .connectionLost)
        }

        let timeoutFixture = try Fixture()
        defer { timeoutFixture.remove() }
        let timeoutClient = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [], failure: .timedOut)])
        do {
            _ = try await timeoutFixture.installer(client: timeoutClient).install()
            XCTFail("expected timeout")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .timeout)
        }

        let cancellationFixture = try Fixture()
        defer { cancellationFixture.remove() }
        let cancellationClient = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)], failure: .cancelled)])
        do {
            _ = try await cancellationFixture.installer(client: cancellationClient).install()
            XCTFail("expected cancellation")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testUnsafePartialSymlinkIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let partialRoot = fixture.store.downloadsDirectory.appendingPathComponent("\(fixture.commit).partial/\(ModelManifest.supportedRepositoryFolder)/Preprocessor.mlmodelc")
        try FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        let link = partialRoot.appendingPathComponent("metadata.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("outside"))
        let client = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])])

        do {
            _ = try await fixture.installer(client: client).install()
            XCTFail("expected symlink rejection")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .partialIsSymlink)
        }
    }

    func testExistingVerifiedTargetIsAcceptedAndConflictIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let target = fixture.store.revisionsDirectory.appendingPathComponent(fixture.commit)
        let file = target.appendingPathComponent(ModelManifest.supportedRepositoryFolder).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abcdef".utf8).write(to: file)
        try setPrivateModes(below: target)
        let client = FixtureClient(specs: [])
        _ = try await fixture.installer(client: client).install()
        let existingRequests = await client.requests()
        XCTAssertTrue(existingRequests.isEmpty)

        let badFixture = try Fixture()
        defer { badFixture.remove() }
        try badFixture.store.prepareDirectories()
        let badTarget = badFixture.store.revisionsDirectory.appendingPathComponent(badFixture.commit)
        let badFile = badTarget.appendingPathComponent(ModelManifest.supportedRepositoryFolder).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try FileManager.default.createDirectory(at: badFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: badFile)
        do {
            _ = try await badFixture.installer(client: FixtureClient(specs: [])).install()
            XCTFail("expected target conflict")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .targetConflict)
        }
    }

    func testExistingVerifiedTargetSkipsDiskPreflight() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let target = fixture.store.revisionsDirectory.appendingPathComponent(fixture.commit)
        let file = target.appendingPathComponent(ModelManifest.supportedRepositoryFolder)
            .appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abcdef".utf8).write(to: file)
        try setPrivateModes(below: target)

        let installer = try fixture.installer(
            client: FixtureClient(specs: []),
            disk: FixedDiskSpaceProvider(bytes: 0)
        )
        _ = try await installer.install()
    }

    func testPartialDiskPreflightCountsOnlyBytesStillMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makePartial(prefix: Data("abc".utf8))
        let client = FixtureClient(specs: [
            .init(status: 206, headers: ["content-length": "3", "content-range": "bytes 3-5/6"], chunks: [Data("def".utf8)])
        ])
        let installer = try fixture.installer(
            client: client,
            disk: FixedDiskSpaceProvider(bytes: 3)
        )

        _ = try await installer.install()
        XCTAssertEqual(
            try Data(contentsOf: fixture.store.revisionURL(for: fixture.commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")),
            Data("abcdef".utf8)
        )
    }

    func testParentSymlinkSwapCannotEscapeDescriptorRelativeStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let partialParent = fixture.store.downloadsDirectory
            .appendingPathComponent("\(fixture.commit).partial")
            .appendingPathComponent(ModelManifest.supportedRepositoryFolder)
            .appendingPathComponent("Preprocessor.mlmodelc")
        let swap = SwapOnce {
            try? FileManager.default.removeItem(at: partialParent)
            try? FileManager.default.createSymbolicLink(at: partialParent, withDestinationURL: outside)
        }
        let client = FixtureClient(specs: [
            .init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])
        ])

        do {
            _ = try await fixture.installer(client: client, stagingAccessHook: { event in
                if event.relativePath == "Preprocessor.mlmodelc" {
                    swap.run()
                }
            }).install()
            XCTFail("expected staging swap rejection")
        } catch let error as ModelInstallerError {
            XCTAssertTrue([.partialIsSymlink, .unsafePartial].contains(error))
        }
        XCTAssertFalse(outside.appendingPathComponent("metadata.json").exists)
        XCTAssertFalse(fixture.store.revisionURL(for: fixture.commit).exists)
    }

    func testRepositorySwapAfterVerificationIsRejectedBeforeCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let repository = fixture.store.downloadsDirectory
            .appendingPathComponent("\(fixture.commit).partial")
            .appendingPathComponent(ModelManifest.supportedRepositoryFolder)
        let swap = SwapOnce {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.createSymbolicLink(at: repository, withDestinationURL: outside)
        }
        let client = FixtureClient(specs: [
            .init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])
        ])

        do {
            _ = try await fixture.installer(client: client, stagingAccessHook: { event in
                if event.phase == .afterVerify { swap.run() }
            }).install()
            XCTFail("expected repository identity rejection")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .verificationFailed)
        }
        XCTAssertFalse(outside.appendingPathComponent("Preprocessor.mlmodelc/metadata.json").exists)
        XCTAssertFalse(fixture.store.revisionURL(for: fixture.commit).exists)
    }

    func testPartialRootSwapBeforeCommitIsRejectedWithoutCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let partial = fixture.store.downloadsDirectory.appendingPathComponent("\(fixture.commit).partial")
        let swap = SwapOnce {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.createSymbolicLink(at: partial, withDestinationURL: outside)
        }
        let client = FixtureClient(specs: [
            .init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])
        ])

        do {
            _ = try await fixture.installer(client: client, stagingAccessHook: { event in
                if event.phase == .beforeCommit { swap.run() }
            }).install()
            XCTFail("expected partial identity rejection")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .unsafePartial)
        }
        XCTAssertFalse(outside.appendingPathComponent("Preprocessor.mlmodelc/metadata.json").exists)
        XCTAssertFalse(fixture.store.revisionURL(for: fixture.commit).exists)
    }

    func testPostRenameSyncFailureRemovesUnrecordedTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.prepareDirectories()
        let previousCommit = String(repeating: "b", count: 40)
        let previous = InstalledState(
            modelId: fixture.manifest.modelId,
            variantId: fixture.manifest.variantId,
            revisions: [InstalledRevision(
                immutableCommit: previousCommit,
                modelId: fixture.manifest.modelId,
                variantId: fixture.manifest.variantId,
                verifiedAt: Date(timeIntervalSince1970: 1)
            )]
        )
        let selection = SelectionState(
            modelId: fixture.manifest.modelId,
            variantId: fixture.manifest.variantId,
            currentRevision: previousCommit,
            priorRevision: nil,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        try AtomicStateWriter().write(previous, to: fixture.store.installedURL)
        try AtomicStateWriter().write(selection, to: fixture.store.selectionURL)
        let oldInstalledBytes = try Data(contentsOf: fixture.store.installedURL)
        let oldSelectionBytes = try Data(contentsOf: fixture.store.selectionURL)

        do {
            _ = try await fixture.installer(
                client: FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])]),
                postRenameSyncHook: { throw PostRenameSyncFailure.injected }
            ).install()
            XCTFail("expected post-rename sync failure")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .directoryOperationFailed)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.store.installedURL), oldInstalledBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.store.selectionURL), oldSelectionBytes)
        XCTAssertFalse(fixture.store.revisionURL(for: fixture.commit).exists)
    }

    func testInstalledStateWriteFailurePreservesOldBytesAndRemovesNewTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-installer-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldState = InstalledState(
            modelId: ModelManifest.supportedModelID,
            variantId: ModelManifest.supportedVariantID,
            revisions: [InstalledRevision(immutableCommit: String(repeating: "b", count: 40), modelId: ModelManifest.supportedModelID, variantId: ModelManifest.supportedVariantID, verifiedAt: Date(timeIntervalSince1970: 1))]
        )
        let store = ModelStore(root: root, writer: AtomicStateWriter(failureInjector: { $0 == .rename }))
        try store.prepareDirectories()
        try AtomicStateWriter().write(oldState, to: store.installedURL)
        let data = Data("abcdef".utf8)
        let manifest = ModelManifest(testFiles: [("Preprocessor.mlmodelc/metadata.json", data)], baseURL: "http://fixture.invalid/model", immutableCommit: String(repeating: "a", count: 40))
        let client = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [data])])
        let installer = ModelInstaller(unvalidatedManifestForTesting: manifest, store: store, downloadClient: client, enforceHTTPS: false)

        do {
            _ = try await installer.install()
            XCTFail("expected state write failure")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .stateUpdateFailed)
        }
        XCTAssertEqual(try Data(contentsOf: store.installedURL), try AtomicStateWriter.defaultEncoder.encode(oldState))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.revisionURL(for: manifest.immutableCommit).deletingLastPathComponent().path))
    }

    func testDiskFullDoesNotChangeInstalledState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = FixtureClient(specs: [.init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])])
        let installer = try fixture.installer(client: client, disk: FixedDiskSpaceProvider(bytes: 1))

        do {
            _ = try await installer.install()
            XCTFail("expected disk-full error")
        } catch let error as ModelInstallerError {
            XCTAssertEqual(error, .diskFull)
        }
        XCTAssertNil(try fixture.store.readInstalled())
    }

    func testConcurrentInstallsProduceOneCommittedTreeAndConsistentState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let client = FixtureClient(specs: [
            .init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)]),
            .init(status: 200, headers: ["content-length": "6"], chunks: [Data("abcdef".utf8)])
        ])
        let installer = try fixture.installer(client: client)
        async let first = installer.install()
        async let second = installer.install()
        _ = try await (first, second)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.commit).path))
        XCTAssertEqual(try fixture.store.readInstalled()?.revisions.count, 1)
    }

    private struct Fixture {
        let root: URL
        let store: ModelStore
        let commit = String(repeating: "a", count: 40)
        let manifest: ModelManifest

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-installer-\(UUID().uuidString)")
            let data = Data("abcdef".utf8)
            manifest = ModelManifest(testFiles: [("Preprocessor.mlmodelc/metadata.json", data)], baseURL: "http://fixture.invalid/model", immutableCommit: String(repeating: "a", count: 40))
            store = ModelStore(root: root)
        }

        func installer(
            client: FixtureClient,
            disk: any ModelDiskSpaceProvider = FixedDiskSpaceProvider(bytes: Int64.max),
            stagingAccessHook: ModelStagingAccessHook? = nil,
            postRenameSyncHook: ModelPostRenameSyncHook? = nil
        ) throws -> ModelInstaller {
            ModelInstaller(
                unvalidatedManifestForTesting: manifest,
                store: store,
                downloadClient: client,
                diskSpaceProvider: disk,
                enforceHTTPS: false,
                stagingAccessHook: stagingAccessHook,
                postRenameSyncHook: postRenameSyncHook
            )
        }

        func makePartial(prefix: Data) throws {
            try store.prepareDirectories()
            let file = store.downloadsDirectory.appendingPathComponent("\(commit).partial/\(ModelManifest.supportedRepositoryFolder)/Preprocessor.mlmodelc/metadata.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try prefix.write(to: file)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func setPrivateModes(below root: URL) throws {
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) + [""] {
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let mode: NSNumber = (info.st_mode & S_IFMT) == S_IFDIR ? 0o700 : 0o600
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }
}

private final class SwapOnce: @unchecked Sendable {
    private let action: () -> Void
    private let lock = NSLock()
    private var didRun = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRun else { return }
        didRun = true
        action()
    }
}

private extension URL {
    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private actor FixtureClient: ModelDownloadClient {
    struct Spec: Sendable {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]
        let failure: FixtureClientFailure?

        init(status: Int, headers: [String: String], chunks: [Data], failure: FixtureClientFailure? = nil) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
            self.failure = failure
        }
    }

    private var specs: [Spec]
    private var recordedRequests: [ModelDownloadRequest] = []

    init(specs: [Spec]) {
        self.specs = specs
    }

    func response(for request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        recordedRequests.append(request)
        guard !specs.isEmpty else { throw FixtureClientFailure.noResponse }
        let spec = specs.removeFirst()
        let body = ModelDownloadBody { sink in
            for chunk in spec.chunks {
                try await sink.push(chunk)
            }
            if let failure = spec.failure {
                switch failure {
                case .timedOut:
                    throw URLError(.timedOut)
                case .cancelled:
                    throw CancellationError()
                default:
                    throw failure
                }
            }
        }
        return ModelDownloadResponse(statusCode: spec.status, headers: spec.headers, body: body)
    }

    func requests() -> [ModelDownloadRequest] { recordedRequests }
}

private enum FixtureClientFailure: Error, Sendable {
    case noResponse
    case disconnected
    case timedOut
    case cancelled
}

private enum PostRenameSyncFailure: Error {
    case injected
}
