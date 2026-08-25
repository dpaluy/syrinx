import CryptoKit
import Darwin
import Foundation

public enum TrustedCandidateMaterializationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSourceLayout
    case destinationExists
    case destinationUnsafe
    case copyFailed(String)
    case cleanupFailed

    public var description: String {
        switch self {
        case .invalidSourceLayout:
            return "candidate source layout is invalid"
        case .destinationExists:
            return "candidate version already exists"
        case .destinationUnsafe:
            return "candidate destination is unsafe"
        case let .copyFailed(detail):
            return "candidate materialization failed: \(detail)"
        case .cleanupFailed:
            return "candidate materialization cleanup failed"
        }
    }
}

public struct TrustedMaterializedSourceIdentity: Equatable, Sendable {
    public let commit: String
    public let tag: String
    public let annotatedTag: Bool

    public init(commit: String, tag: String, annotatedTag: Bool) {
        self.commit = commit
        self.tag = tag
        self.annotatedTag = annotatedTag
    }
}

public final class TrustedMaterializedCandidateLease: @unchecked Sendable {
    private let tree: PinnedMaterializationTree
    private let lock = NSLock()

    fileprivate init(tree: PinnedMaterializationTree) {
        self.tree = tree
    }

    public func verifyStillValid() throws {
        lock.lock()
        defer { lock.unlock() }
        try tree.verify()
    }
}

public struct TrustedMaterializedCandidate: Sendable {
    public let version: String
    public let destination: URL
    public let metadataIdentityDigest: String
    public let manifestDigest: String
    public let sourceIdentity: TrustedMaterializedSourceIdentity
    public let lease: TrustedMaterializedCandidateLease

    fileprivate init(
        version: String,
        destination: URL,
        metadataIdentityDigest: String,
        manifestDigest: String,
        sourceIdentity: TrustedMaterializedSourceIdentity,
        lease: TrustedMaterializedCandidateLease
    ) {
        self.version = version
        self.destination = destination
        self.metadataIdentityDigest = metadataIdentityDigest
        self.manifestDigest = manifestDigest
        self.sourceIdentity = sourceIdentity
        self.lease = lease
    }
}

public struct TrustedCandidateMaterializer: Sendable {
    private let requirements: TrustedCandidateRequirements
    private let validator: TrustedCandidateValidator
    private let copyObserver: (@Sendable (Int) -> Void)?
    private let copyFailure: (@Sendable (Int) -> TrustedCandidateMaterializationError?)?
    private let directorySyncObserver: (@Sendable (String) -> Void)?
    private let stagingOpenObserver: (@Sendable (URL) -> Void)?
    private let cleanupSyncObserver: (@Sendable () -> Void)?
    private let postRenameFailure: (@Sendable () -> TrustedCandidateMaterializationError?)?
    private let validationTreeObserver: (@Sendable (URL) -> Void)?

    public init(
        requirements: TrustedCandidateRequirements,
        signatureEvaluator: TrustedCandidateSignatureEvaluator
    ) {
        self.requirements = requirements
        validator = TrustedCandidateValidator(
            requirements: requirements,
            signatureEvaluator: signatureEvaluator
        )
        copyObserver = nil
        copyFailure = nil
        directorySyncObserver = nil
        stagingOpenObserver = nil
        cleanupSyncObserver = nil
        postRenameFailure = nil
        validationTreeObserver = nil
    }

    internal init(
        requirements: TrustedCandidateRequirements,
        signatureEvaluator: TrustedCandidateSignatureEvaluator,
        copyObserver: (@Sendable (Int) -> Void)?,
        copyFailure: (@Sendable (Int) -> TrustedCandidateMaterializationError?)? = nil,
        directorySyncObserver: (@Sendable (String) -> Void)? = nil,
        stagingOpenObserver: (@Sendable (URL) -> Void)? = nil,
        cleanupSyncObserver: (@Sendable () -> Void)? = nil,
        postRenameFailure: (@Sendable () -> TrustedCandidateMaterializationError?)? = nil,
        validationTreeObserver: (@Sendable (URL) -> Void)? = nil
    ) {
        self.requirements = requirements
        validator = TrustedCandidateValidator(
            requirements: requirements,
            signatureEvaluator: signatureEvaluator
        )
        self.copyObserver = copyObserver
        self.copyFailure = copyFailure
        self.directorySyncObserver = directorySyncObserver
        self.stagingOpenObserver = stagingOpenObserver
        self.cleanupSyncObserver = cleanupSyncObserver
        self.postRenameFailure = postRenameFailure
        self.validationTreeObserver = validationTreeObserver
    }

    public func materialize(packageAt source: URL, dataRoot: URL) async throws -> TrustedMaterializedCandidate {
        try await materialize(source: source, kind: .package, dataRoot: dataRoot)
    }

    public func materialize(homebrewLibexecAt source: URL, dataRoot: URL) async throws -> TrustedMaterializedCandidate {
        try await materialize(source: source, kind: .homebrew, dataRoot: dataRoot)
    }

    private enum SourceKind {
        case package
        case homebrew
    }

