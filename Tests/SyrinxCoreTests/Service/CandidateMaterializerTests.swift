import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class CandidateMaterializerTests: XCTestCase {
    func testPackageMaterializesValidatedCandidateWithExactBytesAndNoSelectionMutation() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }

        let selectionBefore = try Data(contentsOf: fixture.selectionURL)
        let result: TrustedMaterializedCandidate
        do {
            result = try await fixture.materializer().materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        } catch {
            XCTFail("package materialization failed: \(error)")
            return
        }

        XCTAssertEqual(result.version, MaterializerFixture.version)
        XCTAssertEqual(result.sourceIdentity.commit, MaterializerFixture.sourceCommit)
        XCTAssertEqual(result.sourceIdentity.tag, MaterializerFixture.tag)
        XCTAssertEqual(result.manifestDigest, MaterializerFixture.manifestDigest)
        XCTAssertEqual(try fixture.mode(of: result.destination), 0o555)
        XCTAssertEqual(
            try Data(contentsOf: fixture.selectionURL),
            selectionBefore
        )
        XCTAssertNoThrow(try result.lease.verifyStillValid())
        for relative in MaterializerFixture.payloadFiles {
            let source = fixture.packageSource.appendingPathComponent(relative)
            let destination = result.destination.appendingPathComponent(relative)
            XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source), relative)
            let sourceMode = try fixture.mode(of: source)
            let destinationMode = try fixture.mode(of: destination)
            XCTAssertEqual(destinationMode & 0o222, 0, relative)
            XCTAssertEqual(destinationMode, sourceMode & 0o7555, relative)
        }
    }

    func testOrdinaryT50BSourceModesMaterializeImmutableAndGroupWorldWritesFail() async throws {
        do {
            let fixture = try MaterializerFixture()
            defer { fixture.cleanup() }
            XCTAssertEqual(try fixture.mode(of: fixture.packageSource.appendingPathComponent(MaterializerFixture.executable)), 0o755)
            XCTAssertEqual(try fixture.mode(of: fixture.packageSource.appendingPathComponent(MaterializerFixture.manifestPath)), 0o644)
            let result = try await fixture.materializer().materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
            XCTAssertEqual(
                try fixture.mode(of: result.destination.appendingPathComponent(MaterializerFixture.executable)),
                0o555
            )
            XCTAssertEqual(
                try fixture.mode(of: result.destination.appendingPathComponent(MaterializerFixture.manifestPath)),
                0o444
            )
        }

        do {
            let fixture = try MaterializerFixture()
            defer { fixture.cleanup() }
            try fixture.makeGroupWorldWritable()
            await expectFailure {
                _ = try await fixture.materializer().materialize(
                    packageAt: fixture.packageSource,
                    dataRoot: fixture.destinationDataRoot
                )
            }
        }
    }

    func testAbsentDestinationParentsAreCreatedAndFsyncedBeforeMaterialization() async throws {
        let fixture = try MaterializerFixture(precreateDestinationLayout: false)
        defer { fixture.cleanup() }
        let dataRootParentSynced = LockedFlag()
        let serviceParentSynced = LockedFlag()

        let result = try await fixture.materializer(directorySyncObserver: { path in
            if path == fixture.destinationDataRoot.path {
                dataRootParentSynced.set()
            }
            if path == fixture.destinationDataRoot.appendingPathComponent("service").path {
                serviceParentSynced.set()
            }
        }).materialize(
            packageAt: fixture.packageSource,
            dataRoot: fixture.destinationDataRoot
        )

        XCTAssertTrue(dataRootParentSynced.value)
        XCTAssertTrue(serviceParentSynced.value)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions").path
        ))
        XCTAssertNoThrow(try result.lease.verifyStillValid())
    }

    func testDestinationDirectoryIdentityProofAcceptsASeparateSourceDevice() {
        var held = stat()
        held.st_dev = 200
        held.st_ino = 300
        held.st_mode = mode_t(S_IFDIR) | mode_t(0o555)
        held.st_nlink = 1
        held.st_size = 0
        held.st_mtimespec.tv_sec = 10
        held.st_ctimespec.tv_sec = 10
        var visible = held

        XCTAssertNotEqual(held.st_dev, dev_t(100))
        XCTAssertTrue(destinationDirectoryIdentityMatches(held, visible))
        visible.st_dev = 201
        XCTAssertFalse(destinationDirectoryIdentityMatches(held, visible))
    }

    func testHomebrewLibexecMaterializesSameVersionedPayload() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.materializer().materialize(
            homebrewLibexecAt: fixture.homebrewSource,
            dataRoot: fixture.destinationDataRoot
        )

        XCTAssertEqual(result.destination.lastPathComponent, MaterializerFixture.version)
        XCTAssertEqual(
            try Data(contentsOf: result.destination.appendingPathComponent("metadata/model-manifest.json")),
            MaterializerFixture.manifestData
        )
        XCTAssertEqual(
            try Data(contentsOf: result.destination.appendingPathComponent("SYRINX_SyrinxCore.bundle/parakeet-tdt-0.6b-v3-int8.json")),
            MaterializerFixture.manifestData
        )
        XCTAssertNoThrow(try result.lease.verifyStillValid())
    }

    func testUntrustedPackageDirectoryNameCannotRedirectOutput() async throws {
        let fixture = try MaterializerFixture(packageDirectoryName: "attacker-selected-version")
        defer { fixture.cleanup() }

        let result = try await fixture.materializer().materialize(
            packageAt: fixture.packageSource,
            dataRoot: fixture.destinationDataRoot
        )

        XCTAssertEqual(result.version, MaterializerFixture.version)
        XCTAssertEqual(result.destination.lastPathComponent, MaterializerFixture.version)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions/attacker-selected-version").path
        ))
    }

    func testDestinationCollisionIsRejectedAndLeavesNoStagingDirectory() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.materializer().materialize(
            packageAt: fixture.packageSource,
            dataRoot: fixture.destinationDataRoot
        )
        await expectFailure {
            _ = try await fixture.materializer().materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions").path
        )
        XCTAssertEqual(names, [MaterializerFixture.version])
    }

    func testSourceSymlinkHardLinkFIFOAndWrongLayoutFailClosed() async throws {
        do {
            let fixture = try MaterializerFixture()
            defer { fixture.cleanup() }
            try fixture.replacePackageSourceWithSymlink()
            await expectFailure {
                _ = try await fixture.materializer().materialize(
                    packageAt: fixture.packageSource,
                    dataRoot: fixture.destinationDataRoot
                )
            }
        }

        do {
            let fixture = try MaterializerFixture()
            defer { fixture.cleanup() }
            try fixture.addHardLink()
            await expectFailure {
                _ = try await fixture.materializer().materialize(
                    packageAt: fixture.packageSource,
                    dataRoot: fixture.destinationDataRoot
                )
            }
        }

        do {
            let fixture = try MaterializerFixture()
            defer { fixture.cleanup() }
            try fixture.addFIFO()
            await expectFailure {
                _ = try await fixture.materializer().materialize(
                    packageAt: fixture.packageSource,
                    dataRoot: fixture.destinationDataRoot
                )
            }
        }

        do {
            let fixture = try MaterializerFixture(wrongPackageParent: true)
            defer { fixture.cleanup() }
            await expectFailure {
                _ = try await fixture.materializer().materialize(
                    packageAt: fixture.packageSource,
                    dataRoot: fixture.destinationDataRoot
                )
            }
        }
    }

    func testDestinationAncestorSymlinkIsRejectedWithoutSelectionMutation() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }

        let selectionBefore = try Data(contentsOf: fixture.selectionURL)
        try fixture.replaceDestinationServiceWithSymlink()
        await expectFailure {
            _ = try await fixture.materializer().materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertEqual(selectionBefore, Data("{\"activeVersion\":null}\n".utf8))
    }

    func testSourceReplacementDuringDescriptorCopyFailsAndDoesNotPublish() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let changed = LockedFlag()
        let materializer = fixture.materializer(observer: { _ in
            guard changed.takeOnce() else { return }
            try? fixture.replaceTargetBytes()
        })

        await expectFailure {
            _ = try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertTrue(changed.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions/1.2.3").path
        ))
    }

    func testSourceAncestorReplacementDuringCopyFailsClosed() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let changed = LockedFlag()
        let materializer = fixture.materializer(observer: { _ in
            guard changed.takeOnce() else { return }
            try? fixture.replacePackageAncestor()
        })

        await expectFailure {
            _ = try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertTrue(changed.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions/1.2.3").path
        ))
    }

    func testDestinationAncestorReplacementDuringCopyFailsClosed() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let changed = LockedFlag()
        let materializer = fixture.materializer(observer: { _ in
            guard !changed.value,
                  (try? fixture.replaceDestinationVersionsWithSentinel()) == true
            else { return }
            changed.set()
        })

        await expectFailure {
            _ = try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertTrue(changed.value)
        XCTAssertTrue(try fixture.destinationReplacementSentinelExists())
    }

    func testStagingReplacementBeforeForcedFailureSurvivesCleanup() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let replaced = LockedFlag()
        let failureCalls = LockedFlag()
        let materializer = fixture.materializer(
            copyFailure: { _ in
                failureCalls.set()
                guard !replaced.value,
                      (try? fixture.replaceCurrentStagingWithSentinel()) == true
                else { return nil }
                replaced.set()
                return .copyFailed("forced cleanup test failure")
            }
        )

        await expectFailure {
            _ = try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertTrue(failureCalls.value)
        XCTAssertTrue(replaced.value)
        XCTAssertTrue(try fixture.replacementSentinelExists())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions/1.2.3").path
        ))
    }

    func testStagingReplacementBetweenCreateAndOpenIsNotAcceptedOrDeleted() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let replaced = LockedFlag()

        await expectFailure {
            _ = try await fixture.materializer(stagingOpenObserver: { path in
                guard replaced.takeOnce() else { return }
                try? fixture.replaceStagingBeforeOpen(path: path)
            }).materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }

        XCTAssertTrue(replaced.value)
        XCTAssertTrue(try fixture.replacementSentinelExists())
    }

    func testPostRenameInventoryTamperingFailsClosed() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let tampered = LockedFlag()
        let materializer = fixture.materializer(postRenameFailure: {
            guard tampered.takeOnce() else { return nil }
            try? fixture.tamperMaterializedPayload()
            return nil
        })

        await expectFailure {
            _ = try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertTrue(tampered.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions/1.2.3").path
        ))
    }

    func testValidationWorkspaceExtraFileFailsSourceParity() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let injected = LockedFlag()
        let materializer = fixture.materializer(validationTreeObserver: { path in
            guard injected.takeOnce() else { return }
            try? fixture.injectValidationExtraFile(at: path)
        })

        await expectFailure {
            _ = try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertTrue(injected.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions/1.2.3").path
        ))
    }

    func testPostRenameFailureRemovesVersionAndFsyncsParent() async throws {
        let fixture = try MaterializerFixture()
        defer { fixture.cleanup() }
        let cleanupSynced = LockedFlag()
        let materializer = fixture.materializer(
            cleanupSyncObserver: { cleanupSynced.set() },
            postRenameFailure: { .copyFailed("forced post-rename failure") }
        )

        await expectFailure {
            _ = try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        XCTAssertTrue(cleanupSynced.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions/1.2.3").path
        ))
    }

    func testCancellationCleansStagingDirectory() async throws {
        let fixture = try MaterializerFixture(largePayload: true)
        defer { fixture.cleanup() }
        let reachedCopy = LockedFlag()
        let materializer = fixture.materializer(observer: { _ in
            reachedCopy.set()
            Thread.sleep(forTimeInterval: 0.1)
        })
        let task = Task {
            try await materializer.materialize(
                packageAt: fixture.packageSource,
                dataRoot: fixture.destinationDataRoot
            )
        }
        let deadline = Date().addingTimeInterval(4)
        while !reachedCopy.value && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled materialization unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destinationDataRoot.appendingPathComponent("service/versions").path
        )
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".candidate-") }))
    }

    private func expectFailure(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("operation unexpectedly succeeded", file: file, line: line)
        } catch {
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }

    func takeOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !storedValue else { return false }
        storedValue = true
        return true
    }
}

