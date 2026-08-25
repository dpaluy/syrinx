import CryptoKit
import Darwin
import Foundation

private let expectedSwiftResourceBundleName = "SYRINX_SyrinxCore.bundle"
private let expectedSwiftResourceManifestName = "parakeet-tdt-0.6b-v3-int8.json"

private func isStableAbsolutePath(_ url: URL) -> Bool {
    let path = url.path
    let standardized = url.standardizedFileURL.path
    if path == standardized {
        return true
    }
    if path == "/private/var" || path.hasPrefix("/private/var/") {
        return standardized == "/var" || standardized.hasPrefix("/var/")
    }
    if path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
        return standardized == "/tmp" || standardized.hasPrefix("/tmp/")
    }
    return false
}

public enum TrustedCandidateError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidMetadata
    case invalidField(String)
    case metadataMismatch(String)
    case unsafePath(String)
    case missingFile(String)
    case symbolicLink(String)
    case hardLink(String)
    case unsafeFileType(String)
    case unsafePermissions(String)
    case architectureMismatch
    case signatureUnverified
    case digestMismatch

    public var description: String {
        switch self {
        case .invalidMetadata:
            return "candidate metadata is invalid"
        case let .invalidField(field):
            return "candidate metadata field is invalid: \(field)"
        case let .metadataMismatch(field):
            return "candidate metadata does not match the release requirement: \(field)"
        case let .unsafePath(path):
            return "candidate path is unsafe: \(path)"
        case let .missingFile(name):
            return "candidate file is missing: \(name)"
        case let .symbolicLink(path):
            return "candidate contains a symbolic link: \(path)"
        case let .hardLink(path):
            return "candidate contains a hard link: \(path)"
        case let .unsafeFileType(path):
            return "candidate contains an unsafe file type: \(path)"
        case let .unsafePermissions(path):
            return "candidate permissions are unsafe: \(path)"
        case .architectureMismatch:
            return "candidate architecture is not arm64"
        case .signatureUnverified:
            return "candidate signature evidence is not verified"
        case .digestMismatch:
            return "candidate model manifest digest does not match"
        }
    }
}

public enum ServiceVersionedLayout {
    public static let serviceDirectoryName = "service"
    public static let versionsDirectoryName = "versions"
    public static let selectionFileName = "selection.json"
    public static let candidateMetadataDirectoryName = "metadata"
    public static let candidateMetadataFileName = "release.json"

    public static func versionDirectory(dataRoot: URL, version: String) throws -> URL {
        guard dataRoot.isFileURL,
              dataRoot.path.hasPrefix("/"),
              isStableAbsolutePath(dataRoot),
              isSafeVersion(version)
        else {
            throw TrustedCandidateError.unsafePath("versioned data root")
        }

        let serviceRoot = dataRoot.appendingPathComponent(serviceDirectoryName, isDirectory: true)
        let versionsRoot = serviceRoot.appendingPathComponent(versionsDirectoryName, isDirectory: true)
        let result = versionsRoot.appendingPathComponent(version, isDirectory: true).standardizedFileURL
        guard result.path.hasPrefix(versionsRoot.standardizedFileURL.path + "/") else {
            throw TrustedCandidateError.unsafePath("version")
        }
        return result
    }

    public static func selectionFile(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent(serviceDirectoryName, isDirectory: true)
            .appendingPathComponent(selectionFileName, isDirectory: false)
            .standardizedFileURL
    }

    public static func candidateMetadata(versionDirectory: URL) -> URL {
        versionDirectory
            .appendingPathComponent(candidateMetadataDirectoryName, isDirectory: true)
            .appendingPathComponent(candidateMetadataFileName, isDirectory: false)
    }

    static func isSafeVersion(_ version: String) -> Bool {
        !version.isEmpty &&
            version != "." &&
            version != ".." &&
            !version.contains("/") &&
            !version.contains("\\") &&
            !version.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }
}

public struct TrustedCandidateSource: Codable, Equatable, Sendable {
    public let commit: String
    public let annotatedTag: Bool

    public init(commit: String, annotatedTag: Bool) {
        self.commit = commit
        self.annotatedTag = annotatedTag
    }
}

public struct TrustedCandidateCompatibility: Codable, Equatable, Sendable {
    public let minimumMacOS: String
    public let architecture: String

    public init(minimumMacOS: String, architecture: String) {
        self.minimumMacOS = minimumMacOS
        self.architecture = architecture
    }
}

public struct TrustedCandidateModelManifest: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct TrustedCandidatePackageLayout: Codable, Equatable, Sendable {
    public let payloadRoot: String
    public let installLocation: String
    public let installedRoot: String
    public let executable: String
    public let serviceLabel: String

    public init(
        payloadRoot: String,
        installLocation: String,
        installedRoot: String,
        executable: String,
        serviceLabel: String
    ) {
        self.payloadRoot = payloadRoot
        self.installLocation = installLocation
        self.installedRoot = installedRoot
        self.executable = executable
        self.serviceLabel = serviceLabel
    }
}

public struct TrustedCandidateHomebrewLayout: Codable, Equatable, Sendable {
    public let sourcePayloadRoot: String
    public let libexecRoot: String
    public let executable: String
    public let binSymlink: String
    public let currentPointer: String
    public let serviceLabel: String

    public init(
        sourcePayloadRoot: String,
        libexecRoot: String,
        executable: String,
        binSymlink: String,
        currentPointer: String,
        serviceLabel: String
    ) {
        self.sourcePayloadRoot = sourcePayloadRoot
        self.libexecRoot = libexecRoot
        self.executable = executable
        self.binSymlink = binSymlink
        self.currentPointer = currentPointer
        self.serviceLabel = serviceLabel
    }
}

public struct TrustedCandidateDeliveryLayouts: Codable, Equatable, Sendable {
    public let package: TrustedCandidatePackageLayout
    public let homebrew: TrustedCandidateHomebrewLayout

    public init(package: TrustedCandidatePackageLayout, homebrew: TrustedCandidateHomebrewLayout) {
        self.package = package
        self.homebrew = homebrew
    }
}

public struct TrustedCandidateRuntimeLayout: Codable, Equatable, Sendable {
    public let sourcePayloadRoot: String
    public let materialization: String
    public let selection: String
    public let dataRootRelativeVersionPath: String
    public let selectionRecord: String
    public let selectionRecordOwner: String
    public let selectionField: String

    public init(
        sourcePayloadRoot: String,
        materialization: String,
        selection: String,
        dataRootRelativeVersionPath: String,
        selectionRecord: String,
        selectionRecordOwner: String,
        selectionField: String
    ) {
        self.sourcePayloadRoot = sourcePayloadRoot
        self.materialization = materialization
        self.selection = selection
        self.dataRootRelativeVersionPath = dataRootRelativeVersionPath
        self.selectionRecord = selectionRecord
        self.selectionRecordOwner = selectionRecordOwner
        self.selectionField = selectionField
    }
}