    private func materialize(
        source: URL,
        kind: SourceKind,
        dataRoot: URL
    ) async throws -> TrustedMaterializedCandidate {
        try Task.checkCancellation()
        let validationWorkspace = try ValidationWorkspace(version: requirements.version)
        defer { validationWorkspace.cleanup() }
        let sourceURL = try validatedSourceURL(source, kind: kind)
        let sourceTree = try PinnedMaterializationTree(rootURL: sourceURL)
        let metadataData = try sourceTree.readData(
            relativePath: "metadata/release.json",
            maximumBytes: 256 * 1024
        )
        let metadata = try TrustedCandidateMetadata(data: metadataData)
        guard metadata.version == requirements.version else {
            throw TrustedCandidateError.metadataMismatch("version")
        }
        try validateSourceLayout(sourceURL, kind: kind, metadata: metadata)
        try sourceTree.verify()

        try Task.checkCancellation()
        let validationDestination = try OpenDirectory(path: validationWorkspace.versionDirectory, create: false)
        defer { validationDestination.close() }
        try sourceTree.copy(
            to: validationDestination.descriptor,
            checkCancellation: { try Task.checkCancellation() },
            sourceStillValid: { try sourceTree.verify() },
            observer: copyObserver,
            failure: copyFailure
        )
        try sourceTree.verify()
        try Task.checkCancellation()

        let validatedCandidate = try validator.validate(
            dataRoot: validationWorkspace.dataRoot,
            version: metadata.version
        )
        try validatedCandidate.lease.verifyStillValid()
        let validatedTree = try PinnedMaterializationTree(
            rootURL: validationWorkspace.versionDirectory,
            requireImmutableModes: true
        )
        try validatedTree.verify()
        validationTreeObserver?(validationWorkspace.versionDirectory)
        try sourceTree.verify()
        try validatedTree.verify()
        let sourceInventory = try sourceTree.refreshedInventory()
        let validationInventory = try validatedTree.refreshedInventory()
        guard sourceInventory == validationInventory else {
            throw TrustedCandidateMaterializationError.copyFailed("source validation inventory mismatch")
        }
        try sourceTree.verify()
        try validatedTree.verify()

        let destinationAuthority = try MaterializationDestination(
            dataRoot: dataRoot,
            directorySyncObserver: directorySyncObserver,
            stagingOpenObserver: stagingOpenObserver,
            cleanupSyncObserver: cleanupSyncObserver
        )
        defer { destinationAuthority.close() }
        try destinationAuthority.verify()
        try Task.checkCancellation()
        let stagingName = ".candidate-\(UUID().uuidString)"
        let staging = try destinationAuthority.createStaging(name: stagingName)
        var renamed = false
        var transferred = false
        defer {
            if !transferred { staging.close() }
        }
        do {
            try validatedCandidate.lease.verifyStillValid()
            try validatedTree.copy(
                to: staging.descriptor,
                checkCancellation: { try Task.checkCancellation() },
                sourceStillValid: {
                    try validatedCandidate.lease.verifyStillValid()
                    try validatedTree.verify()
                },
                observer: copyObserver,
                failure: copyFailure
            )
            try validatedCandidate.lease.verifyStillValid()
            try validatedTree.verify()
            try Task.checkCancellation()
            try staging.refreshIdentity()
            try staging.sync()
            try destinationAuthority.commit(staging: staging, stagingName: stagingName, version: metadata.version)
            renamed = true
            if let postRenameFailure,
               let failure = postRenameFailure()
            {
                throw failure
            }
            try staging.verify()
            try destinationAuthority.sync()
            let destinationLease = try destinationAuthority.makeLease()
            let destinationTree = try PinnedMaterializationTree(
                rootDirectory: staging,
                destinationAuthority: destinationLease,
                expectedInventory: validatedTree.inventory
            )
            try destinationTree.verify()
            let lease = TrustedMaterializedCandidateLease(tree: destinationTree)
            let result = TrustedMaterializedCandidate(
                version: metadata.version,
                destination: staging.path,
                metadataIdentityDigest: try validatedCandidate.metadata.identityDigest(),
                manifestDigest: validatedCandidate.manifestDigest,
                sourceIdentity: TrustedMaterializedSourceIdentity(
                    commit: validatedCandidate.metadata.source.commit,
                    tag: validatedCandidate.metadata.tag,
                    annotatedTag: validatedCandidate.metadata.source.annotatedTag
                ),
                lease: lease
            )
            transferred = true
            return result
        } catch let originalError {
            do {
                try destinationAuthority.removeOwnedNode(
                    named: renamed ? metadata.version : stagingName,
                    ownedBy: staging
                )
            } catch {
                throw TrustedCandidateMaterializationError.cleanupFailed
            }
            throw originalError
        }
    }

    private func validatedSourceURL(_ source: URL, kind: SourceKind) throws -> URL {
        guard source.isFileURL,
              source.path.hasPrefix("/"),
              source.path == source.standardizedFileURL.path,
              !source.path.contains("\0")
        else {
            throw TrustedCandidateMaterializationError.invalidSourceLayout
        }
        if kind == .homebrew, source.lastPathComponent != "libexec" {
            throw TrustedCandidateMaterializationError.invalidSourceLayout
        }
        return source
    }

    private func validateSourceLayout(
        _ source: URL,
        kind: SourceKind,
        metadata: TrustedCandidateMetadata
    ) throws {
        let components = source.path.split(separator: "/").map(String.init)
        switch kind {
        case .homebrew:
            guard components.last == "libexec" else {
                throw TrustedCandidateMaterializationError.invalidSourceLayout
            }
        case .package:
            let root = ["Library", "Application Support", metadata.productIdentity, "versions"]
            guard components.count >= root.count + 1,
                  Array(components.suffix(root.count + 1).dropLast()) == root
            else {
                throw TrustedCandidateMaterializationError.invalidSourceLayout
            }
        }
    }
}

private let materializationMaximumEntries = 4096
private let materializationMaximumDepth = 64
private let materializationMaximumFileBytes: UInt64 = 512 * 1024 * 1024
private let materializationMaximumTotalBytes: UInt64 = 1024 * 1024 * 1024

private struct MaterializationNodeIdentity: Equatable {
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
        size = UInt64(max(0, value.st_size))
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }

    func matchesDirectoryAuthority(_ other: MaterializationNodeIdentity) -> Bool {
        device == other.device &&
            inode == other.inode &&
            mode == other.mode
    }
}

internal func destinationDirectoryIdentityMatches(_ held: stat, _ visible: stat) -> Bool {
    MaterializationNodeIdentity(stat: held) == MaterializationNodeIdentity(stat: visible)
}

private final class PinnedDirectoryChain: @unchecked Sendable {
    private struct Node {
        let url: URL
        let descriptor: Int32
        let identity: MaterializationNodeIdentity
    }

    private let visibleRootURL: URL
    private let nodes: [Node]

    init(rootURL: URL) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              rootURL.path == rootURL.standardizedFileURL.path
        else { throw TrustedCandidateMaterializationError.invalidSourceLayout }

