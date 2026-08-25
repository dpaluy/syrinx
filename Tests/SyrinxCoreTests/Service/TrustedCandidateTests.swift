import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class TrustedCandidateTests: XCTestCase {
    func testValidCandidateBindsRealT50BMetadataManifestArchitectureAndSignatureEvidence() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let candidate = try fixture.validate()

        XCTAssertEqual(candidate.metadata.schemaVersion, 1)
        XCTAssertEqual(candidate.metadata.version, CandidateFixture.version)
        XCTAssertEqual(candidate.metadata.executable, CandidateFixture.executable)
        XCTAssertEqual(candidate.metadata.productIdentity, CandidateFixture.productIdentity)
        XCTAssertEqual(candidate.metadata.packageIdentifier, CandidateFixture.packageIdentifier)
        XCTAssertEqual(candidate.metadata.serviceLabel, CandidateFixture.serviceLabel)
        XCTAssertEqual(candidate.metadata.source.commit, CandidateFixture.sourceCommit)
        XCTAssertTrue(candidate.metadata.source.annotatedTag)
        XCTAssertEqual(candidate.metadata.tag, CandidateFixture.tag)
        XCTAssertEqual(candidate.metadata.compatibility.architecture, "arm64")
        XCTAssertEqual(candidate.metadata.modelManifest.path, CandidateFixture.manifestPath)
        XCTAssertEqual(candidate.manifestDigest, CandidateFixture.manifestDigest)
        XCTAssertEqual(candidate.signatureEvidence.applicationIdentity, CandidateFixture.applicationIdentity)
        XCTAssertEqual(candidate.signatureEvidence.teamID, CandidateFixture.teamID)
        XCTAssertEqual(
            candidate.versionDirectory.standardizedFileURL,
            fixture.versionDirectory.standardizedFileURL
        )
        XCTAssertEqual(
            try ServiceVersionedLayout.versionDirectory(dataRoot: fixture.dataRoot, version: CandidateFixture.version)
                .standardizedFileURL,
            fixture.versionDirectory.standardizedFileURL
        )
        XCTAssertEqual(
            ServiceVersionedLayout.selectionFile(dataRoot: fixture.dataRoot),
            fixture.dataRoot.appendingPathComponent("service/selection.json")
        )
        XCTAssertEqual(
            fixture.servicePaths.candidateMetadata,
            fixture.versionDirectory
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent("release.json")
        )
        XCTAssertNoThrow(try candidate.lease.verifyStillValid())
    }

    func testMissingResourceBundleDeclarationFailsClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceMetadata { object in
            object["swiftResourceBundle"] = NSNull()
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testLegacySnakeCaseMetadataAndUnknownKeysFailClosed() throws {
        let legacy = Data("{\"schema_version\":1,\"version\":\"1.2.3\"}".utf8)
        XCTAssertThrowsError(try TrustedCandidateMetadata(data: legacy))

        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }
        try fixture.replaceMetadata { object in
            object["unexpected"] = true
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testPlaceholderAndMismatchedRealMetadataFailClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceMetadata { object in
            object["productIdentity"] = "Syrinx development placeholder"
        }
        XCTAssertThrowsError(try fixture.validate())

        try fixture.restoreMetadata()
        try fixture.replaceMetadata { object in
            object["source"] = ["commit": String(repeating: "c", count: 40), "annotatedTag": false]
        }
        XCTAssertThrowsError(try fixture.validate())

        try fixture.restoreMetadata()
        try fixture.replaceMetadata { object in
            object["teamId"] = "ZZZZZZZZZZ"
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testReleaseInputPatternsRejectNonASCIISpacesAndPlaceholderForms() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let invalidValues: [(String, Any)] = [
            ("productIdentity", "Parakeet Service"),
            ("productIdentity", "Parakéet"),
            ("productIdentity", "new-name"),
            ("executable", "x"),
            ("executable", "parakeet service"),
            ("executable", "éxecutable"),
            ("packageIdentifier", "com.example_service"),
            ("serviceLabel", "com.example service"),
            ("version", "v1.2.3"),
            ("tag", "v1.2.4"),
            ("teamId", "ABCDE1234é"),
            ("formulaClass", "parakeetService"),
            ("owner", "unresolved owner"),
            ("securityContact", "security@example.com"),
            ("securityContact", "security <contact>")
        ]
        for (key, value) in invalidValues {
            try fixture.replaceMetadata { object in object[key] = value }
            XCTAssertThrowsError(try fixture.validate(), key + "=" + String(describing: value))
            try fixture.restoreMetadata()
        }
    }

    func testReleaseInputPatternsRejectTrailingNewlines() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let invalidValues: [(String, Any)] = [
            ("productIdentity", "Parakeet\n"),
            ("executable", "parakeet-service\n"),
            ("packageIdentifier", "com.soladvisor.parakeet.service\n"),
            ("serviceLabel", "com.soladvisor.parakeet.service\n"),
            ("version", "1.2.3\n"),
            ("tag", "v1.2.3\n"),
            ("formulaClass", "SolAdvisorParakeetService\n")
        ]
        for (key, value) in invalidValues {
            try fixture.replaceMetadata { object in object[key] = value }
            XCTAssertThrowsError(try fixture.validate(), key + " must match the full string")
            try fixture.restoreMetadata()
        }
    }

    func testCertificateIdentityRequiresExactT50BFullString() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let invalidValues: [(String, Any)] = [
            ("applicationIdentity", "Developer ID Application: Sol Advisor(ABCDE12345)"),
            ("installerIdentity", "Developer ID Installer: Sol Advisor(ABCDE12345)"),
            ("applicationIdentity", "Developer ID Application: Sol Advisor (ABCDE12345)\n"),
            ("installerIdentity", "Developer ID Installer: Sol Advisor (ABCDE12345)\n"),
            ("applicationIdentity", "Developer ID Application: Sol Advisor (ABCDE12345) suffix"),
            ("installerIdentity", "Developer ID Installer: Sol Advisor (ABCDE12345) suffix")
        ]
        for (key, value) in invalidValues {
            try fixture.replaceMetadata { object in object[key] = value }
            XCTAssertThrowsError(try fixture.validate(), key + " must be exact")
            try fixture.restoreMetadata()
        }
    }

    func testUnsignedDryRunCandidatesAreNeverTrusted() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceMetadata { object in
            object["unsignedDryRun"] = true
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testUnsafeVersionExecutableAndManifestPathsFailClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        for unsafeVersion in ["../outside", "versions/1.2.3", "/absolute", "", ".", ".."] {
            XCTAssertThrowsError(
                try TrustedCandidateMetadata(
                    productIdentity: CandidateFixture.productIdentity,
                    executable: CandidateFixture.executable,
                    packageIdentifier: CandidateFixture.packageIdentifier,
                    serviceLabel: CandidateFixture.serviceLabel,
                    version: unsafeVersion,
                    tag: CandidateFixture.tag,
                    source: CandidateFixture.source,
                    owner: CandidateFixture.owner,
                    securityContact: CandidateFixture.securityContact,
                    teamID: CandidateFixture.teamID,
                    applicationIdentity: CandidateFixture.applicationIdentity,
                    installerIdentity: CandidateFixture.installerIdentity,
                    compatibility: CandidateFixture.compatibility,
                    deliveryLayouts: CandidateFixture.deliveryLayouts(version: unsafeVersion),
                    t50cRuntime: CandidateFixture.runtimeLayout(version: unsafeVersion),
                    modelManifest: CandidateFixture.modelManifest,
                    swiftResourceBundle: CandidateFixture.bundleName,
                    formulaClass: CandidateFixture.formulaClass,
                    buildTimestamp: CandidateFixture.buildTimestamp,
                    unsignedDryRun: false
                ),
                unsafeVersion
            )
        }

        try fixture.replaceMetadata { object in
            object["modelManifest"] = ["path": "../outside.json", "sha256": CandidateFixture.manifestDigest]
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testSignatureClaimsDoNotTrustMetadataWithoutMatchingInjectedEvidence() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try fixture.validate(evidence: .fixtureRejected))

        let candidate = try fixture.validate(evidence: .fixtureVerified)
        XCTAssertTrue(candidate.signatureEvidence.verified)
    }

    func testWrongApplicationTeamAndBuildIdentityEvidenceFailsClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let cases = [
            CandidateFixture.evidence(applicationIdentity: "Developer ID Application: Other (ABCDE12345)"),
            CandidateFixture.evidence(teamID: "ZZZZZZZZZZ"),
            CandidateFixture.evidence(buildSourceCommit: String(repeating: "c", count: 40)),
            CandidateFixture.evidence(buildVersion: "1.2.4"),
            CandidateFixture.evidence(executableDigest: String(repeating: "d", count: 64))
        ]
        for evidence in cases {
            XCTAssertThrowsError(try fixture.validate(evidence: evidence))
        }
    }

    func testNonArm64MachOHeaderFailsClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceExecutable(with: CandidateFixture.x86_64MachO())
        XCTAssertThrowsError(try fixture.validate())
    }

    func testExecutableReplacementDuringSignatureEvaluationFailsClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let evaluator = TrustedCandidateSignatureEvaluator { snapshotURL, snapshot in
            XCTAssertEqual(try Data(contentsOf: snapshotURL), fixture.executableData)
            XCTAssertEqual(snapshot.sha256, CandidateFixture.executableDigest)
            try fixture.replaceExecutableWithReplacement()
            return .fixtureVerified
        }
        XCTAssertThrowsError(try fixture.validate(evaluator: evaluator))
    }

    func testDirectoryTimestampMutationRestoredBeforeFinalAuthorityCheckFailsClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let evaluator = TrustedCandidateSignatureEvaluator { _, _ in
            fixture.withMutableCandidate {}
            return .fixtureVerified
        }
        XCTAssertThrowsError(try fixture.validate(evaluator: evaluator))
    }

    func testTrustedCandidateRetainsLeaseAndDetectsPostValidationChange() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let candidate = try fixture.validate()
        XCTAssertNoThrow(try candidate.lease.verifyStillValid())
        fixture.withMutableCandidate {}
        XCTAssertThrowsError(try candidate.lease.verifyStillValid())
    }

    func testLeaseRejectsMetadataManifestAndNestedResourceMutation() throws {
        let metadataFixture = try CandidateFixture()
        defer { metadataFixture.cleanup() }
        let metadataCandidate = try metadataFixture.validate()
        try metadataFixture.replaceMetadata { object in object["buildTimestamp"] = "2026-08-15T00:00:01Z" }
        XCTAssertThrowsError(try metadataCandidate.lease.verifyStillValid())

        let manifestFixture = try CandidateFixture()
        defer { manifestFixture.cleanup() }
        let manifestCandidate = try manifestFixture.validate()
        try manifestFixture.replaceManifest(with: Data("mutated manifest".utf8))
        XCTAssertThrowsError(try manifestCandidate.lease.verifyStillValid())

        let bundleFixture = try CandidateFixture()
        defer { bundleFixture.cleanup() }
        let bundleCandidate = try bundleFixture.validate()
        try bundleFixture.replaceBundleManifest(with: Data("mutated bundle manifest".utf8))
        XCTAssertThrowsError(try bundleCandidate.lease.verifyStillValid())
    }

    func testLeaseRejectsSameSizeTimestampRestoredManifestMutation() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let candidate = try fixture.validate()
        try fixture.mutateManifestInPlaceRestoringTimestamps()
        XCTAssertThrowsError(try candidate.lease.verifyStillValid())
    }

    func testLeaseRejectsMetadataReplaceAndRestoreABA() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        let candidate = try fixture.validate()
        try fixture.replaceMetadata { object in object["buildTimestamp"] = "2026-08-15T00:00:01Z" }
        try fixture.restoreMetadata()
        XCTAssertThrowsError(try candidate.lease.verifyStillValid())
    }

    func testOwnerWritableCandidatePayloadFailsClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        _ = fixture.withMutableCandidate {
            chmod(fixture.bundleManifestURL.path, mode_t(0o600))
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testResourceBundleMustMatchTrustedRequirement() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceMetadata { object in object["swiftResourceBundle"] = "Other.bundle" }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testResourceBundleRejectsWrongInitialManifestContent() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceBundleManifest(with: Data("wrong initial content".utf8))
        XCTAssertThrowsError(try fixture.validate())
    }

    func testResourceBundleRejectsWrongManifestFilename() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceBundleManifestFilename(with: "wrong-manifest.json")
        XCTAssertThrowsError(try fixture.validate())
    }

    func testResourceBundleRejectsMissingManifestFile() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.removeBundleManifest()
        XCTAssertThrowsError(try fixture.validate())
    }

    func testResourceBundleRejectsExtraFile() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.addExtraBundleFile()
        XCTAssertThrowsError(try fixture.validate())
    }

    func testFIFOMetadataIsRejectedBeforeBlocking() throws {
        try assertValidationRejectsBeforeDeadline(target: "metadata", label: "metadata FIFO")
    }

    func testFIFOExecutableIsRejectedBeforeBlocking() throws {
        try assertValidationRejectsBeforeDeadline(target: "executable", label: "executable FIFO")
    }

    func testFIFOManifestIsRejectedBeforeBlocking() throws {
        try assertValidationRejectsBeforeDeadline(target: "manifest", label: "manifest FIFO")
    }

    func testFIFONestedResourceIsRejectedBeforeBlocking() throws {
        try assertValidationRejectsBeforeDeadline(target: "nested-resource", label: "nested resource FIFO")
    }

    func testTreeEnumerationRejectsOverLimitDirectoryWithoutUnboundedCollection() throws {
        try assertValidationRejectsBeforeDeadline(
            target: "over-limit",
            label: "over-limit candidate tree",
            timeout: 10.0
        )
    }

    func testArchitectureAcceptsArm64MachOHeaderWithTrailingBytes() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        XCTAssertEqual(try TrustedCandidateArchitecture.detect(at: fixture.executableURL), "arm64")
        XCTAssertGreaterThan(fixture.executableData.count, 8)
    }

    func testManifestDigestBindsTheActualPinnedBytes() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.replaceManifest(with: Data("mutated manifest".utf8))
        XCTAssertThrowsError(try fixture.validate())

        try fixture.restoreManifest()
        let candidate = try fixture.validate()
        XCTAssertEqual(candidate.manifestDigest, CandidateFixture.manifestDigest)
    }

    func testManifestSymlinkFailsClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.withMutableCandidate {
            try FileManager.default.removeItem(at: fixture.manifestURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.manifestURL,
                withDestinationURL: fixture.outsideManifestURL
            )
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testServiceAndVersionsAncestorsRejectSymlinkEscapes() throws {
        let serviceFixture = try CandidateFixture()
        defer { serviceFixture.cleanup() }
        try serviceFixture.replaceServiceWithSymlink()
        XCTAssertThrowsError(try serviceFixture.validate())

        let versionsFixture = try CandidateFixture()
        defer { versionsFixture.cleanup() }
        try versionsFixture.replaceVersionsWithSymlink()
        XCTAssertThrowsError(try versionsFixture.validate())

        let dataFixture = try CandidateFixture()
        defer { dataFixture.cleanup() }
        try dataFixture.replaceDataRootWithSymlink()
        XCTAssertThrowsError(try dataFixture.validate())

        let parentFixture = try CandidateFixture()
        defer { parentFixture.cleanup() }
        try parentFixture.replaceDataRootParentWithSymlink()
        XCTAssertThrowsError(try parentFixture.validate())

        let versionFixture = try CandidateFixture()
        defer { versionFixture.cleanup() }
        try versionFixture.replaceVersionWithSymlink()
        XCTAssertThrowsError(try versionFixture.validate())

        let metadataFixture = try CandidateFixture()
        defer { metadataFixture.cleanup() }
        try metadataFixture.replaceMetadataParentWithSymlink()
        XCTAssertThrowsError(try metadataFixture.validate())
    }

    func testHardLinkAndWritableExecutableFailClosed() throws {
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }

        try fixture.withMutableCandidate {
            try FileManager.default.removeItem(at: fixture.executableURL)
            XCTAssertEqual(link(fixture.targetURL.path, fixture.executableURL.path), 0)
        }
        XCTAssertThrowsError(try fixture.validate())

        try fixture.restoreExecutable()
        chmod(fixture.executableURL.path, mode_t(0o775))
        XCTAssertThrowsError(try fixture.validate())
    }

    func testIdentityDigestIsDeterministicAndBindsMetadataChanges() throws {
        let first = try CandidateFixture.metadata()
        let second = try CandidateFixture.metadata()
        XCTAssertEqual(try first.identityDigest(), try second.identityDigest())

        let changed = try TrustedCandidateMetadata(
            productIdentity: CandidateFixture.productIdentity,
            executable: CandidateFixture.executable,
            packageIdentifier: CandidateFixture.packageIdentifier,
            serviceLabel: CandidateFixture.serviceLabel,
            version: "1.2.4",
            tag: "v1.2.4",
            source: CandidateFixture.source,
            owner: CandidateFixture.owner,
            securityContact: CandidateFixture.securityContact,
            teamID: CandidateFixture.teamID,
            applicationIdentity: CandidateFixture.applicationIdentity,
            installerIdentity: CandidateFixture.installerIdentity,
            compatibility: CandidateFixture.compatibility,
            deliveryLayouts: CandidateFixture.deliveryLayouts(version: "1.2.4"),
            t50cRuntime: CandidateFixture.runtimeLayout(version: "1.2.4"),
            modelManifest: CandidateFixture.modelManifest,
            swiftResourceBundle: CandidateFixture.bundleName,
            formulaClass: CandidateFixture.formulaClass,
            buildTimestamp: CandidateFixture.buildTimestamp,
            unsignedDryRun: false
        )
        XCTAssertNotEqual(try first.identityDigest(), try changed.identityDigest())
        XCTAssertEqual(try first.encodedData(), try first.encodedData())
    }

    func testChildValidationRejectsConfiguredAttack() throws {
        guard let target = ProcessInfo.processInfo.environment["TRUSTED_CANDIDATE_CHILD_ATTACK"] else {
            return
        }
        let fixture = try CandidateFixture()
        defer { fixture.cleanup() }
        switch target {
        case "metadata":
            try fixture.replaceWithFIFO(at: fixture.metadataURL)
        case "executable":
            try fixture.replaceWithFIFO(at: fixture.executableURL)
        case "manifest":
            try fixture.replaceWithFIFO(at: fixture.manifestURL)
        case "nested-resource":
            try fixture.replaceWithFIFO(at: fixture.bundleManifestURL)
        case "over-limit":
            try fixture.addOverflowFiles(count: 4_200)
            XCTAssertGreaterThan(
                try FileManager.default.contentsOfDirectory(at: fixture.versionDirectory, includingPropertiesForKeys: nil).count,
                4_096
            )
        default:
            throw CandidateFixtureError.systemCall("unknown child attack")
        }
        XCTAssertThrowsError(try fixture.validate())
    }

    private func assertValidationRejectsBeforeDeadline(
        target: String,
        label: String,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        process.arguments = [
            "-XCTest",
            "SyrinxCoreTests.TrustedCandidateTests/testChildValidationRejectsConfiguredAttack",
            Bundle(for: TrustedCandidateTests.self).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TRUSTED_CANDIDATE_CHILD_ATTACK"] = target
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard !process.isRunning else {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("\(label) did not fail closed before deadline", file: file, line: line)
            return
        }
        XCTAssertEqual(process.terminationStatus, 0, "\(label) unexpectedly validated", file: file, line: line)
    }
}