public struct TrustedCandidateMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let productIdentity: String
    public let executable: String
    public let packageIdentifier: String
    public let serviceLabel: String
    public let version: String
    public let tag: String
    public let source: TrustedCandidateSource
    public let owner: String
    public let securityContact: String
    public let teamID: String
    public let applicationIdentity: String
    public let installerIdentity: String
    public let compatibility: TrustedCandidateCompatibility
    public let deliveryLayouts: TrustedCandidateDeliveryLayouts
    public let runtimeLifecycle: TrustedCandidateRuntimeLayout
    public let modelManifest: TrustedCandidateModelManifest
    public let swiftResourceBundle: String?
    public let formulaClass: String
    public let buildTimestamp: String
    public let unsignedDryRun: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case productIdentity
        case executable
        case packageIdentifier
        case serviceLabel
        case version
        case tag
        case source
        case owner
        case securityContact
        case teamID = "teamId"
        case applicationIdentity
        case installerIdentity
        case compatibility
        case deliveryLayouts
        case runtimeLifecycle
        case modelManifest
        case swiftResourceBundle
        case formulaClass
        case buildTimestamp
        case unsignedDryRun
    }

    public init(
        schemaVersion: Int = 1,
        productIdentity: String,
        executable: String,
        packageIdentifier: String,
        serviceLabel: String,
        version: String,
        tag: String,
        source: TrustedCandidateSource,
        owner: String,
        securityContact: String,
        teamID: String,
        applicationIdentity: String,
        installerIdentity: String,
        compatibility: TrustedCandidateCompatibility,
        deliveryLayouts: TrustedCandidateDeliveryLayouts,
        runtimeLifecycle: TrustedCandidateRuntimeLayout,
        modelManifest: TrustedCandidateModelManifest,
        swiftResourceBundle: String?,
        formulaClass: String,
        buildTimestamp: String,
        unsignedDryRun: Bool
    ) throws {
        self.schemaVersion = schemaVersion
        self.productIdentity = productIdentity
        self.executable = executable
        self.packageIdentifier = packageIdentifier
        self.serviceLabel = serviceLabel
        self.version = version
        self.tag = tag
        self.source = source
        self.owner = owner
        self.securityContact = securityContact
        self.teamID = teamID
        self.applicationIdentity = applicationIdentity
        self.installerIdentity = installerIdentity
        self.compatibility = compatibility
        self.deliveryLayouts = deliveryLayouts
        self.runtimeLifecycle = runtimeLifecycle
        self.modelManifest = modelManifest
        self.swiftResourceBundle = swiftResourceBundle
        self.formulaClass = formulaClass
        self.buildTimestamp = buildTimestamp
        self.unsignedDryRun = unsignedDryRun
        try validateIntrinsic()
    }

    public init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.hasExactKeys(object, Self.metadataKeys),
              let source = object["source"] as? [String: Any],
              let compatibility = object["compatibility"] as? [String: Any],
              let deliveryLayouts = object["deliveryLayouts"] as? [String: Any],
              let package = deliveryLayouts["package"] as? [String: Any],
              let homebrew = deliveryLayouts["homebrew"] as? [String: Any],
              let runtime = object["runtimeLifecycle"] as? [String: Any],
              let modelManifest = object["modelManifest"] as? [String: Any]
        else {
            throw TrustedCandidateError.invalidMetadata
        }

        guard Self.hasExactKeys(source, ["commit", "annotatedTag"]),
              Self.hasExactKeys(compatibility, ["minimumMacOS", "architecture"]),
              Self.hasExactKeys(deliveryLayouts, ["package", "homebrew"]),
              Self.hasExactKeys(package, ["payloadRoot", "installLocation", "installedRoot", "executable", "serviceLabel"]),
              Self.hasExactKeys(homebrew, ["sourcePayloadRoot", "libexecRoot", "executable", "binSymlink", "currentPointer", "serviceLabel"]),
              Self.hasExactKeys(runtime, ["sourcePayloadRoot", "materialization", "selection", "dataRootRelativeVersionPath", "selectionRecord", "selectionRecordOwner", "selectionField"]),
              Self.hasExactKeys(modelManifest, ["path", "sha256"])
        else {
            throw TrustedCandidateError.invalidMetadata
        }

        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw TrustedCandidateError.invalidMetadata
        }
        try validateIntrinsic()
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func identityDigest() throws -> String {
        let digest = SHA256.hash(data: try encodedData())
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let metadataKeys: Set<String> = [
        "schemaVersion", "productIdentity", "executable", "packageIdentifier", "serviceLabel",
        "version", "tag", "source", "owner", "securityContact", "teamId", "applicationIdentity",
        "installerIdentity", "compatibility", "deliveryLayouts", "runtimeLifecycle", "modelManifest",
        "swiftResourceBundle", "formulaClass", "buildTimestamp", "unsignedDryRun"
    ]

    private static func hasExactKeys(_ object: [String: Any], _ keys: Set<String>) -> Bool {
        Set(object.keys) == keys
    }

    private func validateIntrinsic() throws {
        guard schemaVersion == 1 else { throw TrustedCandidateError.invalidField("schemaVersion") }
        guard Self.isSafeVersion(version) else {
            throw TrustedCandidateError.invalidField("version")
        }
        guard Self.isSafeExecutable(executable) else {
            throw TrustedCandidateError.invalidField("executable")
        }
        try Self.validateIdentity(productIdentity, field: "productIdentity")
        guard Self.isPackageIdentifier(packageIdentifier) else {
            throw TrustedCandidateError.invalidField("packageIdentifier")
        }
        guard Self.isPackageIdentifier(serviceLabel) else {
            throw TrustedCandidateError.invalidField("serviceLabel")
        }
        guard Self.isSafeTag(tag), tag == "v" + version, Self.isCommit(source.commit), source.annotatedTag else {
            throw TrustedCandidateError.invalidField("source")
        }
        try Self.validateText(owner, field: "owner")
        try Self.validateText(securityContact, field: "securityContact")
        guard Self.isTeamID(teamID),
              Self.isApplicationIdentity(applicationIdentity, teamID: teamID),
              Self.isInstallerIdentity(installerIdentity, teamID: teamID)
        else {
            throw TrustedCandidateError.invalidField("signing identity")
        }
        try Self.validateText(applicationIdentity, field: "applicationIdentity")
        try Self.validateText(installerIdentity, field: "installerIdentity")
        guard !unsignedDryRun else {
            throw TrustedCandidateError.invalidField("unsignedDryRun")
        }
        guard compatibility.minimumMacOS == "14.0",
              compatibility.architecture == "arm64"
        else {
            throw TrustedCandidateError.invalidField("compatibility")
        }
        guard Self.isSHA256(modelManifest.sha256),
              Self.isSafeRelativePath(modelManifest.path),
              modelManifest.path == "metadata/model-manifest.json"
        else {
            throw TrustedCandidateError.invalidField("modelManifest")
        }
        guard Self.isFormulaClass(formulaClass),
              !buildTimestamp.isEmpty,
              buildTimestamp.hasSuffix("Z")
        else {
            throw TrustedCandidateError.invalidField("build metadata")
        }
        if let swiftResourceBundle {
            guard Self.isSafeBundleName(swiftResourceBundle) else {
                throw TrustedCandidateError.invalidField("swiftResourceBundle")
            }
        }
        try validateLayouts()
    }

    private func validateLayouts() throws {
        let relativeRoot = "Library/Application Support/\(productIdentity)/versions/\(version)"
        let installedRoot = "/\(relativeRoot)"
        guard deliveryLayouts.package.payloadRoot == relativeRoot,
              deliveryLayouts.package.installLocation == "/",
              deliveryLayouts.package.installedRoot == installedRoot,
              deliveryLayouts.package.executable == installedRoot + "/" + executable,
              deliveryLayouts.package.serviceLabel == serviceLabel,
              deliveryLayouts.homebrew.sourcePayloadRoot == relativeRoot,
              deliveryLayouts.homebrew.libexecRoot == "libexec",
              deliveryLayouts.homebrew.executable == "libexec/" + executable,
              deliveryLayouts.homebrew.binSymlink == "bin/" + executable,
              deliveryLayouts.homebrew.currentPointer == "not applicable; Homebrew uses the formula prefix",
              deliveryLayouts.homebrew.serviceLabel == serviceLabel
        else {
            throw TrustedCandidateError.invalidField("deliveryLayouts")
        }

        guard runtimeLifecycle.sourcePayloadRoot == relativeRoot,
              runtimeLifecycle.dataRootRelativeVersionPath == "service/versions/{version}",
              runtimeLifecycle.selectionRecord == "service/selection.json",
              runtimeLifecycle.selectionRecordOwner == "service lifecycle",
              runtimeLifecycle.selectionField == "activeVersion",
              runtimeLifecycle.materialization == "The service copies the immutable payload into its per-user version store",
              runtimeLifecycle.selection == "The service lifecycle owns per-user version selection and rollback"
        else {
            throw TrustedCandidateError.invalidField("runtimeLifecycle")
        }
    }

    private static func validateIdentity(_ value: String, field: String) throws {
        guard isIdentity(value) else {
            throw TrustedCandidateError.invalidField(field)
        }
    }

    private static func validateText(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.count <= 256,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              !containsPlaceholder(value)
        else {
            throw TrustedCandidateError.invalidField(field)
        }
    }

    private static func isApplicationIdentity(_ value: String, teamID: String) -> Bool {
        matches("^Developer ID Application: .+ \\(\(teamID)\\)$", value)
    }

    private static func isInstallerIdentity(_ value: String, teamID: String) -> Bool {
        matches("^Developer ID Installer: .+ \\(\(teamID)\\)$", value)
    }

    private static func isSafeExecutable(_ value: String) -> Bool {
        matches("^[A-Za-z][A-Za-z0-9._-]{1,127}$", value) && !containsPlaceholder(value)
    }

    private static func isIdentity(_ value: String) -> Bool {
        matches("^[A-Za-z][A-Za-z0-9_-]{2,63}$", value) && !containsPlaceholder(value)
    }

    private static func isPackageIdentifier(_ value: String) -> Bool {
        matches("^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", value) && !containsPlaceholder(value)
    }

    private static func isFormulaClass(_ value: String) -> Bool {
        matches("^[A-Z][A-Za-z0-9]{1,63}$", value) && !containsPlaceholder(value)
    }

    private static func isSafeVersion(_ value: String) -> Bool {
        matches("^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$", value) && !containsPlaceholder(value)
    }

    private static func isSafeTag(_ value: String) -> Bool {
        matches("^v[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$", value) && !containsPlaceholder(value)
    }

    private static func isSafeBundleName(_ value: String) -> Bool {
        value.hasSuffix(".bundle") &&
            !value.contains("/") &&
            !value.contains("\\") &&
            !value.contains("..") &&
            value.count <= 256
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty &&
            !value.hasPrefix("/") &&
            !value.contains("\\") &&
            !value.contains("\0") &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        containsPlaceholder(value)
    }

    private static func containsPlaceholder(_ value: String) -> Bool {
        let folded = value.lowercased()
        return folded.contains("newname") ||
            folded.contains("new-name") ||
            folded.contains("placeholder") ||
            folded.contains("unresolved") ||
            folded.contains("not-selected") ||
            folded.contains("not selected") ||
            folded.contains("todo") ||
            folded.range(of: "example\\.(com|org|net|invalid)", options: .regularExpression) != nil ||
            value.range(of: "<[^>]+>", options: .regularExpression) != nil
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return false
        }
        return NSRange(range, in: value) == NSRange(location: 0, length: value.utf16.count)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func isTeamID(_ value: String) -> Bool {
        matches("^[A-Z0-9]{10}$", value)
    }
}