        let physicalRootURL = Self.physicalURL(rootURL)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw TrustedCandidateError.unsafePath("/") }
        var opened: [Node] = []
        var components = [String]()
        do {
            var rootInfo = stat()
            guard fstat(current, &rootInfo) == 0 else {
                throw TrustedCandidateError.unsafePath("/")
            }
            opened.append(Node(
                url: URL(fileURLWithPath: "/", isDirectory: true),
                descriptor: current,
                identity: MaterializationNodeIdentity(stat: rootInfo)
            ))
            for component in physicalRootURL.path.split(separator: "/").map(String.init) {
                components.append(component)
                var info = stat()
                guard component.withCString({ fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }),
                      (info.st_mode & S_IFMT) == S_IFDIR,
                      (info.st_mode & 0o022) == 0
                else { throw TrustedCandidateError.unsafePath(components.joined(separator: "/")) }
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else {
                    throw TrustedCandidateError.unsafePath(components.joined(separator: "/"))
                }
                let componentURL = URL(
                    fileURLWithPath: "/" + components.joined(separator: "/"),
                    isDirectory: true
                )
                opened.append(Node(
                    url: componentURL,
                    descriptor: next,
                    identity: MaterializationNodeIdentity(stat: info)
                ))
                current = next
            }
            guard let last = opened.last else { throw TrustedCandidateError.unsafePath(rootURL.path) }
            var visible = stat()
            guard lstat(rootURL.path, &visible) == 0,
                  MaterializationNodeIdentity(stat: visible) == last.identity
            else { throw TrustedCandidateError.unsafePath(rootURL.path) }
            self.visibleRootURL = rootURL
            self.nodes = opened
        } catch {
            for node in opened { close(node.descriptor) }
            if opened.isEmpty { close(current) }
            throw error
        }
    }

    var rootDescriptor: Int32 { nodes[nodes.count - 1].descriptor }

    func verify() throws {
        for (index, node) in nodes.enumerated() {
            var descriptorInfo = stat()
            var visibleInfo = stat()
            guard fstat(node.descriptor, &descriptorInfo) == 0,
                  lstat(node.url.path, &visibleInfo) == 0,
                  (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
                  (index == nodes.count - 1
                      ? MaterializationNodeIdentity(stat: descriptorInfo) == node.identity
                      : MaterializationNodeIdentity(stat: descriptorInfo).matchesDirectoryAuthority(node.identity)),
                  (index == nodes.count - 1
                      ? MaterializationNodeIdentity(stat: visibleInfo) == node.identity
                      : MaterializationNodeIdentity(stat: visibleInfo).matchesDirectoryAuthority(node.identity))
            else { throw TrustedCandidateError.unsafePath(node.url.path) }
        }
        guard let root = nodes.last else { throw TrustedCandidateError.unsafePath(visibleRootURL.path) }
        var visibleRoot = stat()
        guard lstat(visibleRootURL.path, &visibleRoot) == 0,
              MaterializationNodeIdentity(stat: visibleRoot) == root.identity
        else { throw TrustedCandidateError.unsafePath(visibleRootURL.path) }
    }

    private static func physicalURL(_ url: URL) -> URL {
        if url.path == "/var" || url.path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + url.path, isDirectory: true)
        }
        if url.path == "/tmp" || url.path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + url.path, isDirectory: true)
        }
        return url
    }

    deinit {
        for node in nodes { close(node.descriptor) }
    }
}

private struct MaterializationEntry {
    let relativePath: String
    let url: URL
    let descriptor: Int32
    let isDirectory: Bool
    let mode: mode_t
    let identity: MaterializationNodeIdentity
    let digest: String?
}

private struct MaterializationInventoryItem: Equatable {
    let relativePath: String
    let isDirectory: Bool
    let mode: mode_t
    let size: UInt64?
    let digest: String?
}

private final class PinnedMaterializationTree: @unchecked Sendable {
    private let rootURL: URL
    private let rootDescriptor: Int32
    private let directoryChain: PinnedDirectoryChain?
    private let rootAuthority: OpenDirectory?
    private let destinationAuthority: MaterializationDestinationLease?
    private let requireImmutableModes: Bool
    private var entries: [MaterializationEntry]

    convenience init(rootURL: URL, requireImmutableModes: Bool = false) throws {
        let chain = try PinnedDirectoryChain(rootURL: rootURL)
        try self.init(
            rootURL: rootURL,
            rootDescriptor: chain.rootDescriptor,
            directoryChain: chain,
            rootAuthority: nil,
            destinationAuthority: nil,
            requireImmutableModes: requireImmutableModes,
            expectedInventory: nil
        )
    }

    convenience init(
        rootDirectory: OpenDirectory,
        destinationAuthority: MaterializationDestinationLease,
        expectedInventory: [MaterializationInventoryItem]
    ) throws {
        try self.init(
            rootURL: rootDirectory.path,
            rootDescriptor: rootDirectory.descriptor,
            directoryChain: nil,
            rootAuthority: rootDirectory,
            destinationAuthority: destinationAuthority,
            requireImmutableModes: true,
            expectedInventory: expectedInventory
        )
    }

    private init(
        rootURL: URL,
        rootDescriptor: Int32,
        directoryChain: PinnedDirectoryChain?,
        rootAuthority: OpenDirectory?,
        destinationAuthority: MaterializationDestinationLease?,
        requireImmutableModes: Bool,
        expectedInventory: [MaterializationInventoryItem]?
    ) throws {
        self.rootURL = rootURL
        self.rootDescriptor = rootDescriptor
        self.directoryChain = directoryChain
        self.rootAuthority = rootAuthority
        self.destinationAuthority = destinationAuthority
        self.requireImmutableModes = requireImmutableModes
        self.entries = []
        var info = stat()
        var visible = stat()
        guard fstat(rootDescriptor, &info) == 0,
              lstat(rootURL.path, &visible) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              Self.modeIsAllowed(info.st_mode, requireImmutableModes: requireImmutableModes),
              MaterializationNodeIdentity(stat: info) == MaterializationNodeIdentity(stat: visible)
        else { throw TrustedCandidateError.unsafePath(rootURL.path) }
        var collected = [MaterializationEntry(
            relativePath: ".",
            url: rootURL,
            descriptor: rootDescriptor,
            isDirectory: true,
            mode: mode_t(info.st_mode & 0o7777),
            identity: MaterializationNodeIdentity(stat: info),
            digest: nil
        )]
        do {
            var totalBytes: UInt64 = 0
            try collect(
                directoryURL: rootURL,
                directoryDescriptor: rootDescriptor,
                relativePath: ".",
                depth: 0,
                entries: &collected,
                totalBytes: &totalBytes
            )
            if let expectedInventory {
                let actual = collected.map {
                    MaterializationInventoryItem(
                        relativePath: $0.relativePath,
                        isDirectory: $0.isDirectory,
                        mode: Self.immutableMode($0.mode),
                        size: $0.isDirectory ? nil : $0.identity.size,
                        digest: $0.digest
                    )
                }
                guard actual == expectedInventory else {
                    throw TrustedCandidateMaterializationError.copyFailed("destination inventory mismatch")
                }
            }
            entries = collected
        } catch {
            for entry in collected.dropFirst() { close(entry.descriptor) }
            throw error
        }
    }