private struct MaterializerFixture {
    static let version = "1.2.3"
    static let executable = "parakeet-service"
    static let productIdentity = "Syrinx"
    static let packageIdentifier = "com.dpaluy.syrinx"
    static let serviceLabel = "com.dpaluy.syrinx"
    static let sourceCommit = String(repeating: "b", count: 40)
    static let tag = "v1.2.3"
    static let owner = "Sol Advisor"
    static let securityContact = "security@soladvisor.test"
    static let teamID = "ABCDE12345"
    static let applicationIdentity = "Developer ID Application: Sol Advisor (ABCDE12345)"
    static let installerIdentity = "Developer ID Installer: Sol Advisor (ABCDE12345)"
    static let manifestPath = "metadata/model-manifest.json"
    static let manifestData = Data("{\"model\":\"fixture\",\"revision\":1}\n".utf8)
    static let manifestDigest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
    static let bundleName = "SYRINX_SyrinxCore.bundle"
    static let bundleManifestName = "parakeet-tdt-0.6b-v3-int8.json"
    static let payloadFiles = [
        "metadata/release.json",
        "metadata/model-manifest.json",
        "metadata/model-manifest.sha256",
        "metadata/model-attribution.txt",
        "docs/COMPATIBILITY.md",
        "docs/SUPPORT.md",
        "docs/CHANGELOG.md",
        "licenses/LICENSE",
        "licenses/THIRD_PARTY_NOTICES.md",
        "payload/config.dat",
        "SYRINX_SyrinxCore.bundle/parakeet-tdt-0.6b-v3-int8.json",
        executable
    ]