public struct TrustedCandidateExecutableSnapshot: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let linkCount: UInt64
    public let size: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64
    public let sha256: String

    init(stat value: stat, sha256: String) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        mode = UInt32(value.st_mode)
        linkCount = UInt64(value.st_nlink)
        size = UInt64(value.st_size)
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        self.sha256 = sha256
    }
}

public struct TrustedCandidateSignatureEvidence: Equatable, Sendable {
    public let verified: Bool
    public let applicationIdentity: String
    public let teamID: String
    public let hardenedRuntime: Bool
    public let timestamped: Bool
    public let notarized: Bool
    public let stapled: Bool
    public let gatekeeperAccepted: Bool
    public let executableDigest: String
    public let buildProductIdentity: String
    public let buildPackageIdentifier: String
    public let buildVersion: String
    public let buildSourceCommit: String
    public let buildTag: String

    public init(
        verified: Bool,
        applicationIdentity: String,
        teamID: String,
        hardenedRuntime: Bool,
        timestamped: Bool,
        notarized: Bool,
        stapled: Bool,
        gatekeeperAccepted: Bool,
        executableDigest: String,
        buildProductIdentity: String,
        buildPackageIdentifier: String,
        buildVersion: String,
        buildSourceCommit: String,
        buildTag: String
    ) {
        self.verified = verified
        self.applicationIdentity = applicationIdentity
        self.teamID = teamID
        self.hardenedRuntime = hardenedRuntime
        self.timestamped = timestamped
        self.notarized = notarized
        self.stapled = stapled
        self.gatekeeperAccepted = gatekeeperAccepted
        self.executableDigest = executableDigest
        self.buildProductIdentity = buildProductIdentity
        self.buildPackageIdentifier = buildPackageIdentifier
        self.buildVersion = buildVersion
        self.buildSourceCommit = buildSourceCommit
        self.buildTag = buildTag
    }
}

public struct TrustedCandidateSignatureEvaluator: Sendable {
    private let evaluateClosure: @Sendable (URL, TrustedCandidateExecutableSnapshot) throws -> TrustedCandidateSignatureEvidence

    public init(evaluate: @escaping @Sendable (URL, TrustedCandidateExecutableSnapshot) throws -> TrustedCandidateSignatureEvidence) {
        evaluateClosure = evaluate
    }

    public func evaluate(
        executable: URL,
        snapshot: TrustedCandidateExecutableSnapshot
    ) throws -> TrustedCandidateSignatureEvidence {
        try evaluateClosure(executable, snapshot)
    }
}

public struct TrustedCandidateRequirements: Equatable, Sendable {
    public let productIdentity: String
    public let executable: String
    public let packageIdentifier: String
    public let serviceLabel: String
    public let version: String
    public let sourceCommit: String
    public let tag: String
    public let applicationIdentity: String
    public let teamID: String
    public let architecture: String
    public let manifestPath: String
    public let manifestDigest: String
    public let swiftResourceBundle: String

    public init(
        productIdentity: String,
        executable: String,
        packageIdentifier: String,
        serviceLabel: String,
        version: String,
        sourceCommit: String,
        tag: String,
        applicationIdentity: String,
        teamID: String,
        architecture: String = "arm64",
        manifestPath: String = "metadata/model-manifest.json",
        manifestDigest: String,
        swiftResourceBundle: String
    ) {
        self.productIdentity = productIdentity
        self.executable = executable
        self.packageIdentifier = packageIdentifier
        self.serviceLabel = serviceLabel
        self.version = version
        self.sourceCommit = sourceCommit
        self.tag = tag
        self.applicationIdentity = applicationIdentity
        self.teamID = teamID
        self.architecture = architecture
        self.manifestPath = manifestPath
        self.manifestDigest = manifestDigest
        self.swiftResourceBundle = swiftResourceBundle
    }
}

public final class TrustedCandidateLease: @unchecked Sendable {
    private let authority: PinnedDirectoryAuthority
    private let executable: PinnedExecutable
    private let inventory: CandidateTreeInventory
    private let lock = NSLock()

    fileprivate init(
        authority: PinnedDirectoryAuthority,
        executable: PinnedExecutable,
        inventory: CandidateTreeInventory
    ) {
        self.authority = authority
        self.executable = executable
        self.inventory = inventory
    }

    public func verifyStillValid() throws {
        lock.lock()
        defer { lock.unlock() }
        try authority.verify()
        try inventory.verify()
        try executable.verify()
    }
}

public struct TrustedVersionedCandidate: Equatable, Sendable {
    public let metadata: TrustedCandidateMetadata
    public let versionDirectory: URL
    public let identityDigest: String
    public let manifestDigest: String
    public let signatureEvidence: TrustedCandidateSignatureEvidence
    public let lease: TrustedCandidateLease

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metadata == rhs.metadata &&
            lhs.versionDirectory == rhs.versionDirectory &&
            lhs.identityDigest == rhs.identityDigest &&
            lhs.manifestDigest == rhs.manifestDigest &&
            lhs.signatureEvidence == rhs.signatureEvidence
    }
}

public enum TrustedCandidateArchitecture {
    public static func detect(at executable: URL) throws -> String {
        let data = try readPinnedPrefix(executable, count: 8)
        guard data.count == 8,
              Array(data.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe],
              Array(data.dropFirst(4)) == [0x0c, 0x00, 0x00, 0x01]
        else {
            throw TrustedCandidateError.architectureMismatch
        }
        return "arm64"
    }
}

public struct TrustedCandidateValidator: Sendable {
    private let requirements: TrustedCandidateRequirements
    private let signatureEvaluator: TrustedCandidateSignatureEvaluator