    var inventory: [MaterializationInventoryItem] {
        entries.map {
            MaterializationInventoryItem(
                relativePath: $0.relativePath,
                isDirectory: $0.isDirectory,
                mode: Self.immutableMode($0.mode),
                size: $0.isDirectory ? nil : $0.identity.size,
                digest: $0.digest
            )
        }
    }

    func refreshedInventory() throws -> [MaterializationInventoryItem] {
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              Self.modeIsAllowed(rootInfo.st_mode, requireImmutableModes: requireImmutableModes)
        else {
            throw TrustedCandidateError.unsafePath(rootURL.path)
        }
        var collected = [MaterializationEntry(
            relativePath: ".",
            url: rootURL,
            descriptor: rootDescriptor,
            isDirectory: true,
            mode: mode_t(rootInfo.st_mode & 0o7777),
            identity: MaterializationNodeIdentity(stat: rootInfo),
            digest: nil
        )]
        do {
            var totalBytes: UInt64 = 0
            try collect(
                directoryURL: rootURL,
                directoryDescriptor: rootDescriptor,
                relativePath: ".",
                depth: 0,
                entries: &collected,
                totalBytes: &totalBytes
            )
            let inventory = collected.map {
                MaterializationInventoryItem(
                    relativePath: $0.relativePath,
                    isDirectory: $0.isDirectory,
                    mode: Self.immutableMode($0.mode),
                    size: $0.isDirectory ? nil : $0.identity.size,
                    digest: $0.digest
                )
            }
            for entry in collected.dropFirst() { close(entry.descriptor) }
            return inventory
        } catch {
            for entry in collected.dropFirst() { close(entry.descriptor) }
            throw error
        }
    }