private struct CandidateFixture {
    static let version = "1.2.3"
    static let executable = "parakeet-service"
    static let productIdentity = "Parakeet"
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
    static let bundleManifestData = Data("{\"model\":\"fixture\",\"revision\":1}\n".utf8)
    static let formulaClass = "Syrinx"
    static let buildTimestamp = "2026-08-15T00:00:00Z"
    static let compatibility = TrustedCandidateCompatibility(minimumMacOS: "14.0", architecture: "arm64")
    static let source = TrustedCandidateSource(commit: sourceCommit, annotatedTag: true)
    static let modelManifest = TrustedCandidateModelManifest(path: manifestPath, sha256: manifestDigest)
    static let executableDigest = SHA256.hash(data: arm64MachO()).map { String(format: "%02x", $0) }.joined()

    let root: URL
    let dataRoot: URL
    let versionDirectory: URL
    let metadataURL: URL
    let manifestURL: URL
    let bundleDirectory: URL
    let bundleManifestURL: URL
    let outsideManifestURL: URL
    let executableURL: URL
    let targetURL: URL
    let servicePaths: ServicePaths
    let executableData: Data
    private let metadataData: Data

    init() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let physicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private" + temporaryPath
            : temporaryPath
        root = URL(fileURLWithPath: physicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("trusted-candidate-\(UUID().uuidString)", isDirectory: true)
        dataRoot = root.appendingPathComponent("data", isDirectory: true)
        versionDirectory = try ServiceVersionedLayout.versionDirectory(dataRoot: dataRoot, version: Self.version)
        metadataURL = versionDirectory
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("release.json")
        manifestURL = versionDirectory
            .appendingPathComponent(Self.manifestPath)
        bundleDirectory = versionDirectory.appendingPathComponent(Self.bundleName, isDirectory: true)
        bundleManifestURL = bundleDirectory.appendingPathComponent(Self.bundleManifestName)
        outsideManifestURL = root.appendingPathComponent("outside-manifest.json")
        executableURL = versionDirectory.appendingPathComponent(Self.executable)
        targetURL = versionDirectory.appendingPathComponent("target.bin")
        servicePaths = ServicePaths(
            paths: StandardPaths(
                data: dataRoot,
                cache: root.appendingPathComponent("cache"),
                logs: root.appendingPathComponent("logs")
            ),
            homeDirectory: root.path,
            executableURL: executableURL,
            version: Self.version
        )
        executableData = Self.arm64MachO()
        metadataData = try Self.metadata().encodedData()

        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: false
        )
        try metadataData.write(to: metadataURL, options: .atomic)
        chmod(metadataURL.path, mode_t(0o400))
        try Self.manifestData.write(to: manifestURL, options: .atomic)
        chmod(manifestURL.path, mode_t(0o400))
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: false)
        try Self.bundleManifestData.write(to: bundleManifestURL, options: .atomic)
        chmod(bundleManifestURL.path, mode_t(0o400))
        try executableData.write(to: executableURL, options: .atomic)
        chmod(executableURL.path, mode_t(0o500))
        try Data("fixture target".utf8).write(to: targetURL)
        chmod(targetURL.path, mode_t(0o400))
        try Data("outside".utf8).write(to: outsideManifestURL)
        chmod(outsideManifestURL.path, mode_t(0o600))
        for directory in [
            dataRoot,
            dataRoot.appendingPathComponent("service"),
            dataRoot.appendingPathComponent("service/versions"),
            versionDirectory,
            metadataURL.deletingLastPathComponent(),
            bundleDirectory
        ] {
            chmod(directory.path, mode_t(
                directory == versionDirectory ||
                directory == metadataURL.deletingLastPathComponent() ||
                directory == bundleDirectory ? 0o500 : 0o700
            ))
        }
    }

    static func metadata() throws -> TrustedCandidateMetadata {
        try TrustedCandidateMetadata(
            productIdentity: productIdentity,
            executable: executable,
            packageIdentifier: packageIdentifier,
            serviceLabel: serviceLabel,
            version: version,
            tag: tag,
            source: source,
            owner: owner,
            securityContact: securityContact,
            teamID: teamID,
            applicationIdentity: applicationIdentity,
            installerIdentity: installerIdentity,
            compatibility: compatibility,
            deliveryLayouts: deliveryLayouts(version: version),
            t50cRuntime: runtimeLayout(version: version),
            modelManifest: modelManifest,
            swiftResourceBundle: bundleName,
            formulaClass: formulaClass,
            buildTimestamp: buildTimestamp,
            unsignedDryRun: false
        )
    }

    static func deliveryLayouts(version: String) -> TrustedCandidateDeliveryLayouts {
        let relativeRoot = "Library/Application Support/\(productIdentity)/versions/\(version)"
        let installedRoot = "/\(relativeRoot)"
        return TrustedCandidateDeliveryLayouts(
            package: TrustedCandidatePackageLayout(
                payloadRoot: relativeRoot,
                installLocation: "/",
                installedRoot: installedRoot,
                executable: installedRoot + "/" + executable,
                serviceLabel: serviceLabel
            ),
            homebrew: TrustedCandidateHomebrewLayout(
                sourcePayloadRoot: relativeRoot,
                libexecRoot: "libexec",
                executable: "libexec/" + executable,
                binSymlink: "bin/" + executable,
                currentPointer: "not applicable; Homebrew uses the formula prefix",
                serviceLabel: serviceLabel
            )
        )
    }

    static func runtimeLayout(version: String) -> TrustedCandidateRuntimeLayout {
        let relativeRoot = "Library/Application Support/\(productIdentity)/versions/\(version)"
        return TrustedCandidateRuntimeLayout(
            sourcePayloadRoot: relativeRoot,
            materialization: "T50C copies the immutable versioned payload into its per-user service version store",
            selection: "T50C lifecycle owns per-user version selection and rollback",
            dataRootRelativeVersionPath: "service/versions/{version}",
            selectionRecord: "service/selection.json",
            selectionRecordOwner: "T50C lifecycle",
            selectionField: "activeVersion"
        )
    }

    func validate(
        evidence: TrustedCandidateSignatureEvidence = .fixtureVerified
    ) throws -> TrustedVersionedCandidate {
        try validate(evaluator: TrustedCandidateSignatureEvaluator { _, _ in evidence })
    }

    func validate(evaluator: TrustedCandidateSignatureEvaluator) throws -> TrustedVersionedCandidate {
        try TrustedCandidateValidator(
            requirements: TrustedCandidateRequirements(
                productIdentity: Self.productIdentity,
                executable: Self.executable,
                packageIdentifier: Self.packageIdentifier,
                serviceLabel: Self.serviceLabel,
                version: Self.version,
                sourceCommit: Self.sourceCommit,
                tag: Self.tag,
                applicationIdentity: Self.applicationIdentity,
                teamID: Self.teamID,
                architecture: "arm64",
                manifestPath: Self.manifestPath,
                manifestDigest: Self.manifestDigest,
                swiftResourceBundle: Self.bundleName
            ),
            signatureEvaluator: evaluator
        ).validate(dataRoot: dataRoot, version: Self.version)
    }

    static func evidence(
        verified: Bool = true,
        applicationIdentity: String = CandidateFixture.applicationIdentity,
        teamID: String = CandidateFixture.teamID,
        executableDigest: String = CandidateFixture.executableDigest,
        buildProductIdentity: String = CandidateFixture.productIdentity,
        buildPackageIdentifier: String = CandidateFixture.packageIdentifier,
        buildVersion: String = CandidateFixture.version,
        buildSourceCommit: String = CandidateFixture.sourceCommit,
        buildTag: String = CandidateFixture.tag
    ) -> TrustedCandidateSignatureEvidence {
        TrustedCandidateSignatureEvidence(
            verified: verified,
            applicationIdentity: applicationIdentity,
            teamID: teamID,
            hardenedRuntime: verified,
            timestamped: verified,
            notarized: verified,
            stapled: verified,
            gatekeeperAccepted: verified,
            executableDigest: executableDigest,
            buildProductIdentity: buildProductIdentity,
            buildPackageIdentifier: buildPackageIdentifier,
            buildVersion: buildVersion,
            buildSourceCommit: buildSourceCommit,
            buildTag: buildTag
        )
    }

    func replaceMetadata(_ mutate: (inout [String: Any]) throws -> Void) throws {
        try withMutableCandidate {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
            try mutate(&object)
            try JSONSerialization.data(withJSONObject: object, options: []).write(to: metadataURL, options: .atomic)
            chmod(metadataURL.path, mode_t(0o400))
        }
    }

    func restoreMetadata() throws {
        try withMutableCandidate {
            try metadataData.write(to: metadataURL, options: .atomic)
            chmod(metadataURL.path, mode_t(0o400))
        }
    }

    func replaceManifest(with data: Data) throws {
        try withMutableCandidate {
            try data.write(to: manifestURL, options: .atomic)
            chmod(manifestURL.path, mode_t(0o400))
        }
    }

    func restoreManifest() throws {
        try withMutableCandidate {
            try Self.manifestData.write(to: manifestURL, options: .atomic)
            chmod(manifestURL.path, mode_t(0o400))
        }
    }

    func replaceBundleManifest(with data: Data) throws {
        try withMutableCandidate {
            try data.write(to: bundleManifestURL, options: .atomic)
            chmod(bundleManifestURL.path, mode_t(0o400))
        }
    }

    func replaceBundleManifestFilename(with name: String) throws {
        try withMutableCandidate {
            try FileManager.default.removeItem(at: bundleManifestURL)
            let replacement = bundleDirectory.appendingPathComponent(name)
            try Data("wrong manifest filename".utf8).write(to: replacement, options: .atomic)
            chmod(replacement.path, mode_t(0o400))
        }
    }

    func removeBundleManifest() throws {
        try withMutableCandidate {
            try FileManager.default.removeItem(at: bundleManifestURL)
        }
    }

    func addExtraBundleFile() throws {
        try withMutableCandidate {
            let extra = bundleDirectory.appendingPathComponent("extra.json")
            try Data("extra bundle file".utf8).write(to: extra, options: .atomic)
            chmod(extra.path, mode_t(0o400))
        }
    }

    func replaceWithFIFO(at url: URL) throws {
        try withMutableCandidate {
            try? FileManager.default.removeItem(at: url)
            guard mkfifo(url.path, mode_t(0o400)) == 0 else {
                throw CandidateFixtureError.systemCall("mkfifo (url.lastPathComponent)")
            }
        }
    }

    func addOverflowFiles(count: Int) throws {
        try withMutableCandidate {
            for index in 0..<count {
                let file = versionDirectory.appendingPathComponent("overflow-\(index)")
                guard FileManager.default.createFile(atPath: file.path, contents: Data([UInt8(index & 0xff)])) else {
                    throw CandidateFixtureError.systemCall("create overflow file")
                }
                guard chmod(file.path, mode_t(0o400)) == 0 else {
                    throw CandidateFixtureError.systemCall("chmod overflow file")
                }
            }
        }
    }

    func mutateManifestInPlaceRestoringTimestamps() throws {
        guard chmod(manifestURL.path, mode_t(0o600)) == 0 else {
            throw CandidateFixtureError.systemCall("chmod manifest")
        }
        defer { chmod(manifestURL.path, mode_t(0o400)) }
        let descriptor = open(manifestURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CandidateFixtureError.systemCall("open manifest") }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw CandidateFixtureError.systemCall("fstat manifest")
        }
        var byte: UInt8 = 0
        guard pread(descriptor, &byte, 1, 0) == 1 else {
            throw CandidateFixtureError.systemCall("read manifest")
        }
        byte ^= 0x01
        guard pwrite(descriptor, &byte, 1, 0) == 1 else {
            throw CandidateFixtureError.systemCall("write manifest")
        }
        var timestamps = [before.st_atimespec, before.st_mtimespec]
        guard timestamps.withUnsafeMutableBufferPointer({ futimens(descriptor, $0.baseAddress) }) == 0 else {
            throw CandidateFixtureError.systemCall("restore manifest timestamps")
        }
    }

    func restoreExecutable() throws {
        try withMutableCandidate {
            try? FileManager.default.removeItem(at: executableURL)
            try executableData.write(to: executableURL, options: .atomic)
            chmod(executableURL.path, mode_t(0o500))
        }
    }

    func replaceExecutable(with data: Data) throws {
        try withMutableCandidate {
            try? FileManager.default.removeItem(at: executableURL)
            try data.write(to: executableURL, options: .atomic)
            chmod(executableURL.path, mode_t(0o500))
        }
    }

    func replaceExecutableWithReplacement() throws {
        try replaceExecutable(with: Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] + Array(repeating: 0xbb, count: 256)))
    }

    func replaceServiceWithSymlink() throws {
        let service = dataRoot.appendingPathComponent("service")
        let outside = root.appendingPathComponent("outside-service")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("versions"), withIntermediateDirectories: true)
        makeAllFixtureDirectoriesMutable()
        try FileManager.default.removeItem(at: service)
        try FileManager.default.createSymbolicLink(at: service, withDestinationURL: outside)
    }

    func replaceVersionsWithSymlink() throws {
        let versions = dataRoot.appendingPathComponent("service/versions")
        let outside = root.appendingPathComponent("outside-versions")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        makeAllFixtureDirectoriesMutable()
        try FileManager.default.removeItem(at: versions)
        try FileManager.default.createSymbolicLink(at: versions, withDestinationURL: outside)
    }

    func replaceDataRootWithSymlink() throws {
        let outside = root.appendingPathComponent("outside-data")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        makeAllFixtureDirectoriesMutable()
        try FileManager.default.removeItem(at: dataRoot)
        try FileManager.default.createSymbolicLink(at: dataRoot, withDestinationURL: outside)
    }

    func replaceDataRootParentWithSymlink() throws {
        let relocated = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".relocated", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: relocated)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: relocated)
    }

    func replaceVersionWithSymlink() throws {
        let outside = root.appendingPathComponent("outside-version")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        makeAllFixtureDirectoriesMutable()
        try FileManager.default.removeItem(at: versionDirectory)
        try FileManager.default.createSymbolicLink(at: versionDirectory, withDestinationURL: outside)
    }

    func replaceMetadataParentWithSymlink() throws {
        let metadataDirectory = metadataURL.deletingLastPathComponent()
        let outside = root.appendingPathComponent("outside-metadata")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try withMutableCandidate {
            try FileManager.default.removeItem(at: metadataDirectory)
            try FileManager.default.createSymbolicLink(at: metadataDirectory, withDestinationURL: outside)
        }
    }

    func withMutableCandidate<T>(_ body: () throws -> T) rethrows -> T {
        chmod(versionDirectory.path, mode_t(0o700))
        chmod(metadataURL.deletingLastPathComponent().path, mode_t(0o700))
        chmod(bundleDirectory.path, mode_t(0o700))
        defer {
            var versionInfo = stat()
            if lstat(versionDirectory.path, &versionInfo) == 0,
               (versionInfo.st_mode & S_IFMT) == S_IFDIR {
                chmod(versionDirectory.path, mode_t(0o500))
            }
            var metadataInfo = stat()
            if lstat(metadataURL.deletingLastPathComponent().path, &metadataInfo) == 0,
               (metadataInfo.st_mode & S_IFMT) == S_IFDIR {
                chmod(metadataURL.deletingLastPathComponent().path, mode_t(0o500))
            }
            var bundleInfo = stat()
            if lstat(bundleDirectory.path, &bundleInfo) == 0,
               (bundleInfo.st_mode & S_IFMT) == S_IFDIR {
                chmod(bundleDirectory.path, mode_t(0o500))
            }
        }
        return try body()
    }

    private func makeAllFixtureDirectoriesMutable() {
        for directory in [
            metadataURL.deletingLastPathComponent(),
            bundleDirectory,
            versionDirectory,
            dataRoot.appendingPathComponent("service/versions"),
            dataRoot.appendingPathComponent("service"),
            dataRoot
        ] {
            var info = stat()
            if lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                chmod(directory.path, mode_t(0o700))
            }
        }
    }

    func cleanup() {
        for directory in [
            metadataURL.deletingLastPathComponent(),
            bundleDirectory,
            versionDirectory,
            dataRoot.appendingPathComponent("service/versions"),
            dataRoot.appendingPathComponent("service"),
            dataRoot
        ] {
            var info = stat()
            if lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                chmod(directory.path, mode_t(0o700))
            }
        }
        try? FileManager.default.removeItem(at: root)
        let relocated = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".relocated", isDirectory: true)
        try? FileManager.default.removeItem(at: relocated)
    }

    static func arm64MachO() -> Data {
        Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] + Array(repeating: 0xaa, count: 256))
    }

    static func x86_64MachO() -> Data {
        Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01] + Array(repeating: 0xaa, count: 256))
    }
}

private enum CandidateFixtureError: Error {
    case systemCall(String)
}

private extension TrustedCandidateSignatureEvidence {
    static let fixtureVerified = CandidateFixture.evidence()
    static let fixtureRejected = CandidateFixture.evidence(verified: false)
}