    public init(
        requirements: TrustedCandidateRequirements,
        signatureEvaluator: TrustedCandidateSignatureEvaluator,
        architectureProbe: @escaping @Sendable (URL) throws -> String = TrustedCandidateArchitecture.detect
    ) {
        self.requirements = requirements
        self.signatureEvaluator = signatureEvaluator
        // Kept for source compatibility. Validation uses the held executable descriptor.
        _ = architectureProbe
    }

    public func validate(dataRoot: URL, version: String) throws -> TrustedVersionedCandidate {
        let logicalRoot = dataRoot.standardizedFileURL
        guard dataRoot.isFileURL,
              dataRoot.path.hasPrefix("/"),
              isStableAbsolutePath(dataRoot)
        else {
            throw TrustedCandidateError.unsafePath("data root")
        }
        _ = try ServiceVersionedLayout.versionDirectory(dataRoot: logicalRoot, version: version)
        let authority = try PinnedDirectoryAuthority(dataRoot: try authorityRootURL(dataRoot), version: version)
        return try validate(using: authority)
    }

    func validate(at versionDirectory: URL) throws -> TrustedVersionedCandidate {
        let directory = versionDirectory.standardizedFileURL
        guard versionDirectory.isFileURL,
              versionDirectory.path.hasPrefix("/"),
              versionDirectory.path == directory.path,
              ServiceVersionedLayout.isSafeVersion(directory.lastPathComponent)
        else {
            throw TrustedCandidateError.unsafePath("version directory")
        }

        let dataRoot = directory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let authority = try PinnedDirectoryAuthority(dataRoot: dataRoot, version: directory.lastPathComponent)
        return try validate(using: authority)
    }

    private func validate(using authority: PinnedDirectoryAuthority) throws -> TrustedVersionedCandidate {
        let directory = authority.versionDirectory
        try authority.retainDirectory(relative: [ServiceVersionedLayout.candidateMetadataDirectoryName])

        let metadataURL = ServiceVersionedLayout.candidateMetadata(versionDirectory: directory)
        let metadataData = try readPinnedRegularFile(
            metadataURL,
            authority: authority,
            relative: [ServiceVersionedLayout.candidateMetadataDirectoryName, ServiceVersionedLayout.candidateMetadataFileName],
            limit: 256 * 1024
        )
        let metadata = try TrustedCandidateMetadata(data: metadataData)
        guard metadata.version == directory.lastPathComponent else {
            throw TrustedCandidateError.metadataMismatch("version")
        }
        try match(metadata)

        let executableURL = directory.appendingPathComponent(metadata.executable, isDirectory: false)
        let executable = try PinnedExecutable(url: executableURL, authority: authority, relative: [metadata.executable])

        try executable.verify()
        guard try executable.detectArchitecture() == metadata.compatibility.architecture else {
            throw TrustedCandidateError.architectureMismatch
        }
        try executable.verify()

        let evidence: TrustedCandidateSignatureEvidence
        let snapshotURL = try executable.materializeSnapshot()
        defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
        do {
            evidence = try signatureEvaluator.evaluate(executable: snapshotURL, snapshot: executable.snapshot)
        } catch {
            throw TrustedCandidateError.signatureUnverified
        }
        try executable.verifySnapshot(at: snapshotURL)
        try executable.verify()
        try validateSignatureEvidence(evidence, metadata: metadata, snapshot: executable.snapshot)

        let manifestURL = try safeRelativeURL(metadata.modelManifest.path, within: directory)
        try validateRelativeAncestors(manifestURL, root: directory)
        let manifestData = try readPinnedRegularFile(
            manifestURL,
            authority: authority,
            relative: metadata.modelManifest.path.split(separator: "/").map { String($0) },
            limit: 8 * 1024 * 1024
        )
        let manifestDigest = sha256(manifestData)
        guard manifestDigest == metadata.modelManifest.sha256,
              manifestDigest == requirements.manifestDigest
        else {
            throw TrustedCandidateError.digestMismatch
        }

        let inventory = try authority.makeTreeInventory(expectedDigests: [
            "metadata/release.json": sha256(metadataData),
            metadata.modelManifest.path: manifestDigest,
            metadata.executable: executable.snapshot.sha256
        ])
        guard requirements.swiftResourceBundle == expectedSwiftResourceBundleName,
              metadata.swiftResourceBundle == expectedSwiftResourceBundleName,
              metadata.swiftResourceBundle == requirements.swiftResourceBundle,
              let bundleName = metadata.swiftResourceBundle
        else {
            throw TrustedCandidateError.metadataMismatch("swiftResourceBundle")
        }
        let expectedBundles = Set([bundleName])
        guard inventory.bundleDirectories() == expectedBundles,
              inventory.hasExactResourceManifest(
                  bundleName: bundleName,
                  manifestName: expectedSwiftResourceManifestName,
                  digest: requirements.manifestDigest
              ) else {
            throw TrustedCandidateError.metadataMismatch("swiftResourceBundle")
        }
        try inventory.verify()
        try executable.verify()
        try authority.verify()
        return TrustedVersionedCandidate(
            metadata: metadata,
            versionDirectory: directory,
            identityDigest: try metadata.identityDigest(),
            manifestDigest: manifestDigest,
            signatureEvidence: evidence,
            lease: TrustedCandidateLease(authority: authority, executable: executable, inventory: inventory)
        )
    }

    private func authorityRootURL(_ dataRoot: URL) throws -> URL {
        let root = dataRoot
        guard dataRoot.isFileURL,
              dataRoot.path.hasPrefix("/"),
              isStableAbsolutePath(dataRoot)
        else {
            throw TrustedCandidateError.unsafePath("data root")
        }
        if root.path == "/var" || root.path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + root.path, isDirectory: true)
        }
        if root.path == "/tmp" || root.path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + root.path, isDirectory: true)
        }
        return root
    }

    private func match(_ metadata: TrustedCandidateMetadata) throws {
        guard metadata.productIdentity == requirements.productIdentity else {
            throw TrustedCandidateError.metadataMismatch("productIdentity")
        }
        guard !metadata.unsignedDryRun else {
            throw TrustedCandidateError.metadataMismatch("unsignedDryRun")
        }
        guard metadata.executable == requirements.executable else {
            throw TrustedCandidateError.metadataMismatch("executable")
        }
        guard metadata.packageIdentifier == requirements.packageIdentifier else {
            throw TrustedCandidateError.metadataMismatch("packageIdentifier")
        }
        guard metadata.serviceLabel == requirements.serviceLabel else {
            throw TrustedCandidateError.metadataMismatch("serviceLabel")
        }
        if metadata.version != requirements.version {
            throw TrustedCandidateError.metadataMismatch("version")
        }
        guard metadata.source.commit == requirements.sourceCommit else {
            throw TrustedCandidateError.metadataMismatch("source.commit")
        }
        guard metadata.tag == requirements.tag else {
            throw TrustedCandidateError.metadataMismatch("tag")
        }
        guard metadata.applicationIdentity == requirements.applicationIdentity,
              metadata.teamID == requirements.teamID
        else {
            throw TrustedCandidateError.metadataMismatch("signing identity")
        }
        guard metadata.compatibility.architecture == requirements.architecture else {
            throw TrustedCandidateError.architectureMismatch
        }
        guard metadata.modelManifest.path == requirements.manifestPath else {
            throw TrustedCandidateError.metadataMismatch("modelManifest.path")
        }
        guard metadata.modelManifest.sha256 == requirements.manifestDigest else {
            throw TrustedCandidateError.digestMismatch
        }
        guard requirements.swiftResourceBundle == expectedSwiftResourceBundleName,
              metadata.swiftResourceBundle == expectedSwiftResourceBundleName,
              metadata.swiftResourceBundle == requirements.swiftResourceBundle
        else {
            throw TrustedCandidateError.metadataMismatch("swiftResourceBundle")
        }
    }

    private func validateSignatureEvidence(
        _ evidence: TrustedCandidateSignatureEvidence,
        metadata: TrustedCandidateMetadata,
        snapshot: TrustedCandidateExecutableSnapshot
    ) throws {
        guard evidence.verified,
              evidence.hardenedRuntime,
              evidence.timestamped,
              evidence.notarized,
              evidence.stapled,
              evidence.gatekeeperAccepted,
              evidence.executableDigest == snapshot.sha256,
              evidence.buildProductIdentity == requirements.productIdentity,
              evidence.buildPackageIdentifier == requirements.packageIdentifier,
              evidence.buildVersion == metadata.version,
              evidence.buildSourceCommit == requirements.sourceCommit,
              evidence.buildTag == requirements.tag,
              evidence.applicationIdentity == metadata.applicationIdentity,
              evidence.applicationIdentity == requirements.applicationIdentity,
              evidence.teamID == metadata.teamID,
              evidence.teamID == requirements.teamID
        else {
            throw TrustedCandidateError.signatureUnverified
        }
    }

    private func validateRelativeAncestors(_ file: URL, root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw TrustedCandidateError.unsafePath(file.path)
        }
        let suffix = String(filePath.dropFirst(rootPath.count + 1))
        let components = suffix.split(separator: "/")
        guard !components.isEmpty else { throw TrustedCandidateError.unsafePath(file.path) }
        var current = root
        for component in components.dropLast() {
            current.appendPathComponent(String(component), isDirectory: true)
            let info = try lstatNode(current, relativePath: String(component))
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw TrustedCandidateError.unsafeFileType(current.path)
            }
            guard (info.st_mode & 0o222) == 0 else {
                throw TrustedCandidateError.unsafePermissions(current.path)
            }
        }
    }

    private func lstatNode(_ url: URL, relativePath: String) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { throw TrustedCandidateError.missingFile(relativePath) }
            throw TrustedCandidateError.unsafePath(relativePath)
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            throw TrustedCandidateError.symbolicLink(relativePath)
        }
        return info
    }
}