    func readData(relativePath: String, maximumBytes: UInt64) throws -> Data {
        guard let entry = entries.first(where: { $0.relativePath == relativePath }),
              !entry.isDirectory,
              let expectedDigest = entry.digest,
              entry.identity.size <= maximumBytes
        else {
            throw TrustedCandidateError.missingFile(relativePath)
        }
        try verify()
        guard lseek(entry.descriptor, 0, SEEK_SET) >= 0 else {
            throw TrustedCandidateError.invalidMetadata
        }
        var result = Data()
        result.reserveCapacity(Int(entry.identity.size))
        var remaining = entry.identity.size
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let requested = min(UInt64(buffer.count), remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(entry.descriptor, bytes.baseAddress, Int(requested))
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw TrustedCandidateError.invalidMetadata
            }
            guard count > 0 else { throw TrustedCandidateError.invalidMetadata }
            result.append(contentsOf: buffer[0..<count])
            remaining -= UInt64(count)
        }
        guard digest(data: result) == expectedDigest else {
            throw TrustedCandidateError.digestMismatch
        }
        try verify()
        return result
    }

    func copy(
        to destination: Int32,
        checkCancellation: () throws -> Void,
        sourceStillValid: () throws -> Void,
        observer: (@Sendable (Int) -> Void)?,
        failure: (@Sendable (Int) -> TrustedCandidateMaterializationError?)?
    ) throws {
        var directoryDescriptors: [String: Int32] = [".": destination]
        defer {
            for (path, descriptor) in directoryDescriptors where path != "." {
                close(descriptor)
            }
        }
        let ordered = entries.dropFirst().sorted {
            let leftDepth = $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath.split(separator: "/").count
            return leftDepth == rightDepth ? $0.relativePath < $1.relativePath : leftDepth < rightDepth
        }
        var copiedFiles = 0
        for entry in ordered {
            try checkCancellation()
            try sourceStillValid()
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard let name = components.last,
                  !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.contains("/"),
                  !name.contains("\\")
            else {
                throw TrustedCandidateError.unsafePath(entry.relativePath)
            }
            let parentPath = components.dropLast().joined(separator: "/").isEmpty
                ? "."
                : components.dropLast().joined(separator: "/")
            guard let parent = directoryDescriptors[parentPath] else {
                throw TrustedCandidateError.unsafePath(entry.relativePath)
            }
            if entry.isDirectory {
                guard mkdirat(parent, name, mode_t(0o700)) == 0 else {
                    if errno == EEXIST { throw TrustedCandidateMaterializationError.destinationExists }
                    throw TrustedCandidateMaterializationError.copyFailed("mkdirat")
                }
                let child = name.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard child >= 0 else { throw TrustedCandidateMaterializationError.copyFailed("open destination directory") }
                var heldInfo = stat()
                var visibleInfo = stat()
                guard fstat(child, &heldInfo) == 0,
                      name.withCString({ fstatat(parent, $0, &visibleInfo, AT_SYMLINK_NOFOLLOW) == 0 }),
                      (heldInfo.st_mode & S_IFMT) == S_IFDIR,
                      destinationDirectoryIdentityMatches(heldInfo, visibleInfo)
                else {
                    close(child)
                    throw TrustedCandidateMaterializationError.copyFailed("destination directory identity")
                }
                directoryDescriptors[entry.relativePath] = child
                guard fsync(parent) == 0 else {
                    throw TrustedCandidateMaterializationError.copyFailed("fsync destination parent")
                }
            } else {
                let output = name.withCString {
                    let destinationMode = Self.immutableMode(entry.mode)
                    return openat(
                        parent,
                        $0,
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        destinationMode
                    )
                }
                guard output >= 0 else {
                    if errno == EEXIST { throw TrustedCandidateMaterializationError.destinationExists }
                    throw TrustedCandidateMaterializationError.copyFailed("open destination file")
                }
                do {
                    let destinationMode = Self.immutableMode(entry.mode)
                    guard fchmod(output, destinationMode) == 0,
                          lseek(entry.descriptor, 0, SEEK_SET) >= 0
                    else { throw TrustedCandidateMaterializationError.copyFailed("prepare file copy") }
                    try copyBytes(from: entry.descriptor, to: output, size: entry.identity.size, checkCancellation: checkCancellation, observer: observer)
                    guard fsync(output) == 0 else {
                        throw TrustedCandidateMaterializationError.copyFailed("fsync destination file")
                    }
                    var info = stat()
                    guard fstat(output, &info) == 0,
                          (info.st_mode & S_IFMT) == S_IFREG,
                          info.st_nlink == 1,
                          mode_t(info.st_mode & 0o7777) == destinationMode,
                          UInt64(info.st_size) == entry.identity.size,
                          try digest(descriptor: output, size: entry.identity.size) == entry.digest
                    else {
                        throw TrustedCandidateMaterializationError.copyFailed("destination file identity")
                    }
                } catch {
                    close(output)
                    throw error
                }
                close(output)
                copiedFiles += 1
                observer?(copiedFiles)
                if let failure = failure?(copiedFiles) { throw failure }
            }
        }
        let directories = entries.filter(\.isDirectory).sorted {
            let leftDepth = $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath.split(separator: "/").count
            return leftDepth > rightDepth
        }
        for entry in directories {
            guard let descriptor = directoryDescriptors[entry.relativePath],
                  fchmod(descriptor, Self.immutableMode(entry.mode)) == 0,
                  fsync(descriptor) == 0
            else {
                throw TrustedCandidateMaterializationError.copyFailed("fsync destination directory")
            }
        }
        guard let root = directoryDescriptors["."],
              fchmod(root, Self.immutableMode(entries[0].mode)) == 0,
              fsync(root) == 0
        else { throw TrustedCandidateMaterializationError.copyFailed("seal destination root") }
        try sourceStillValid()
    }

    func verify() throws {
        try directoryChain?.verify()
        try destinationAuthority?.verify()
        try rootAuthority?.verify()
        var totalBytes: UInt64 = 0
        for entry in entries {
            var descriptorInfo = stat()
            var visibleInfo = stat()
            guard fstat(entry.descriptor, &descriptorInfo) == 0,
                  lstat(entry.url.path, &visibleInfo) == 0,
                  MaterializationNodeIdentity(stat: descriptorInfo) == entry.identity,
                  MaterializationNodeIdentity(stat: visibleInfo) == entry.identity,
                  (descriptorInfo.st_mode & S_IFMT) == (entry.isDirectory ? S_IFDIR : S_IFREG),
                  Self.modeIsAllowed(descriptorInfo.st_mode, requireImmutableModes: requireImmutableModes)
            else {
                throw TrustedCandidateError.unsafePath(entry.relativePath)
            }
            if entry.isDirectory { continue }
            guard descriptorInfo.st_nlink == 1,
                  UInt64(descriptorInfo.st_size) <= materializationMaximumFileBytes,
                  let expected = entry.digest
            else {
                throw TrustedCandidateError.hardLink(entry.relativePath)
            }
            totalBytes += UInt64(descriptorInfo.st_size)
            guard totalBytes <= materializationMaximumTotalBytes,
                  try digest(descriptor: entry.descriptor, size: UInt64(descriptorInfo.st_size)) == expected
            else {
                throw TrustedCandidateError.digestMismatch
            }
        }
    }

    private func collect(
        directoryURL: URL,
        directoryDescriptor: Int32,
        relativePath: String,
        depth: Int,
        entries: inout [MaterializationEntry],
        totalBytes: inout UInt64
    ) throws {
        guard depth < materializationMaximumDepth,
              entries.count < materializationMaximumEntries
        else {
            throw TrustedCandidateError.unsafeFileType("candidate tree limit")
        }
        let names = try directoryNames(directoryDescriptor, maximum: materializationMaximumEntries - entries.count)
        for name in names {
            guard !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.contains("/"),
                  !name.contains("\\"),
                  !name.contains("\0")
            else {
                throw TrustedCandidateError.unsafePath(name)
            }
            guard entries.count < materializationMaximumEntries else {
                throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
            }
            let relative = relativePath == "." ? name : relativePath + "/" + name
            var visible = stat()
            guard name.withCString({ fstatat(directoryDescriptor, $0, &visible, AT_SYMLINK_NOFOLLOW) == 0 }) else {
                throw TrustedCandidateError.unsafePath(relative)
            }
            let type = visible.st_mode & S_IFMT
            if type == S_IFLNK { throw TrustedCandidateError.symbolicLink(relative) }
            guard type == S_IFDIR || type == S_IFREG else {
                throw TrustedCandidateError.unsafeFileType(relative)
            }
            let child = name.withCString {
                type == S_IFDIR
                    ? openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    : openat(directoryDescriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            }
            guard child >= 0 else { throw TrustedCandidateError.unsafePath(relative) }
            do {
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      MaterializationNodeIdentity(stat: opened) == MaterializationNodeIdentity(stat: visible),
                      Self.modeIsAllowed(opened.st_mode, requireImmutableModes: requireImmutableModes)
                else { throw TrustedCandidateError.unsafePath(relative) }
                let isDirectory = type == S_IFDIR
                if isDirectory {
                    entries.append(MaterializationEntry(
                        relativePath: relative,
                        url: directoryURL.appendingPathComponent(name, isDirectory: true),
                        descriptor: child,
                        isDirectory: true,
                        mode: mode_t(opened.st_mode & 0o7777),
                        identity: MaterializationNodeIdentity(stat: opened),
                        digest: nil
                    ))
                    try collect(
                        directoryURL: directoryURL.appendingPathComponent(name, isDirectory: true),
                        directoryDescriptor: child,
                        relativePath: relative,
                        depth: depth + 1,
                        entries: &entries,
                        totalBytes: &totalBytes
                    )
                } else {
                    guard opened.st_nlink == 1,
                          opened.st_size >= 0,
                          UInt64(opened.st_size) <= materializationMaximumFileBytes,
                          totalBytes + UInt64(opened.st_size) <= materializationMaximumTotalBytes
                    else { throw TrustedCandidateError.hardLink(relative) }
                    let fileDigest = try digest(descriptor: child, size: UInt64(opened.st_size))
                    totalBytes += UInt64(opened.st_size)
                    entries.append(MaterializationEntry(
                        relativePath: relative,
                        url: directoryURL.appendingPathComponent(name, isDirectory: false),
                        descriptor: child,
                        isDirectory: false,
                        mode: mode_t(opened.st_mode & 0o7777),
                        identity: MaterializationNodeIdentity(stat: opened),
                        digest: fileDigest
                    ))
                }
            } catch {
                close(child)
                throw error
            }
        }
    }

    private func directoryNames(_ descriptor: Int32, maximum: Int) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw TrustedCandidateError.unsafePath("candidate enumeration")
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    let bytes = UnsafeBufferPointer(start: $0, count: MemoryLayout.size(ofValue: entry.pointee.d_name))
                    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                    return String(decoding: bytes[..<end], as: UTF8.self)
                }
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximum else {
                throw TrustedCandidateError.unsafeFileType("candidate tree entry limit")
            }
            names.append(name)
        }
        guard errno == 0 else { throw TrustedCandidateError.unsafePath("candidate enumeration") }
        return names.sorted()
    }

    deinit {
        for entry in entries.dropFirst() { close(entry.descriptor) }
    }

    private static func immutableMode(_ mode: mode_t) -> mode_t {
        mode & mode_t(0o7555)
    }

    private static func modeIsAllowed(_ mode: mode_t, requireImmutableModes: Bool) -> Bool {
        (mode & 0o022) == 0 && (!requireImmutableModes || (mode & 0o222) == 0)
    }
}