    let root: URL
    let packageSource: URL
    let homebrewSource: URL
    let destinationDataRoot: URL
    let selectionURL: URL
    let targetURL: URL
    private let packageDirectoryName: String

    init(
        packageDirectoryName: String = version,
        wrongPackageParent: Bool = false,
        largePayload: Bool = false,
        precreateDestinationLayout: Bool = true
    ) throws {
        self.packageDirectoryName = packageDirectoryName
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t50c2a-fixture-\(UUID().uuidString)", isDirectory: true)
        let packageParent = root.appendingPathComponent(
            wrongPackageParent ? "not-a-package" : "package",
            isDirectory: true
        )
        packageSource = wrongPackageParent
            ? packageParent
                .appendingPathComponent(Self.productIdentity, isDirectory: true)
                .appendingPathComponent("versions", isDirectory: true)
                .appendingPathComponent(packageDirectoryName, isDirectory: true)
            : packageParent
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(Self.productIdentity, isDirectory: true)
                .appendingPathComponent("versions", isDirectory: true)
                .appendingPathComponent(packageDirectoryName, isDirectory: true)
        homebrewSource = root.appendingPathComponent("homebrew/libexec", isDirectory: true)
        destinationDataRoot = root.appendingPathComponent("destination", isDirectory: true)
        selectionURL = precreateDestinationLayout
            ? destinationDataRoot.appendingPathComponent("service/selection.json")
            : root.appendingPathComponent("selection-before.json")
        targetURL = packageSource.appendingPathComponent("payload/config.dat")

        try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homebrewSource, withIntermediateDirectories: true)
        for relative in [
            "metadata",
            "docs",
            "licenses",
            "payload",
            Self.bundleName
        ] {
            try FileManager.default.createDirectory(
                at: packageSource.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: destinationDataRoot, withIntermediateDirectories: true)
        if precreateDestinationLayout {
            try FileManager.default.createDirectory(
                at: destinationDataRoot.appendingPathComponent("service/versions", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("{\"activeVersion\":null}\n".utf8).write(to: selectionURL)
        chmod(selectionURL.path, mode_t(0o600))

        let metadata = try Self.metadata()
        let metadataURL = packageSource.appendingPathComponent("metadata/release.json")
        try metadata.encodedData().write(to: metadataURL)
        try Self.manifestData.write(to: packageSource.appendingPathComponent(Self.manifestPath))
        try Data((Self.manifestDigest + "  model-manifest.json\n").utf8).write(to: packageSource.appendingPathComponent("metadata/model-manifest.sha256"))
        try Data("fixture attribution\n".utf8).write(to: packageSource.appendingPathComponent("metadata/model-attribution.txt"))
        try Data("compatibility\n".utf8).write(to: packageSource.appendingPathComponent("docs/COMPATIBILITY.md"))
        try Data("support\n".utf8).write(to: packageSource.appendingPathComponent("docs/SUPPORT.md"))
        try Data("changelog\n".utf8).write(to: packageSource.appendingPathComponent("docs/CHANGELOG.md"))
        try Data("license\n".utf8).write(to: packageSource.appendingPathComponent("licenses/LICENSE"))
        try Data("notices\n".utf8).write(to: packageSource.appendingPathComponent("licenses/THIRD_PARTY_NOTICES.md"))
        try Data("config\n".utf8).write(to: targetURL)
        try Self.arm64MachO().write(to: packageSource.appendingPathComponent(Self.executable))
        try Self.manifestData.write(to: packageSource.appendingPathComponent("\(Self.bundleName)/\(Self.bundleManifestName)"))

        if largePayload {
            try Data(repeating: 0x44, count: 8 * 1024 * 1024).write(to: packageSource.appendingPathComponent("payload/large.bin"))
        }
        try clonePackagePayload(to: homebrewSource)
        sealTree(at: root)
        chmod(destinationDataRoot.path, mode_t(0o700))
        chmod(destinationDataRoot.appendingPathComponent("service").path, mode_t(0o700))
        chmod(destinationDataRoot.appendingPathComponent("service/versions").path, mode_t(0o700))
    }

    func materializer(
        observer: (@Sendable (Int) -> Void)? = nil,
        copyFailure: (@Sendable (Int) -> TrustedCandidateMaterializationError?)? = nil,
        directorySyncObserver: (@Sendable (String) -> Void)? = nil,
        stagingOpenObserver: (@Sendable (URL) -> Void)? = nil,
        cleanupSyncObserver: (@Sendable () -> Void)? = nil,
        postRenameFailure: (@Sendable () -> TrustedCandidateMaterializationError?)? = nil,
        validationTreeObserver: (@Sendable (URL) -> Void)? = nil
    ) -> TrustedCandidateMaterializer {
        TrustedCandidateMaterializer(
            requirements: Self.requirements(),
            signatureEvaluator: TrustedCandidateSignatureEvaluator { _, snapshot in
                TrustedCandidateSignatureEvidence(
                    verified: true,
                    applicationIdentity: Self.applicationIdentity,
                    teamID: Self.teamID,
                    hardenedRuntime: true,
                    timestamped: true,
                    notarized: true,
                    stapled: true,
                    gatekeeperAccepted: true,
                    executableDigest: snapshot.sha256,
                    buildProductIdentity: Self.productIdentity,
                    buildPackageIdentifier: Self.packageIdentifier,
                    buildVersion: Self.version,
                    buildSourceCommit: Self.sourceCommit,
                    buildTag: Self.tag
                )
            },
            copyObserver: observer,
            copyFailure: copyFailure,
            directorySyncObserver: directorySyncObserver,
            stagingOpenObserver: stagingOpenObserver,
            cleanupSyncObserver: cleanupSyncObserver,
            postRenameFailure: postRenameFailure,
            validationTreeObserver: validationTreeObserver
        )
    }

    func mode(of url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return Int(info.st_mode & 0o7777)
    }

    func replacePackageSourceWithSymlink() throws {
        let moved = packageSource.deletingLastPathComponent().appendingPathComponent("moved", isDirectory: true)
        chmod(packageSource.deletingLastPathComponent().path, mode_t(0o700))
        chmod(packageSource.path, mode_t(0o700))
        try FileManager.default.moveItem(at: packageSource, to: moved)
        try FileManager.default.createSymbolicLink(at: packageSource, withDestinationURL: moved)
    }

    func replacePackageAncestor() throws {
        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let moved = root.appendingPathComponent("package-replaced", isDirectory: true)
        chmod(packageRoot.path, mode_t(0o700))
        try FileManager.default.moveItem(at: packageRoot, to: moved)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
        chmod(packageRoot.path, mode_t(0o700))
    }

    func addHardLink() throws {
        chmod(packageSource.appendingPathComponent("payload").path, mode_t(0o700))
        chmod(packageSource.path, mode_t(0o700))
        try FileManager.default.linkItem(
            at: packageSource.appendingPathComponent("payload/config.dat"),
            to: packageSource.appendingPathComponent("payload/config-alias.dat")
        )
        chmod(packageSource.path, mode_t(0o500))
    }

    func addFIFO() throws {
        chmod(packageSource.appendingPathComponent("payload").path, mode_t(0o700))
        chmod(packageSource.path, mode_t(0o700))
        guard mkfifo(packageSource.appendingPathComponent("payload/fifo").path, mode_t(0o400)) == 0 else {
            throw POSIXError(.EIO)
        }
        chmod(packageSource.path, mode_t(0o500))
    }

    func replaceTargetBytes() throws {
        let parent = targetURL.deletingLastPathComponent()
        chmod(parent.path, mode_t(0o700))
        try FileManager.default.removeItem(at: targetURL)
        try Data("attacker replacement\n".utf8).write(to: targetURL)
        chmod(targetURL.path, mode_t(0o400))
        chmod(parent.path, mode_t(0o500))
    }

    func replaceDestinationVersionsWithSentinel() throws -> Bool {
        let service = destinationDataRoot.appendingPathComponent("service", isDirectory: true)
        let versions = service.appendingPathComponent("versions", isDirectory: true)
        let moved = service.appendingPathComponent("versions-replaced", isDirectory: true)
        guard let _ = try FileManager.default.contentsOfDirectory(
            at: versions,
            includingPropertiesForKeys: nil
        ).first(where: { $0.lastPathComponent.hasPrefix(".candidate-") }) else {
            return false
        }
        chmod(service.path, mode_t(0o700))
        chmod(versions.path, mode_t(0o700))
        try FileManager.default.moveItem(at: versions, to: moved)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: false)
        try Data("destination ancestor replacement\n".utf8)
            .write(to: versions.appendingPathComponent("ancestor-sentinel"))
        chmod(versions.path, mode_t(0o700))
        chmod(versions.appendingPathComponent("ancestor-sentinel").path, mode_t(0o600))
        return true
    }

    func destinationReplacementSentinelExists() throws -> Bool {
        FileManager.default.fileExists(
            atPath: destinationDataRoot
                .appendingPathComponent("service/versions/ancestor-sentinel")
                .path
        )
    }

    func tamperMaterializedPayload() throws {
        let payload = destinationDataRoot
            .appendingPathComponent("service/versions/1.2.3/payload/config.dat")
        guard chmod(payload.path, mode_t(0o600)) == 0 else { throw POSIXError(.EACCES) }
        try Data("post-rename inventory tamper\n".utf8).write(to: payload)
        guard chmod(payload.path, mode_t(0o444)) == 0 else { throw POSIXError(.EACCES) }
    }

    func injectValidationExtraFile(at versionDirectory: URL) throws {
        let payload = versionDirectory.appendingPathComponent("payload", isDirectory: true)
        let extra = payload.appendingPathComponent("validation-extra.dat")
        guard chmod(payload.path, mode_t(0o700)) == 0 else { throw POSIXError(.EACCES) }
        try Data("validation workspace injection\n".utf8).write(to: extra)
        guard chmod(extra.path, mode_t(0o444)) == 0,
              chmod(payload.path, mode_t(0o555)) == 0
        else { throw POSIXError(.EACCES) }
    }

    func makeGroupWorldWritable() throws {
        guard chmod(targetURL.path, mode_t(0o664)) == 0 else { throw POSIXError(.EACCES) }
    }

    func replaceCurrentStagingWithSentinel() throws -> Bool {
        let versions = destinationDataRoot.appendingPathComponent("service/versions", isDirectory: true)
        guard let staging = try FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix(".candidate-") })
        else { return false }
        let moved = versions.appendingPathComponent(".replaced-owned", isDirectory: true)
        try FileManager.default.moveItem(at: staging, to: moved)
        let replacement = versions.appendingPathComponent(staging.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("replacement survives\n".utf8).write(to: replacement.appendingPathComponent("sentinel"))
        chmod(replacement.path, mode_t(0o700))
        chmod(replacement.appendingPathComponent("sentinel").path, mode_t(0o600))
        return true
    }

    func replaceStagingBeforeOpen(path: URL) throws {
        let versions = destinationDataRoot.appendingPathComponent("service/versions", isDirectory: true)
        let moved = versions.appendingPathComponent(".replaced-before-open", isDirectory: true)
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("replacement survives create-open race\n".utf8)
            .write(to: path.appendingPathComponent("sentinel"))
        chmod(path.path, mode_t(0o700))
        chmod(path.appendingPathComponent("sentinel").path, mode_t(0o600))
    }

    func replacementSentinelExists() throws -> Bool {
        let versions = destinationDataRoot.appendingPathComponent("service/versions", isDirectory: true)
        guard let replacement = try FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix(".candidate-") })
        else { return false }
        return FileManager.default.fileExists(atPath: replacement.appendingPathComponent("sentinel").path)
    }

    func replaceDestinationServiceWithSymlink() throws {
        let service = destinationDataRoot.appendingPathComponent("service", isDirectory: true)
        let outside = root.appendingPathComponent("outside-service", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        chmod(destinationDataRoot.path, mode_t(0o700))
        try FileManager.default.removeItem(at: service)
        try FileManager.default.createSymbolicLink(at: service, withDestinationURL: outside)
    }

    func cleanup() {
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                chmod(url.path, mode_t(0o700))
            }
        }
        chmod(root.path, mode_t(0o700))
        try? FileManager.default.removeItem(at: root)
    }


    private func clonePackagePayload(to destination: URL) throws {
        for relative in Self.payloadFiles {
            let source = packageSource.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            if relative == "metadata/release.json" || relative == "metadata/model-manifest.json" || relative.contains("/"),
               relative.split(separator: "/").count > 1 {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data(contentsOf: source).write(to: target)
        }
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("payload", isDirectory: true), withIntermediateDirectories: true)
    }

    private func sealTree(at root: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            var isDirectory = ObjCBool(false)
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            chmod(url.path, mode_t(
                isDirectory.boolValue
                    ? 0o755
                    : (url.lastPathComponent == Self.executable ? 0o755 : 0o644)
            ))
        }
        chmod(root.path, mode_t(0o755))
    }

    static func requirements() -> TrustedCandidateRequirements {
        TrustedCandidateRequirements(
            productIdentity: productIdentity,
            executable: executable,
            packageIdentifier: packageIdentifier,
            serviceLabel: serviceLabel,
            version: version,
            sourceCommit: sourceCommit,
            tag: tag,
            applicationIdentity: applicationIdentity,
            teamID: teamID,
            architecture: "arm64",
            manifestPath: manifestPath,
            manifestDigest: manifestDigest,
            swiftResourceBundle: bundleName
        )
    }

    static func metadata() throws -> TrustedCandidateMetadata {
        let relativeRoot = "Library/Application Support/\(productIdentity)/versions/\(version)"
        return try TrustedCandidateMetadata(
            productIdentity: productIdentity,
            executable: executable,
            packageIdentifier: packageIdentifier,
            serviceLabel: serviceLabel,
            version: version,
            tag: tag,
            source: TrustedCandidateSource(commit: sourceCommit, annotatedTag: true),
            owner: owner,
            securityContact: securityContact,
            teamID: teamID,
            applicationIdentity: applicationIdentity,
            installerIdentity: installerIdentity,
            compatibility: TrustedCandidateCompatibility(minimumMacOS: "14.0", architecture: "arm64"),
            deliveryLayouts: TrustedCandidateDeliveryLayouts(
                package: TrustedCandidatePackageLayout(
                    payloadRoot: relativeRoot,
                    installLocation: "/",
                    installedRoot: "/\(relativeRoot)",
                    executable: "/\(relativeRoot)/\(executable)",
                    serviceLabel: serviceLabel
                ),
                homebrew: TrustedCandidateHomebrewLayout(
                    sourcePayloadRoot: relativeRoot,
                    libexecRoot: "libexec",
                    executable: "libexec/\(executable)",
                    binSymlink: "bin/\(executable)",
                    currentPointer: "not applicable; Homebrew uses the formula prefix",
                    serviceLabel: serviceLabel
                )
            ),
            t50cRuntime: TrustedCandidateRuntimeLayout(
                sourcePayloadRoot: relativeRoot,
                materialization: "T50C copies the immutable versioned payload into its per-user service version store",
                selection: "T50C lifecycle owns per-user version selection and rollback",
                dataRootRelativeVersionPath: "service/versions/{version}",
                selectionRecord: "service/selection.json",
                selectionRecordOwner: "T50C lifecycle",
                selectionField: "activeVersion"
            ),
            modelManifest: TrustedCandidateModelManifest(path: manifestPath, sha256: manifestDigest),
            swiftResourceBundle: bundleName,
            formulaClass: "Syrinx",
            buildTimestamp: "2026-08-15T00:00:00Z",
            unsignedDryRun: false
        )
    }

    static func arm64MachO() -> Data {
        Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] + Array(repeating: 0xaa, count: 256))
    }
}