private struct CandidateNodeIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let linkCount: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(stat value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        mode = UInt32(value.st_mode)
        linkCount = UInt64(value.st_nlink)
        size = UInt64(value.st_size)
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

private struct CandidateTreeEntry {
    let relativePath: String
    let url: URL
    let descriptor: Int32
    let isDirectory: Bool
    let identity: CandidateNodeIdentity
    let digest: String?
}

private final class CandidateTreeInventory {
    static let maxEntries = 4096
    static let maxDepth = 64
    static let maxFileBytes: UInt64 = 512 * 1024 * 1024
    static let maxTotalBytes: UInt64 = 1024 * 1024 * 1024

    private let entries: [CandidateTreeEntry]

    init(entries: [CandidateTreeEntry]) {
        self.entries = entries
    }

    func bundleDirectories() -> Set<String> {
        Set(
            entries
                .filter { $0.isDirectory && $0.relativePath.hasSuffix(".bundle") }
                .map(\.relativePath)
        )
    }

    func hasExactResourceManifest(bundleName: String, manifestName: String, digest: String) -> Bool {
        let prefix = bundleName + "/"
        let scopedEntries = entries.filter {
            $0.relativePath == bundleName || $0.relativePath.hasPrefix(prefix)
        }
        guard scopedEntries.count == 2,
              scopedEntries.contains(where: { $0.relativePath == bundleName && $0.isDirectory }),
              let manifest = scopedEntries.first(where: {
                  $0.relativePath == prefix + manifestName && !$0.isDirectory
              })
        else {
            return false
        }
        return manifest.digest == digest
    }

    func verify() throws {
        guard entries.count <= Self.maxEntries else {
            throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
        }
        var totalBytes: UInt64 = 0
        for entry in entries {
            var descriptorInfo = stat()
            var visibleInfo = stat()
            guard fstat(entry.descriptor, &descriptorInfo) == 0,
                  lstat(entry.url.path, &visibleInfo) == 0,
                  CandidateNodeIdentity(stat: descriptorInfo) == entry.identity,
                  CandidateNodeIdentity(stat: visibleInfo) == entry.identity
            else {
                throw TrustedCandidateError.unsafePath(entry.relativePath)
            }

            let type = descriptorInfo.st_mode & S_IFMT
            if entry.isDirectory {
                guard type == S_IFDIR,
                      (descriptorInfo.st_mode & 0o222) == 0
                else {
                    throw TrustedCandidateError.unsafePermissions(entry.relativePath)
                }
                continue
            }

            guard type == S_IFREG,
                  descriptorInfo.st_nlink == 1,
                  (descriptorInfo.st_mode & 0o222) == 0,
                  UInt64(descriptorInfo.st_size) <= Self.maxFileBytes,
                  let expectedDigest = entry.digest
            else {
                if descriptorInfo.st_nlink != 1 {
                    throw TrustedCandidateError.hardLink(entry.relativePath)
                }
                throw TrustedCandidateError.unsafePermissions(entry.relativePath)
            }
            totalBytes += UInt64(descriptorInfo.st_size)
            guard totalBytes <= Self.maxTotalBytes else {
                throw TrustedCandidateError.unsafeFileType("candidate tree byte limit")
            }
            let digest = try hashDescriptor(entry.descriptor, expectedSize: descriptorInfo.st_size)
            var after = stat()
            var visibleAfter = stat()
            guard fstat(entry.descriptor, &after) == 0,
                  lstat(entry.url.path, &visibleAfter) == 0,
                  CandidateNodeIdentity(stat: after) == entry.identity,
                  CandidateNodeIdentity(stat: visibleAfter) == entry.identity,
                  digest == expectedDigest
            else {
                throw TrustedCandidateError.invalidMetadata
            }
        }
    }

    deinit {
        for entry in entries {
            close(entry.descriptor)
        }
    }
}

private struct DirectoryIdentity: Equatable {
    // Parent directory timestamps and link counts change when unrelated temporary
    // entries are created. The tree inventory checks candidate contents separately.
    // These fields therefore track only replacement and permission changes.
    let device: UInt64
    let inode: UInt64
    let mode: UInt32

    init(stat value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        mode = UInt32(value.st_mode)
    }
}

private struct HeldDirectory {
    let url: URL
    let descriptor: Int32
    let identity: DirectoryIdentity
    let strictIdentity: CandidateNodeIdentity?
}

private final class PinnedDirectoryAuthority {
    private(set) var versionDirectory: URL
    private var versionDescriptor: Int32
    private var heldDirectories: [HeldDirectory]

    init(dataRoot: URL, version: String) throws {
        let root = dataRoot
        guard dataRoot.isFileURL,
              dataRoot.path.hasPrefix("/"),
              isStableAbsolutePath(dataRoot),
              Self.isSafeVersion(version)
        else {
            throw TrustedCandidateError.unsafePath("directory authority")
        }

        let rootDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw TrustedCandidateError.unsafePath("/") }
        versionDirectory = root
        versionDescriptor = rootDescriptor
        heldDirectories = []
        do {
            try appendHeldDirectory(
                url: URL(fileURLWithPath: "/", isDirectory: true),
                descriptor: rootDescriptor,
                requireImmutable: false
            )

            var parent = rootDescriptor
            var current = URL(fileURLWithPath: "/", isDirectory: true)
            let rootComponents = root.path.split(separator: "/").map(String.init)
            let components = rootComponents + [
                ServiceVersionedLayout.serviceDirectoryName,
                ServiceVersionedLayout.versionsDirectoryName,
                version
            ]
            for (index, component) in components.enumerated() {
                guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                    throw TrustedCandidateError.unsafePath(component)
                }
                let descriptor = component.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else {
                    throw TrustedCandidateError.missingFile(component)
                }
                current = current.appendingPathComponent(component, isDirectory: true)
                do {
                    try appendHeldDirectory(
                        url: current,
                        descriptor: descriptor,
                        requireImmutable: index == components.count - 1
                    )
                } catch {
                    close(descriptor)
                    throw error
                }
                parent = descriptor
            }
            versionDirectory = current
            versionDescriptor = parent
            guard heldDirectories.last?.descriptor == versionDescriptor else {
                throw TrustedCandidateError.unsafePath("version directory authority")
            }
        } catch {
            for held in heldDirectories { close(held.descriptor) }
            throw error
        }
    }

    func retainDirectory(relative: [String]) throws {
        let (descriptor, url) = try openRelative(relative, directory: true)
        do {
            try appendHeldDirectory(url: url, descriptor: descriptor, requireImmutable: true)
        } catch {
            close(descriptor)
            throw error
        }
    }

    func openFile(relative: [String]) throws -> (descriptor: Int32, url: URL) {
        try openRelative(relative, directory: false)
    }

    func makeTreeInventory(expectedDigests: [String: String]) throws -> CandidateTreeInventory {
        let rootDescriptor = dup(versionDescriptor)
        guard rootDescriptor >= 0 else {
            throw TrustedCandidateError.unsafePath("candidate tree")
        }
        var entries: [CandidateTreeEntry] = []
        var seen: Set<String> = []
        var totalBytes: UInt64 = 0
        do {
            var rootInfo = stat()
            var visibleRootInfo = stat()
            guard fstat(rootDescriptor, &rootInfo) == 0,
                  lstat(versionDirectory.path, &visibleRootInfo) == 0,
                  (rootInfo.st_mode & S_IFMT) == S_IFDIR,
                  (rootInfo.st_mode & 0o222) == 0,
                  CandidateNodeIdentity(stat: rootInfo) == CandidateNodeIdentity(stat: visibleRootInfo)
            else {
                throw TrustedCandidateError.unsafePermissions("candidate root")
            }
            entries.append(
                CandidateTreeEntry(
                    relativePath: ".",
                    url: versionDirectory,
                    descriptor: rootDescriptor,
                    isDirectory: true,
                    identity: CandidateNodeIdentity(stat: rootInfo),
                    digest: nil
                )
            )
            seen.insert(".")
            try collectTreeInventory(
                directoryURL: versionDirectory,
                directoryDescriptor: rootDescriptor,
                relativePath: ".",
                entries: &entries,
                seen: &seen,
                totalBytes: &totalBytes
            )
            guard entries.count <= CandidateTreeInventory.maxEntries else {
                throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
            }
            for (path, expectedDigest) in expectedDigests {
                guard let entry = entries.first(where: { $0.relativePath == path }),
                      !entry.isDirectory,
                      entry.digest == expectedDigest
                else {
                    throw TrustedCandidateError.digestMismatch
                }
            }
            return CandidateTreeInventory(entries: entries)
        } catch {
            for entry in entries {
                close(entry.descriptor)
            }
            throw error
        }
    }

    func verify() throws {
        for held in heldDirectories {
            var descriptorInfo = stat()
            var visibleInfo = stat()
            guard fstat(held.descriptor, &descriptorInfo) == 0,
                  lstat(held.url.path, &visibleInfo) == 0,
                  (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
                  (visibleInfo.st_mode & S_IFMT) == S_IFDIR,
                  DirectoryIdentity(stat: descriptorInfo) == held.identity,
                  DirectoryIdentity(stat: visibleInfo) == held.identity,
                  (held.strictIdentity.map({ CandidateNodeIdentity(stat: descriptorInfo) == $0 }) ?? true),
                  (held.strictIdentity.map({ CandidateNodeIdentity(stat: visibleInfo) == $0 }) ?? true)
            else {
                throw TrustedCandidateError.unsafePath("directory authority changed")
            }
        }
    }

    deinit {
        for held in heldDirectories { close(held.descriptor) }
    }

    private func openRelative(_ relative: [String], directory: Bool) throws -> (descriptor: Int32, url: URL) {
        guard !relative.isEmpty,
              relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") })
        else {
            throw TrustedCandidateError.unsafePath(relative.joined(separator: "/"))
        }

        var parent = versionDescriptor
        var current = versionDirectory
        var temporaryDescriptors: [Int32] = []
        defer {
            for descriptor in temporaryDescriptors { close(descriptor) }
        }

        for component in relative.dropLast() {
            let descriptor = String(component).withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw TrustedCandidateError.missingFile(String(component))
            }
            temporaryDescriptors.append(descriptor)
            parent = descriptor
            current = current.appendingPathComponent(String(component), isDirectory: true)
        }

        let leaf = String(relative.last!)
        let flags = directory
            ? O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            : O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        let descriptor = leaf.withCString { openat(parent, $0, flags) }
        guard descriptor >= 0 else {
            throw TrustedCandidateError.missingFile(leaf)
        }
        current = current.appendingPathComponent(leaf, isDirectory: directory).standardizedFileURL
        return (descriptor, current)
    }

    private func collectTreeInventory(
        directoryURL: URL,
        directoryDescriptor: Int32,
        relativePath: String,
        entries: inout [CandidateTreeEntry],
        seen: inout Set<String>,
        totalBytes: inout UInt64,
        depth: Int = 0
    ) throws {
        guard depth <= CandidateTreeInventory.maxDepth,
              entries.count <= CandidateTreeInventory.maxEntries
        else {
            throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
        }
        let children = try directoryNames(
            directoryDescriptor,
            maximumNames: CandidateTreeInventory.maxEntries - entries.count
        )
        for name in children {
            guard !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.contains("/"),
                  !name.contains("\\"),
                  !name.contains("\0")
            else {
                throw TrustedCandidateError.unsafePath(name)
            }
            let childRelativePath = relativePath == "."
                ? name
                : relativePath + "/" + name
            guard seen.insert(childRelativePath).inserted else {
                throw TrustedCandidateError.invalidMetadata
            }
            guard entries.count < CandidateTreeInventory.maxEntries else {
                throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
            }
            let childDepth = depth + 1
            guard childDepth <= CandidateTreeInventory.maxDepth else {
                throw TrustedCandidateError.unsafeFileType("candidate tree depth limit")
            }

            var visibleInfo = stat()
            guard name.withCString({
                fstatat(directoryDescriptor, $0, &visibleInfo, AT_SYMLINK_NOFOLLOW) == 0
            }) else {
                throw TrustedCandidateError.missingFile(childRelativePath)
            }
            if (visibleInfo.st_mode & S_IFMT) == S_IFLNK {
                throw TrustedCandidateError.symbolicLink(childRelativePath)
            }
            let visibleType = visibleInfo.st_mode & S_IFMT
            guard visibleType == S_IFDIR || visibleType == S_IFREG else {
                throw TrustedCandidateError.unsafeFileType(childRelativePath)
            }
            let childDescriptor = name.withCString {
                if visibleType == S_IFDIR {
                    return openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                return openat(directoryDescriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            }
            guard childDescriptor >= 0 else {
                throw TrustedCandidateError.unsafePath(childRelativePath)
            }
            var retainedDescriptor = false
            do {
                var descriptorInfo = stat()
                guard fstat(childDescriptor, &descriptorInfo) == 0,
                      CandidateNodeIdentity(stat: descriptorInfo) == CandidateNodeIdentity(stat: visibleInfo),
                      (descriptorInfo.st_mode & S_IFMT) == visibleType
                else {
                    throw TrustedCandidateError.unsafePath(childRelativePath)
                }
                let type = descriptorInfo.st_mode & S_IFMT
                let isDirectory = type == S_IFDIR
                guard isDirectory || type == S_IFREG else {
                    throw TrustedCandidateError.unsafeFileType(childRelativePath)
                }
                guard (descriptorInfo.st_mode & 0o222) == 0 else {
                    throw TrustedCandidateError.unsafePermissions(childRelativePath)
                }
                if isDirectory {
                    entries.append(
                        CandidateTreeEntry(
                            relativePath: childRelativePath,
                            url: directoryURL.appendingPathComponent(name, isDirectory: true),
                            descriptor: childDescriptor,
                            isDirectory: true,
                            identity: CandidateNodeIdentity(stat: descriptorInfo),
                            digest: nil
                        )
                    )
                    retainedDescriptor = true
                    try collectTreeInventory(
                        directoryURL: directoryURL.appendingPathComponent(name, isDirectory: true),
                        directoryDescriptor: childDescriptor,
                        relativePath: childRelativePath,
                        entries: &entries,
                        seen: &seen,
                        totalBytes: &totalBytes,
                        depth: childDepth
                    )
                } else {
                    guard descriptorInfo.st_nlink == 1,
                          descriptorInfo.st_size >= 0,
                          UInt64(descriptorInfo.st_size) <= CandidateTreeInventory.maxFileBytes,
                          totalBytes + UInt64(descriptorInfo.st_size) <= CandidateTreeInventory.maxTotalBytes
                    else {
                        if descriptorInfo.st_nlink != 1 {
                            throw TrustedCandidateError.hardLink(childRelativePath)
                        }
                        throw TrustedCandidateError.unsafeFileType(childRelativePath)
                    }
                    let digest = try hashDescriptor(childDescriptor, expectedSize: descriptorInfo.st_size)
                    var after = stat()
                    var visibleAfter = stat()
                    guard fstat(childDescriptor, &after) == 0,
                          name.withCString({
                              fstatat(directoryDescriptor, $0, &visibleAfter, AT_SYMLINK_NOFOLLOW) == 0
                          }),
                          CandidateNodeIdentity(stat: after) == CandidateNodeIdentity(stat: descriptorInfo),
                          CandidateNodeIdentity(stat: visibleAfter) == CandidateNodeIdentity(stat: descriptorInfo)
                    else {
                        throw TrustedCandidateError.invalidMetadata
                    }
                    totalBytes += UInt64(descriptorInfo.st_size)
                    entries.append(
                        CandidateTreeEntry(
                            relativePath: childRelativePath,
                            url: directoryURL.appendingPathComponent(name, isDirectory: false),
                            descriptor: childDescriptor,
                            isDirectory: false,
                            identity: CandidateNodeIdentity(stat: descriptorInfo),
                            digest: digest
                        )
                    )
                    retainedDescriptor = true
                }
            } catch {
                if !retainedDescriptor {
                    close(childDescriptor)
                }
                throw error
            }
        }
    }

    private func directoryNames(_ descriptor: Int32, maximumNames: Int) throws -> [String] {
        guard maximumNames >= 0 else {
            throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
        }
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw TrustedCandidateError.unsafePath("candidate tree enumeration")
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: UInt8.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) {
                    let bytes = UnsafeBufferPointer(
                        start: $0,
                        count: MemoryLayout.size(ofValue: entry.pointee.d_name)
                    )
                    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                    return String(decoding: bytes[..<end], as: UTF8.self)
                }
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximumNames else {
                throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
            }
            names.append(name)
        }
        guard errno == 0 else {
            throw TrustedCandidateError.unsafePath("candidate tree enumeration")
        }
        return names.sorted()
    }

    private func appendHeldDirectory(url: URL, descriptor: Int32, requireImmutable: Bool) throws {
        var descriptorInfo = stat()
        var visibleInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              lstat(url.path, &visibleInfo) == 0,
              (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
              (visibleInfo.st_mode & S_IFMT) == S_IFDIR,
              DirectoryIdentity(stat: descriptorInfo) == DirectoryIdentity(stat: visibleInfo)
        else {
            throw TrustedCandidateError.unsafePath(url.path)
        }
        let writableMask: mode_t = requireImmutable ? 0o222 : 0o022
        guard (descriptorInfo.st_mode & writableMask) == 0 else {
            throw TrustedCandidateError.unsafePermissions(url.path)
        }
        let strictIdentity = requireImmutable ? CandidateNodeIdentity(stat: descriptorInfo) : nil
        heldDirectories.append(
            HeldDirectory(
                url: url,
                descriptor: descriptor,
                identity: DirectoryIdentity(stat: descriptorInfo),
                strictIdentity: strictIdentity
            )
        )
    }

    private static func isSafeVersion(_ version: String) -> Bool {
        version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$", options: .regularExpression) != nil
    }
}