private final class OpenDirectory: @unchecked Sendable {
    let descriptor: Int32
    private(set) var path: URL
    private(set) var identity: MaterializationNodeIdentity
    private var closed = false

    convenience init(path: URL, create: Bool) throws {
        try self.init(path: path, create: create, directorySyncObserver: nil)
    }

    init(
        path: URL,
        create: Bool,
        directorySyncObserver: (@Sendable (String) -> Void)?
    ) throws {
        let physicalPath = Self.physicalURL(path)
        let parent = physicalPath.deletingLastPathComponent()
        let logicalParent = path.deletingLastPathComponent()
        let name = physicalPath.lastPathComponent
        let parentDescriptor = try OpenDirectory.openAbsoluteDirectory(
            parent,
            create: create,
            directorySyncObserver: directorySyncObserver
        )
        defer { Darwin.close(parentDescriptor) }
        if create {
            let created = name.withCString { mkdirat(parentDescriptor, $0, mode_t(0o700)) == 0 }
            if created {
                guard fsync(parentDescriptor) == 0 else {
                    throw TrustedCandidateMaterializationError.copyFailed("fsync created directory parent")
                }
                directorySyncObserver?(logicalParent.path)
            } else {
                guard errno == EEXIST else {
                    throw TrustedCandidateMaterializationError.copyFailed("create directory")
                }
            }
        }
        let opened = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard opened >= 0 else { throw TrustedCandidateError.unsafePath(path.path) }
        var info = stat()
        guard fstat(opened, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR
        else {
            Darwin.close(opened)
            throw TrustedCandidateError.unsafePath(path.path)
        }
        descriptor = opened
        self.path = path.standardizedFileURL
        identity = MaterializationNodeIdentity(stat: info)
    }

    fileprivate init(descriptor: Int32, path: URL, identity: MaterializationNodeIdentity) {
        self.descriptor = descriptor
        self.path = path.standardizedFileURL
        self.identity = identity
    }

    private static func physicalURL(_ path: URL) -> URL {
        if path.path == "/var" || path.path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + path.path, isDirectory: true)
        }
        if path.path == "/tmp" || path.path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path.path, isDirectory: true)
        }
        return path
    }

    private static func openAbsoluteDirectory(
        _ path: URL,
        create: Bool,
        directorySyncObserver: (@Sendable (String) -> Void)?
    ) throws -> Int32 {
        guard path.path.hasPrefix("/") else { throw TrustedCandidateError.unsafePath(path.path) }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw TrustedCandidateError.unsafePath("/") }
        for component in path.path.split(separator: "/").map(String.init) {
            var info = stat()
            let found = component.withCString { fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }
            if !found {
                guard create, errno == ENOENT else {
                    Darwin.close(current)
                    throw TrustedCandidateError.unsafePath(path.path)
                }
                let created = component.withCString { mkdirat(current, $0, mode_t(0o700)) == 0 }
                guard created || errno == EEXIST
                else {
                    Darwin.close(current)
                    throw TrustedCandidateError.unsafePath(path.path)
                }
                if created {
                    guard fsync(current) == 0 else {
                        Darwin.close(current)
                        throw TrustedCandidateMaterializationError.copyFailed("fsync created directory parent")
                    }
                    directorySyncObserver?(path.path)
                }
                guard component.withCString({ fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }) else {
                    Darwin.close(current)
                    throw TrustedCandidateError.unsafePath(path.path)
                }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(current)
                throw TrustedCandidateError.unsafePath(path.path)
            }
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw TrustedCandidateError.unsafePath(path.path)
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    func verify() throws {
        var descriptorInfo = stat()
        var visibleInfo = stat()
        guard !closed,
              fstat(descriptor, &descriptorInfo) == 0,
              lstat(path.path, &visibleInfo) == 0,
              (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
              MaterializationNodeIdentity(stat: descriptorInfo) == identity,
              MaterializationNodeIdentity(stat: visibleInfo) == identity
        else { throw TrustedCandidateMaterializationError.destinationUnsafe }
    }

    func duplicated() throws -> OpenDirectory {
        guard !closed else { throw TrustedCandidateMaterializationError.destinationUnsafe }
        let copy = dup(descriptor)
        guard copy >= 0 else { throw TrustedCandidateMaterializationError.destinationUnsafe }
        return OpenDirectory(descriptor: copy, path: path, identity: identity)
    }

    func updatePath(_ newPath: URL) {
        path = newPath.standardizedFileURL
    }

    func refreshIdentity() throws {
        var info = stat()
        guard !closed,
              fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR
        else { throw TrustedCandidateMaterializationError.destinationUnsafe }
        identity = MaterializationNodeIdentity(stat: info)
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    deinit { close() }

    func sync() throws {
        guard fsync(descriptor) == 0 else {
            throw TrustedCandidateMaterializationError.copyFailed("fsync directory")
        }
    }
}

private final class MaterializationDestinationLease: @unchecked Sendable {
    private let root: OpenDirectory
    private let service: OpenDirectory
    private let versions: OpenDirectory

    init(root: OpenDirectory, service: OpenDirectory, versions: OpenDirectory) {
        self.root = root
        self.service = service
        self.versions = versions
    }

    func verify() throws {
        try root.verify()
        try service.verify()
        try versions.verify()
    }
}

private final class MaterializationDestination: @unchecked Sendable {
    private let dataRoot: URL
    private let root: OpenDirectory
    private let service: OpenDirectory
    private let versions: OpenDirectory
    private let stagingOpenObserver: (@Sendable (URL) -> Void)?
    private let cleanupSyncObserver: (@Sendable () -> Void)?

    init(
        dataRoot: URL,
        directorySyncObserver: (@Sendable (String) -> Void)? = nil,
        stagingOpenObserver: (@Sendable (URL) -> Void)? = nil,
        cleanupSyncObserver: (@Sendable () -> Void)? = nil
    ) throws {
        guard dataRoot.isFileURL,
              dataRoot.path.hasPrefix("/"),
              dataRoot.path == dataRoot.standardizedFileURL.path
        else { throw TrustedCandidateMaterializationError.destinationUnsafe }
        self.dataRoot = dataRoot
        self.stagingOpenObserver = stagingOpenObserver
        self.cleanupSyncObserver = cleanupSyncObserver
        let root = try OpenDirectory(path: dataRoot, create: false)
        let serviceURL = dataRoot.appendingPathComponent("service", isDirectory: true)
        let versionsURL = serviceURL.appendingPathComponent("versions", isDirectory: true)
        do {
            self.root = root
            service = try OpenDirectory(
                path: serviceURL,
                create: true,
                directorySyncObserver: directorySyncObserver
            )
            versions = try OpenDirectory(
                path: versionsURL,
                create: true,
                directorySyncObserver: directorySyncObserver
            )
            try root.refreshIdentity()
            try service.refreshIdentity()
        } catch {
            root.close()
            throw error
        }
    }

    func verify() throws {
        try root.verify()
        try service.verify()
        try versions.verify()
    }

    func makeLease() throws -> MaterializationDestinationLease {
        try verify()
        return try MaterializationDestinationLease(
            root: root.duplicated(),
            service: service.duplicated(),
            versions: versions.duplicated()
        )
    }

    func createStaging(name: String) throws -> OpenDirectory {
        guard name.hasPrefix(".candidate-"), !name.contains("/"), !name.contains("\\") else {
            throw TrustedCandidateMaterializationError.destinationUnsafe
        }
        guard name.withCString({ mkdirat(versions.descriptor, $0, mode_t(0o700)) == 0 }) else {
            throw TrustedCandidateMaterializationError.copyFailed("create staging")
        }
        var createdInfo = stat()
        var createdIdentity: MaterializationNodeIdentity?
        let path = dataRoot
            .appendingPathComponent("service/versions", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        var opened: Int32 = -1
        do {
            guard name.withCString({ fstatat(versions.descriptor, $0, &createdInfo, AT_SYMLINK_NOFOLLOW) == 0 }),
                  (createdInfo.st_mode & S_IFMT) == S_IFDIR
            else {
                throw TrustedCandidateMaterializationError.copyFailed("inspect staging")
            }
            createdIdentity = MaterializationNodeIdentity(stat: createdInfo)
            guard fsync(versions.descriptor) == 0 else {
                throw TrustedCandidateMaterializationError.copyFailed("fsync staging parent")
            }
            stagingOpenObserver?(path)
            opened = name.withCString {
                openat(versions.descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard opened >= 0 else {
                throw TrustedCandidateMaterializationError.copyFailed("open staging")
            }
            var heldInfo = stat()
            var visibleInfo = stat()
            guard fstat(opened, &heldInfo) == 0,
                  name.withCString({ fstatat(versions.descriptor, $0, &visibleInfo, AT_SYMLINK_NOFOLLOW) == 0 }),
                  MaterializationNodeIdentity(stat: heldInfo) == MaterializationNodeIdentity(stat: visibleInfo),
                  MaterializationNodeIdentity(stat: heldInfo) == createdIdentity
            else {
                throw TrustedCandidateMaterializationError.destinationUnsafe
            }
            let staging = OpenDirectory(descriptor: opened, path: path, identity: MaterializationNodeIdentity(stat: heldInfo))
            opened = -1
            try versions.refreshIdentity()
            return staging
        } catch {
            if opened >= 0 { Darwin.close(opened) }
            do {
                var visibleInfo = stat()
                guard let createdIdentity,
                      name.withCString({ fstatat(versions.descriptor, $0, &visibleInfo, AT_SYMLINK_NOFOLLOW) == 0 }),
                      MaterializationNodeIdentity(stat: visibleInfo) == createdIdentity,
                      name.withCString({ unlinkat(versions.descriptor, $0, AT_REMOVEDIR) == 0 }),
                      fsync(versions.descriptor) == 0
                else { throw TrustedCandidateMaterializationError.cleanupFailed }
                cleanupSyncObserver?()
            } catch {
                throw TrustedCandidateMaterializationError.cleanupFailed
            }
            throw error
        }
    }

    func commit(staging: OpenDirectory, stagingName: String, version: String) throws {
        try verify()
        try staging.verify()
        guard ServiceVersionedLayout.isSafeVersion(version) else {
            throw TrustedCandidateMaterializationError.destinationUnsafe
        }
        var existing = stat()
        if version.withCString({ fstatat(versions.descriptor, $0, &existing, AT_SYMLINK_NOFOLLOW) == 0 }) {
            throw TrustedCandidateMaterializationError.destinationExists
        }
        guard errno == ENOENT else { throw TrustedCandidateMaterializationError.destinationUnsafe }
        guard renameatx_np(
            versions.descriptor,
            stagingName,
            versions.descriptor,
            version,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { throw TrustedCandidateMaterializationError.destinationExists }
            throw TrustedCandidateMaterializationError.copyFailed("atomic rename")
        }
        staging.updatePath(
            dataRoot
                .appendingPathComponent("service/versions", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
        )
        try staging.refreshIdentity()
        try versions.refreshIdentity()
    }

    func sync() throws {
        guard fsync(versions.descriptor) == 0,
              fsync(service.descriptor) == 0,
              fsync(root.descriptor) == 0
        else { throw TrustedCandidateMaterializationError.copyFailed("fsync destination parents") }
    }

    func removeOwnedNode(named name: String, ownedBy expected: OpenDirectory) throws {
        try verify()
        try expected.verify()
        var visible = stat()
        guard name.withCString({ fstatat(versions.descriptor, $0, &visible, AT_SYMLINK_NOFOLLOW) == 0 }),
              MaterializationNodeIdentity(stat: visible) == expected.identity
        else { throw TrustedCandidateMaterializationError.cleanupFailed }
        try removeNode(parent: versions.descriptor, name: name)
        guard fsync(versions.descriptor) == 0 else {
            throw TrustedCandidateMaterializationError.cleanupFailed
        }
        cleanupSyncObserver?()
    }

    private func removeNode(parent: Int32, name: String) throws {
        var info = stat()
        guard name.withCString({ fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }) else {
            if errno == ENOENT { return }
            throw TrustedCandidateMaterializationError.cleanupFailed
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK || (type != S_IFDIR && type != S_IFREG) {
            throw TrustedCandidateMaterializationError.cleanupFailed
        }
        if type == S_IFREG {
            guard info.st_nlink == 1,
                  name.withCString({ unlinkat(parent, $0, 0) == 0 })
            else { throw TrustedCandidateMaterializationError.cleanupFailed }
            return
        }
        let directory = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directory >= 0 else { throw TrustedCandidateMaterializationError.cleanupFailed }
        defer { Darwin.close(directory) }
        guard fchmod(directory, mode_t(0o700)) == 0 else {
            throw TrustedCandidateMaterializationError.cleanupFailed
        }
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw TrustedCandidateMaterializationError.cleanupFailed
        }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let child = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    let bytes = UnsafeBufferPointer(start: $0, count: MemoryLayout.size(ofValue: entry.pointee.d_name))
                    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                    return String(decoding: bytes[..<end], as: UTF8.self)
                }
            }
            if child != "." && child != ".." { names.append(child) }
        }
        let readError = errno
        closedir(stream)
        guard readError == 0 else { throw TrustedCandidateMaterializationError.cleanupFailed }
        for child in names { try removeNode(parent: directory, name: child) }
        guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) == 0 }) else {
            throw TrustedCandidateMaterializationError.cleanupFailed
        }
    }

    func close() {
        root.close()
        service.close()
        versions.close()
    }
}