private final class PinnedExecutable {
    let url: URL
    let descriptor: Int32
    let snapshot: TrustedCandidateExecutableSnapshot

    init(url: URL, authority: PinnedDirectoryAuthority, relative: [String]) throws {
        let opened = try authority.openFile(relative: relative)
        let descriptor = opened.descriptor
        do {
            var before = stat()
            var visible = stat()
            guard fstat(descriptor, &before) == 0,
                  lstat(url.path, &visible) == 0,
                  isSafeExecutableStat(before),
                  sameExecutableIdentity(before, visible)
            else {
                throw TrustedCandidateError.unsafeFileType(url.path)
            }
            guard (before.st_mode & 0o222) == 0,
                  (before.st_mode & 0o100) != 0,
                  before.st_size >= 0,
                  before.st_size <= 2 * 1024 * 1024 * 1024
            else {
                throw TrustedCandidateError.unsafePermissions(url.path)
            }
            let digest = try hashDescriptor(descriptor, expectedSize: before.st_size)
            var after = stat()
            var visibleAfter = stat()
            guard fstat(descriptor, &after) == 0,
                  lstat(url.path, &visibleAfter) == 0,
                  sameExecutableIdentity(before, after),
                  sameExecutableIdentity(before, visibleAfter)
            else {
                throw TrustedCandidateError.invalidMetadata
            }
            self.url = url
            self.descriptor = descriptor
            self.snapshot = TrustedCandidateExecutableSnapshot(stat: after, sha256: digest)
        } catch {
            close(descriptor)
            throw error
        }
    }

    func verify() throws {
        var before = stat()
        var visible = stat()
        guard fstat(descriptor, &before) == 0,
              lstat(url.path, &visible) == 0,
              sameExecutableIdentity(before, snapshot),
              sameExecutableIdentity(before, visible)
        else {
            throw TrustedCandidateError.invalidMetadata
        }
        let digest = try hashDescriptor(descriptor, expectedSize: before.st_size)
        var after = stat()
        var visibleAfter = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &visibleAfter) == 0,
              sameExecutableIdentity(before, after),
              sameExecutableIdentity(before, visibleAfter),
              digest == snapshot.sha256
        else {
            throw TrustedCandidateError.invalidMetadata
        }
    }

    func detectArchitecture() throws -> String {
        try verify()
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw TrustedCandidateError.architectureMismatch
        }
        var prefix = [UInt8](repeating: 0, count: 8)
        let prefixCount = prefix.count
        var offset = 0
        while offset < prefixCount {
            let count = prefix.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), prefixCount - offset)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw TrustedCandidateError.architectureMismatch
            }
            guard count > 0 else { throw TrustedCandidateError.architectureMismatch }
            offset += count
        }
        try verify()
        guard Array(prefix.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe],
              Array(prefix.dropFirst(4)) == [0x0c, 0x00, 0x00, 0x01]
        else {
            throw TrustedCandidateError.architectureMismatch
        }
        return "arm64"
    }

    func materializeSnapshot() throws -> URL {
        try verify()
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("trusted-candidate-executable-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = directory.appendingPathComponent("executable", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            guard chmod(directory.path, mode_t(0o700)) == 0 else {
                throw TrustedCandidateError.unsafePermissions(directory.path)
            }
            let directoryDescriptor = directory.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard directoryDescriptor >= 0 else {
                throw TrustedCandidateError.unsafePath(directory.path)
            }
            defer { close(directoryDescriptor) }

            let outputDescriptor = snapshotURL.lastPathComponent.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o400)
                )
            }
            guard outputDescriptor >= 0 else {
                throw TrustedCandidateError.unsafePath(snapshotURL.path)
            }
            defer { close(outputDescriptor) }
            guard fchmod(outputDescriptor, mode_t(0o400)) == 0,
                  lseek(descriptor, 0, SEEK_SET) >= 0
            else {
                throw TrustedCandidateError.invalidMetadata
            }

            var copied: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while copied < snapshot.size {
                let requested = min(UInt64(buffer.count), snapshot.size - copied)
                let readCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, Int(requested))
                }
                guard readCount >= 0 else {
                    if errno == EINTR { continue }
                    throw TrustedCandidateError.invalidMetadata
                }
                guard readCount > 0 else { throw TrustedCandidateError.invalidMetadata }
                var written = 0
                while written < readCount {
                    let writeCount = buffer.withUnsafeBytes { bytes in
                        Darwin.write(
                            outputDescriptor,
                            bytes.baseAddress!.advanced(by: written),
                            readCount - written
                        )
                    }
                    guard writeCount >= 0 else {
                        if errno == EINTR { continue }
                        throw TrustedCandidateError.invalidMetadata
                    }
                    guard writeCount > 0 else { throw TrustedCandidateError.invalidMetadata }
                    written += writeCount
                }
                copied += UInt64(readCount)
            }
            guard fsync(outputDescriptor) == 0 else {
                throw TrustedCandidateError.invalidMetadata
            }

            var outputInfo = stat()
            var visibleInfo = stat()
            guard fstat(outputDescriptor, &outputInfo) == 0,
                  lstat(snapshotURL.path, &visibleInfo) == 0
            else {
                throw TrustedCandidateError.invalidMetadata
            }
            let outputDigest = try hashDescriptor(outputDescriptor, expectedSize: outputInfo.st_size)
            guard isSafeExecutableStat(outputInfo),
                  (outputInfo.st_mode & 0o022) == 0,
                  sameFileIdentity(outputInfo, visibleInfo),
                  UInt64(outputInfo.st_size) == snapshot.size,
                  outputDigest == snapshot.sha256
            else {
                throw TrustedCandidateError.invalidMetadata
            }
            try verify()
            return snapshotURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func verifySnapshot(at snapshotURL: URL) throws {
        let snapshotDescriptor = snapshotURL.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard snapshotDescriptor >= 0 else { throw TrustedCandidateError.signatureUnverified }
        defer { close(snapshotDescriptor) }
        var descriptorInfo = stat()
        var visibleInfo = stat()
        guard fstat(snapshotDescriptor, &descriptorInfo) == 0,
              lstat(snapshotURL.path, &visibleInfo) == 0,
              isSafeExecutableStat(descriptorInfo),
              (descriptorInfo.st_mode & 0o022) == 0,
              UInt64(descriptorInfo.st_size) == snapshot.size,
              sameFileIdentity(descriptorInfo, visibleInfo),
              try hashDescriptor(snapshotDescriptor, expectedSize: descriptorInfo.st_size) == snapshot.sha256
        else {
            throw TrustedCandidateError.signatureUnverified
        }
    }

    deinit { close(descriptor) }
}