private final class ValidationWorkspace {
    let root: URL
    let dataRoot: URL
    let versionDirectory: URL

    init(version: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t50c2a-validation-\(UUID().uuidString)", isDirectory: true)
        dataRoot = root.appendingPathComponent("data", isDirectory: true)
        versionDirectory = dataRoot
            .appendingPathComponent("service", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        chmod(root.path, mode_t(0o700))
        chmod(dataRoot.path, mode_t(0o700))
        chmod(dataRoot.appendingPathComponent("service").path, mode_t(0o700))
        chmod(dataRoot.appendingPathComponent("service/versions").path, mode_t(0o700))
        chmod(versionDirectory.path, mode_t(0o700))
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
}

private func copyBytes(
    from source: Int32,
    to destination: Int32,
    size: UInt64,
    checkCancellation: () throws -> Void,
    observer: (@Sendable (Int) -> Void)?
) throws {
    var remaining = size
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while remaining > 0 {
        try checkCancellation()
        let requested = min(UInt64(buffer.count), remaining)
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(source, bytes.baseAddress, Int(requested))
        }
        guard readCount >= 0 else {
            if errno == EINTR { continue }
            throw TrustedCandidateMaterializationError.copyFailed("read source")
        }
        guard readCount > 0 else { throw TrustedCandidateMaterializationError.copyFailed("short source") }
        var written = 0
        while written < readCount {
            let writeCount = buffer.withUnsafeBytes { bytes in
                Darwin.write(destination, bytes.baseAddress!.advanced(by: written), readCount - written)
            }
            guard writeCount >= 0 else {
                if errno == EINTR { continue }
                throw TrustedCandidateMaterializationError.copyFailed("write destination")
            }
            guard writeCount > 0 else { throw TrustedCandidateMaterializationError.copyFailed("short destination") }
            written += writeCount
        }
        remaining -= UInt64(readCount)
        observer?(Int(size - remaining))
    }
}

private func digest(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func digest(descriptor: Int32, size: UInt64) throws -> String {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw TrustedCandidateError.invalidMetadata }
    var hasher = SHA256()
    var remaining = size
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while remaining > 0 {
        let requested = min(UInt64(buffer.count), remaining)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, Int(requested))
        }
        guard count >= 0 else {
            if errno == EINTR { continue }
            throw TrustedCandidateError.invalidMetadata
        }
        guard count > 0 else { throw TrustedCandidateError.invalidMetadata }
        buffer.withUnsafeBytes { bytes in
            hasher.update(data: Data(bytes: bytes.baseAddress!.advanced(by: 0), count: count))
        }
        remaining -= UInt64(count)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