private func isSafeExecutableStat(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_nlink == 1
}

private func sameExecutableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev &&
        lhs.st_ino == rhs.st_ino &&
        lhs.st_mode == rhs.st_mode &&
        lhs.st_nlink == rhs.st_nlink &&
        lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
        lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

private func sameExecutableIdentity(_ lhs: stat, _ rhs: TrustedCandidateExecutableSnapshot) -> Bool {
    UInt64(lhs.st_dev) == rhs.device &&
        UInt64(lhs.st_ino) == rhs.inode &&
        UInt32(lhs.st_mode) == rhs.mode &&
        UInt64(lhs.st_nlink) == rhs.linkCount &&
        UInt64(lhs.st_size) == rhs.size &&
        Int64(lhs.st_mtimespec.tv_sec) == rhs.modificationSeconds &&
        Int64(lhs.st_mtimespec.tv_nsec) == rhs.modificationNanoseconds &&
        Int64(lhs.st_ctimespec.tv_sec) == rhs.changeSeconds &&
        Int64(lhs.st_ctimespec.tv_nsec) == rhs.changeNanoseconds
}

private func hashDescriptor(_ descriptor: Int32, expectedSize: off_t) throws -> String {
    guard expectedSize >= 0, expectedSize <= 2 * 1024 * 1024 * 1024 else {
        throw TrustedCandidateError.unsafeFileType("executable")
    }
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw TrustedCandidateError.invalidMetadata
    }
    var hasher = SHA256()
    var total: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else {
            if errno == EINTR { continue }
            throw TrustedCandidateError.invalidMetadata
        }
        if count == 0 { break }
        total += off_t(count)
        guard total <= expectedSize else { throw TrustedCandidateError.invalidMetadata }
        hasher.update(data: Data(buffer[0..<count]))
    }
    guard total == expectedSize else { throw TrustedCandidateError.invalidMetadata }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func safeRelativeURL(_ path: String, within root: URL) throws -> URL {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.contains("\\"),
          !path.contains("\0"),
          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
        throw TrustedCandidateError.unsafePath(path)
    }
    let candidate = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
    guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else {
        throw TrustedCandidateError.unsafePath(path)
    }
    return candidate
}

private func readPinnedRegularFile(
    _ url: URL,
    authority: PinnedDirectoryAuthority,
    relative: [String],
    limit: Int
) throws -> Data {
    let opened = try authority.openFile(relative: relative)
    defer { close(opened.descriptor) }
    return try readPinnedRegularFile(url, descriptor: opened.descriptor, limit: limit)
}

private func readPinnedRegularFile(_ url: URL, limit: Int) throws -> Data {
    let descriptor = url.path.withCString {
        open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw TrustedCandidateError.missingFile(url.lastPathComponent) }
    defer { close(descriptor) }
    return try readPinnedRegularFile(url, descriptor: descriptor, limit: limit)
}

private func readPinnedRegularFile(_ url: URL, descriptor: Int32, limit: Int) throws -> Data {
    guard limit > 0 else { throw TrustedCandidateError.invalidMetadata }

    var visibleBefore = stat()
    guard lstat(url.path, &visibleBefore) == 0 else {
        if errno == ENOENT { throw TrustedCandidateError.missingFile(url.lastPathComponent) }
        throw TrustedCandidateError.unsafePath(url.lastPathComponent)
    }
    if (visibleBefore.st_mode & S_IFMT) == S_IFLNK {
        throw TrustedCandidateError.symbolicLink(url.lastPathComponent)
    }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
          (before.st_mode & S_IFMT) == S_IFREG,
          before.st_nlink == 1,
          (before.st_mode & 0o222) == 0,
          before.st_size >= 0,
          before.st_size <= off_t(limit),
          sameFileIdentity(before, visibleBefore)
    else {
        throw TrustedCandidateError.unsafeFileType(url.lastPathComponent)
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: min(16 * 1024, limit))
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else {
            if errno == EINTR { continue }
            throw TrustedCandidateError.invalidMetadata
        }
        if count == 0 { break }
        data.append(contentsOf: buffer[0..<count])
        guard data.count <= limit else { throw TrustedCandidateError.invalidMetadata }
    }

    var after = stat()
    var visibleAfter = stat()
    guard fstat(descriptor, &after) == 0,
          lstat(url.path, &visibleAfter) == 0,
          sameFileIdentity(before, after),
          sameFileIdentity(before, visibleAfter),
          after.st_size == before.st_size,
          data.count == Int(before.st_size)
    else {
        throw TrustedCandidateError.invalidMetadata
    }
    return data
}

private func readPinnedPrefix(_ url: URL, count: Int) throws -> Data {
    guard count > 0 else { throw TrustedCandidateError.invalidMetadata }

    var visibleBefore = stat()
    guard lstat(url.path, &visibleBefore) == 0 else {
        if errno == ENOENT { throw TrustedCandidateError.missingFile(url.lastPathComponent) }
        throw TrustedCandidateError.unsafePath(url.lastPathComponent)
    }
    if (visibleBefore.st_mode & S_IFMT) == S_IFLNK {
        throw TrustedCandidateError.symbolicLink(url.lastPathComponent)
    }

    let descriptor = url.path.withCString {
        open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw TrustedCandidateError.missingFile(url.lastPathComponent) }
    defer { close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
          (before.st_mode & S_IFMT) == S_IFREG,
          before.st_nlink == 1,
          before.st_size >= off_t(count),
          sameFileIdentity(before, visibleBefore)
    else {
        throw TrustedCandidateError.unsafeFileType(url.lastPathComponent)
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: count)
    while data.count < count {
        let remaining = count - data.count
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, remaining)
        }
        guard readCount >= 0 else {
            if errno == EINTR { continue }
            throw TrustedCandidateError.architectureMismatch
        }
        guard readCount > 0 else { throw TrustedCandidateError.architectureMismatch }
        data.append(contentsOf: buffer[0..<readCount])
    }

    var after = stat()
    var visibleAfter = stat()
    guard fstat(descriptor, &after) == 0,
          lstat(url.path, &visibleAfter) == 0,
          sameFileIdentity(before, after),
          sameFileIdentity(before, visibleAfter),
          after.st_size == before.st_size
    else {
        throw TrustedCandidateError.architectureMismatch
    }
    return data
}

private func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev &&
        lhs.st_ino == rhs.st_ino &&
        lhs.st_mode == rhs.st_mode &&
        lhs.st_nlink == rhs.st_nlink &&
        lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
        lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
