import CryptoKit
import Darwin
import Foundation

public enum ModelInstallerError: Error, Equatable, Sendable, CustomStringConvertible {
    case manifestInvalid
    case unsafePartial
    case partialIsSymlink
    case partialIsNotRegular
    case partialSizeExceedsManifest
    case responseStatus(Int)
    case invalidContentRange
    case wrongContentLength
    case truncatedResponse
    case responseOverrun
    case timeout
    case connectionLost
    case cancelled
    case hashMismatch
    case diskFull
    case verificationFailed
    case targetConflict
    case directoryOperationFailed
    case stateUpdateFailed

    public var description: String {
        switch self {
        case .manifestInvalid:
            return "model manifest is not valid"
        case .unsafePartial:
            return "model partial download tree is unsafe"
        case .partialIsSymlink:
            return "model partial download tree contains a symlink"
        case .partialIsNotRegular:
            return "model partial download file is not regular"
        case .partialSizeExceedsManifest:
            return "model partial download is larger than the manifest file"
        case let .responseStatus(status):
            return "model download returned HTTP status \(status)"
        case .invalidContentRange:
            return "model download returned an invalid content range"
        case .wrongContentLength:
            return "model download returned the wrong content length"
        case .truncatedResponse:
            return "model download response ended before the expected size"
        case .responseOverrun:
            return "model download response exceeded the expected size"
        case .timeout:
            return "model download timed out"
        case .connectionLost:
            return "model download connection was lost"
        case .cancelled:
            return "model download was cancelled"
        case .hashMismatch:
            return "model download has the wrong SHA-256"
        case .diskFull:
            return "model download or state write ran out of disk space"
        case .verificationFailed:
            return "downloaded model tree failed verification"
        case .targetConflict:
            return "verified model revision target conflicts with existing data"
        case .directoryOperationFailed:
            return "model download directory operation failed"
        case .stateUpdateFailed:
            return "model installed or selection state could not be updated"
        }
    }
}

public protocol ModelDiskSpaceProvider: Sendable {
    func availableBytes(at root: URL) throws -> Int64
}

public struct FileSystemDiskSpaceProvider: ModelDiskSpaceProvider {
    public init() {}

    public func availableBytes(at root: URL) throws -> Int64 {
        var info = statfs()
        guard statfs(root.path, &info) == 0 else {
            throw ModelInstallerError.directoryOperationFailed
        }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}

public struct FixedDiskSpaceProvider: ModelDiskSpaceProvider {
    public let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = bytes
    }

    public func availableBytes(at root: URL) throws -> Int64 { bytes }
}

public struct ModelInstallResult: Equatable, Sendable {
    public let immutableCommit: String
    public let activated: Bool

    public init(immutableCommit: String, activated: Bool) {
        self.immutableCommit = immutableCommit
        self.activated = activated
    }
}

public struct ModelInstallPreflight: Equatable, Sendable {
    public let totalBytes: Int64
    public let remainingBytes: Int64
    public let safetyAllowance: Int64
    public let requiredBytes: Int64
    public let availableBytes: Int64

    public init(
        totalBytes: Int64,
        remainingBytes: Int64,
        safetyAllowance: Int64,
        requiredBytes: Int64,
        availableBytes: Int64
    ) {
        self.totalBytes = totalBytes
        self.remainingBytes = remainingBytes
        self.safetyAllowance = safetyAllowance
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }
}

internal struct ModelStagingAccessEvent: Sendable, Equatable {
    let relativePath: String
    let phase: ModelStagingAccessPhase
}

internal enum ModelStagingAccessPhase: String, Sendable, Equatable {
    case beforeOpen
    case beforeVerify
    case afterVerify
    case beforeCommit
    case afterCommit
    case beforeParentSync
}

internal typealias ModelStagingAccessHook = @Sendable (ModelStagingAccessEvent) -> Void
internal typealias ModelPostRenameSyncHook = @Sendable () throws -> Void

private final class DescriptorRelativeStagingSession: @unchecked Sendable {
    private let rootDescriptor: Int32
    private let downloadsDescriptor: Int32
    private let revisionsDescriptor: Int32
    private var partialDescriptor: Int32
    private var repositoryDescriptor: Int32
    private let partialName: String
    private let accessHook: ModelStagingAccessHook?
    private let postRenameSyncHook: ModelPostRenameSyncHook?

    init(
        store: ModelStore,
        immutableCommit: String,
        accessHook: ModelStagingAccessHook?,
        postRenameSyncHook: ModelPostRenameSyncHook?
    ) throws {
        self.accessHook = accessHook
        self.postRenameSyncHook = postRenameSyncHook
        self.partialName = "\(immutableCommit).partial"

        let rootDescriptor = Self.openDirectory(at: store.root)
        guard rootDescriptor >= 0 else { throw ModelInstallerError.directoryOperationFailed }
        self.rootDescriptor = rootDescriptor
        var openedDescriptors: [Int32] = []
        var keepDescriptors = false
        defer {
            if !keepDescriptors {
                openedDescriptors.reversed().forEach { close($0) }
                close(rootDescriptor)
            }
        }
        do {
            let downloadsDescriptor = try Self.openOrCreateDirectory(
                parent: rootDescriptor,
                name: "downloads",
                relativePath: "downloads",
                hook: accessHook
            )
            openedDescriptors.append(downloadsDescriptor)
            let modelsDescriptor = try Self.openOrCreateDirectory(
                parent: rootDescriptor,
                name: "models",
                relativePath: "models",
                hook: accessHook
            )
            openedDescriptors.append(modelsDescriptor)
            let revisionsDescriptor: Int32
            do {
                revisionsDescriptor = try Self.openOrCreateDirectory(
                    parent: modelsDescriptor,
                    name: "revisions",
                    relativePath: "models/revisions",
                    hook: accessHook
                )
            } catch {
                throw error
            }
            openedDescriptors.append(revisionsDescriptor)
            close(modelsDescriptor)
            openedDescriptors.remove(at: 1)
            self.partialDescriptor = try Self.openOrCreateDirectory(
                parent: downloadsDescriptor,
                name: partialName,
                relativePath: partialName,
                hook: accessHook
            )
            openedDescriptors.append(partialDescriptor)
            self.repositoryDescriptor = try Self.openOrCreateDirectory(
                parent: partialDescriptor,
                name: ModelManifest.supportedRepositoryFolder,
                relativePath: "\(partialName)/\(ModelManifest.supportedRepositoryFolder)",
                hook: accessHook
            )
            openedDescriptors.append(repositoryDescriptor)
            self.downloadsDescriptor = downloadsDescriptor
            self.revisionsDescriptor = revisionsDescriptor
            keepDescriptors = true
        } catch {
            throw error
        }
    }

    deinit {
        if repositoryDescriptor >= 0 { close(repositoryDescriptor) }
        if partialDescriptor >= 0 { close(partialDescriptor) }
        close(revisionsDescriptor)
        close(downloadsDescriptor)
        close(rootDescriptor)
    }

    func remainingBytes(for files: [ModelManifest.File]) throws -> Int64 {
        var result: Int64 = 0
        for file in files {
            let info = try existingFileInfo(for: file.relativePath)
            guard info.size <= file.size else { throw ModelInstallerError.partialSizeExceedsManifest }
            let missing: Int64
            if info.size == file.size {
                missing = try fileHash(for: file.relativePath) == file.sha256 ? 0 : file.size
            } else {
                missing = file.size - info.size
            }
            let (next, overflow) = result.addingReportingOverflow(missing)
            guard !overflow else { throw ModelInstallerError.diskFull }
            result = next
        }
        return result
    }

    func existingFileInfo(for relativePath: String) throws -> (exists: Bool, size: Int64) {
        guard let descriptor = try openFile(
            relativePath: relativePath,
            flags: O_RDONLY,
            offset: nil,
            create: false,
            allowMissing: true
        ) else {
            return (false, 0)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ModelInstallerError.unsafePartial }
        return (true, Int64(info.st_size))
    }

    func fileHash(for relativePath: String) throws -> String {
        guard let descriptor = try openFile(
            relativePath: relativePath,
            flags: O_RDONLY,
            offset: nil,
            create: false,
            allowMissing: false
        ) else {
            throw ModelInstallerError.partialIsNotRegular
        }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else { throw ModelInstallerError.partialIsNotRegular }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func truncateFile(for relativePath: String, to size: Int64) throws {
        guard let descriptor = try openFile(
            relativePath: relativePath,
            flags: O_WRONLY,
            offset: nil,
            create: false,
            allowMissing: false
        ) else { throw ModelInstallerError.partialIsNotRegular }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0 else {
            throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.partialIsNotRegular
        }
    }

    func openDownloadFile(for relativePath: String, appendFrom offset: Int64) throws -> Int32 {
        guard let descriptor = try openFile(
            relativePath: relativePath,
            flags: O_RDWR,
            offset: offset,
            create: true,
            allowMissing: false
        ) else { throw ModelInstallerError.partialIsNotRegular }
        if offset == 0 {
            guard ftruncate(descriptor, 0) == 0 else {
                close(descriptor)
                throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.partialIsNotRegular
            }
        }
        guard lseek(descriptor, off_t(offset), SEEK_SET) == offset else {
            close(descriptor)
            throw ModelInstallerError.partialIsNotRegular
        }
        return descriptor
    }

    func syncTree() throws {
        try syncDirectoryDescriptor(partialDescriptor)
    }

    func verify(manifest: ModelManifest, verifier: ModelVerifier) throws {
        try verifyIdentity()
        accessHook?(ModelStagingAccessEvent(relativePath: ModelManifest.supportedRepositoryFolder, phase: .beforeVerify))
        try verifyIdentity()
        try verifier.verify(files: manifest.files.map(\.expectation), descriptor: repositoryDescriptor)
        accessHook?(ModelStagingAccessEvent(relativePath: ModelManifest.supportedRepositoryFolder, phase: .afterVerify))
        try verifyIdentity()
    }

    func commit(to immutableCommit: String) throws {
        accessHook?(ModelStagingAccessEvent(relativePath: partialName, phase: .beforeCommit))
        try verifyIdentity()
        guard renameatx_np(
            downloadsDescriptor,
            partialName,
            revisionsDescriptor,
            immutableCommit,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { throw ModelInstallerError.targetConflict }
            if errno == ENOSPC { throw ModelInstallerError.diskFull }
            throw ModelInstallerError.directoryOperationFailed
        }
        accessHook?(ModelStagingAccessEvent(relativePath: immutableCommit, phase: .afterCommit))
    }

    func syncCommitParents() throws {
        accessHook?(ModelStagingAccessEvent(relativePath: partialName, phase: .beforeParentSync))
        do {
            try postRenameSyncHook?()
        } catch {
            throw ModelInstallerError.directoryOperationFailed
        }
        guard fsync(revisionsDescriptor) == 0, fsync(downloadsDescriptor) == 0 else {
            throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.directoryOperationFailed
        }
    }

    func verifyIdentity() throws {
        try Self.verifyIdentity(descriptor: partialDescriptor, parent: downloadsDescriptor, name: partialName)
        try Self.verifyIdentity(
            descriptor: repositoryDescriptor,
            parent: partialDescriptor,
            name: ModelManifest.supportedRepositoryFolder
        )
    }

    func removeCommittedTarget(_ immutableCommit: String) throws {
        try Self.verifyIdentity(descriptor: partialDescriptor, parent: revisionsDescriptor, name: immutableCommit)
        try removeDirectoryContents(partialDescriptor)
        close(repositoryDescriptor)
        repositoryDescriptor = -1
        close(partialDescriptor)
        partialDescriptor = -1
        guard unlinkat(revisionsDescriptor, immutableCommit, AT_REMOVEDIR) == 0 else {
            throw ModelInstallerError.directoryOperationFailed
        }
    }

    private func openFile(
        relativePath: String,
        flags: Int32,
        offset: Int64?,
        create: Bool,
        allowMissing: Bool
    ) throws -> Int32? {
        let components = try pathComponents(relativePath)
        guard let name = components.last else { throw ModelInstallerError.unsafePartial }
        let parent = try openParentDirectory(components.dropLast(), relativePath: relativePath)
        defer { close(parent) }

        var inspected = stat()
        let inspectedResult = fstatat(parent, name, &inspected, AT_SYMLINK_NOFOLLOW)
        let exists: Bool
        if inspectedResult == 0 {
            exists = true
            let type = inspected.st_mode & S_IFMT
            if type == S_IFLNK { throw ModelInstallerError.partialIsSymlink }
            guard type == S_IFREG else { throw ModelInstallerError.partialIsNotRegular }
        } else if errno == ENOENT {
            exists = false
        } else {
            throw ModelInstallerError.unsafePartial
        }
        accessHook?(ModelStagingAccessEvent(relativePath: relativePath, phase: .beforeOpen))

        let descriptor: Int32
        if create && !exists {
            descriptor = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        } else {
            descriptor = openat(parent, name, (create ? O_RDWR : flags) | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT && allowMissing { return nil }
            if errno == ELOOP { throw ModelInstallerError.partialIsSymlink }
            throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.unsafePartial
        }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1
        else {
            close(descriptor)
            throw ModelInstallerError.partialIsNotRegular
        }
        guard !exists || Self.sameIdentity(inspected, opened) else {
            close(descriptor)
            throw ModelInstallerError.unsafePartial
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            throw ModelInstallerError.unsafePartial
        }
        if let offset {
            guard Int64(opened.st_size) == offset else {
                close(descriptor)
                throw ModelInstallerError.partialIsNotRegular
            }
        }
        return descriptor
    }

    private func openParentDirectory(
        _ components: ArraySlice<String>,
        relativePath: String
    ) throws -> Int32 {
        var current = dup(repositoryDescriptor)
        guard current >= 0 else { throw ModelInstallerError.unsafePartial }
        var prefix: [String] = []
        do {
            for component in components {
                prefix.append(component)
                var inspected = stat()
                let result = fstatat(current, component, &inspected, AT_SYMLINK_NOFOLLOW)
                if result != 0 {
                    guard errno == ENOENT, mkdirat(current, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                        throw ModelInstallerError.directoryOperationFailed
                    }
                    guard fstatat(current, component, &inspected, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw ModelInstallerError.unsafePartial
                    }
                }
                guard (inspected.st_mode & S_IFMT) == S_IFDIR else {
                    if (inspected.st_mode & S_IFMT) == S_IFLNK { throw ModelInstallerError.partialIsSymlink }
                    throw ModelInstallerError.partialIsNotRegular
                }
                accessHook?(ModelStagingAccessEvent(relativePath: prefix.joined(separator: "/"), phase: .beforeOpen))
                let child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else {
                    if errno == ELOOP { throw ModelInstallerError.partialIsSymlink }
                    throw ModelInstallerError.unsafePartial
                }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      (opened.st_mode & S_IFMT) == S_IFDIR,
                      Self.sameIdentity(inspected, opened)
                else {
                    close(child)
                    throw ModelInstallerError.unsafePartial
                }
                close(current)
                current = child
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private func syncDirectoryDescriptor(_ descriptor: Int32) throws {
        for name in try directoryEntries(descriptor) {
            var inspected = stat()
            guard fstatat(descriptor, name, &inspected, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ModelInstallerError.unsafePartial
            }
            let type = inspected.st_mode & S_IFMT
            if type == S_IFLNK { throw ModelInstallerError.partialIsSymlink }
            if type == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw ModelInstallerError.unsafePartial }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      Self.sameIdentity(inspected, opened),
                      (opened.st_mode & 0o077) == 0 || fchmod(child, mode_t(0o700)) == 0
                else { throw ModelInstallerError.unsafePartial }
                try syncDirectoryDescriptor(child)
                guard fsync(child) == 0 else {
                    throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.directoryOperationFailed
                }
            } else if type == S_IFREG {
                let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW)
                guard child >= 0 else { throw ModelInstallerError.unsafePartial }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      Self.sameIdentity(inspected, opened),
                      opened.st_nlink == 1
                else { throw ModelInstallerError.unsafePartial }
                guard fsync(child) == 0 else {
                    throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.directoryOperationFailed
                }
            } else {
                throw ModelInstallerError.unsafePartial
            }
        }
        guard fsync(descriptor) == 0 else {
            throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.directoryOperationFailed
        }
    }

    private func removeDirectoryContents(_ descriptor: Int32) throws {
        for name in try directoryEntries(descriptor) {
            var inspected = stat()
            guard fstatat(descriptor, name, &inspected, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ModelInstallerError.directoryOperationFailed
            }
            let type = inspected.st_mode & S_IFMT
            if type == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw ModelInstallerError.directoryOperationFailed }
                var opened = stat()
                guard fstat(child, &opened) == 0, Self.sameIdentity(inspected, opened) else {
                    close(child)
                    throw ModelInstallerError.directoryOperationFailed
                }
                try removeDirectoryContents(child)
                close(child)
                guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                    throw ModelInstallerError.directoryOperationFailed
                }
            } else if type == S_IFREG {
                let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW)
                guard child >= 0 else { throw ModelInstallerError.directoryOperationFailed }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      Self.sameIdentity(inspected, opened),
                      opened.st_nlink == 1
                else {
                    close(child)
                    throw ModelInstallerError.directoryOperationFailed
                }
                close(child)
                guard unlinkat(descriptor, name, 0) == 0 else {
                    throw ModelInstallerError.directoryOperationFailed
                }
            } else {
                throw ModelInstallerError.directoryOperationFailed
            }
        }
    }

    private static func openDirectory(at url: URL) -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return descriptor }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o077) == 0 || fchmod(descriptor, mode_t(0o700)) == 0
        else {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    private static func openOrCreateDirectory(
        parent: Int32,
        name: String,
        relativePath: String,
        hook: ModelStagingAccessHook?
    ) throws -> Int32 {
        var inspected = stat()
        if fstatat(parent, name, &inspected, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ModelInstallerError.directoryOperationFailed }
            guard mkdirat(parent, name, mode_t(0o700)) == 0 || errno == EEXIST else {
                throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.directoryOperationFailed
            }
            guard fstatat(parent, name, &inspected, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ModelInstallerError.unsafePartial
            }
        }
        guard (inspected.st_mode & S_IFMT) == S_IFDIR else {
            if (inspected.st_mode & S_IFMT) == S_IFLNK { throw ModelInstallerError.partialIsSymlink }
            throw ModelInstallerError.unsafePartial
        }
        hook?(ModelStagingAccessEvent(relativePath: relativePath, phase: .beforeOpen))
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ModelInstallerError.partialIsSymlink }
            throw ModelInstallerError.unsafePartial
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              Self.sameIdentity(inspected, opened),
              fchmod(descriptor, mode_t(0o700)) == 0
        else {
            close(descriptor)
            throw ModelInstallerError.unsafePartial
        }
        return descriptor
    }

    private func pathComponents(_ relativePath: String) throws -> [String] {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !relativePath.hasPrefix("/"),
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty })
        else { throw ModelInstallerError.unsafePartial }
        return components
    }

    private func directoryEntries(_ descriptor: Int32) throws -> [String] {
        let fresh = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fresh >= 0 else {
            throw ModelInstallerError.directoryOperationFailed
        }
        var anchor = stat()
        var opened = stat()
        guard fstat(descriptor, &anchor) == 0,
              fstat(fresh, &opened) == 0,
              Self.sameIdentity(anchor, opened)
        else {
            close(fresh)
            throw ModelInstallerError.unsafePartial
        }
        guard let directory = fdopendir(fresh) else {
            close(fresh)
            throw ModelInstallerError.directoryOperationFailed
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func verifyIdentity(descriptor: Int32, parent: Int32, name: String) throws {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ModelInstallerError.unsafePartial
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              sameIdentity(named, opened)
        else { throw ModelInstallerError.unsafePartial }
    }
}

public final class ModelInstaller: @unchecked Sendable {
    public static let defaultDiskSafetyAllowance: Int64 = 1024 * 1024

    public let manifest: ModelManifest
    public let store: ModelStore

    private let downloadClient: any ModelDownloadClient
    private let lock: any ModelStoreLock
    private let diskSpaceProvider: any ModelDiskSpaceProvider
    private let timeout: TimeInterval
    private let enforceHTTPS: Bool
    private let diskSafetyAllowance: Int64
    private let stagingAccessHook: ModelStagingAccessHook?
    private let postRenameSyncHook: ModelPostRenameSyncHook?

    public init(
        manifest: ModelManifest,
        store: ModelStore,
        downloadClient: any ModelDownloadClient,
        lock: (any ModelStoreLock)? = nil,
        diskSpaceProvider: any ModelDiskSpaceProvider = FileSystemDiskSpaceProvider(),
        timeout: TimeInterval = 60,
        diskSafetyAllowance: Int64 = ModelInstaller.defaultDiskSafetyAllowance
    ) throws {
        do {
            try manifest.validate()
        } catch {
            throw ModelInstallerError.manifestInvalid
        }
        guard timeout > 0, diskSafetyAllowance >= 0 else { throw ModelInstallerError.manifestInvalid }
        self.manifest = manifest
        self.store = store
        self.downloadClient = downloadClient
        self.lock = try lock ?? OSBackedModelStoreLock(store: store)
        self.diskSpaceProvider = diskSpaceProvider
        self.timeout = timeout
        self.enforceHTTPS = true
        self.diskSafetyAllowance = diskSafetyAllowance
        self.stagingAccessHook = nil
        self.postRenameSyncHook = nil
    }

    internal init(
        unvalidatedManifestForTesting manifest: ModelManifest,
        store: ModelStore,
        downloadClient: any ModelDownloadClient,
        lock: any ModelStoreLock = InProcessModelStoreLock(),
        diskSpaceProvider: any ModelDiskSpaceProvider = FixedDiskSpaceProvider(bytes: Int64.max),
        timeout: TimeInterval = 60,
        enforceHTTPS: Bool = false,
        diskSafetyAllowance: Int64 = 0,
        stagingAccessHook: ModelStagingAccessHook? = nil,
        postRenameSyncHook: ModelPostRenameSyncHook? = nil
    ) {
        self.manifest = manifest
        self.store = store
        self.downloadClient = downloadClient
        self.lock = lock
        self.diskSpaceProvider = diskSpaceProvider
        self.timeout = timeout
        self.enforceHTTPS = enforceHTTPS
        self.diskSafetyAllowance = diskSafetyAllowance
        self.stagingAccessHook = stagingAccessHook
        self.postRenameSyncHook = postRenameSyncHook
    }

    public func install(activate: Bool = false, verifiedAt: Date = Date()) async throws -> ModelInstallResult {
        do {
            return try await lock.withLock { [self] in
                try await self.performInstall(activate: activate, verifiedAt: verifiedAt)
            }
        } catch is CancellationError {
            throw ModelInstallerError.cancelled
        }
    }

    public func preflight() async throws -> ModelInstallPreflight {
        do {
            return try await lock.withLock { [self] in
                try Task.checkCancellation()
                try store.prepareDirectories()

                let target = store.revisionsDirectory.appendingPathComponent(
                    manifest.immutableCommit,
                    isDirectory: true
                )
                let remainingBytes: Int64
                if try targetExists(target) {
                    guard targetVerifies(target) else { throw ModelInstallerError.targetConflict }
                    remainingBytes = 0
                } else {
                    let staging = try DescriptorRelativeStagingSession(
                        store: store,
                        immutableCommit: manifest.immutableCommit,
                        accessHook: stagingAccessHook,
                        postRenameSyncHook: nil
                    )
                    remainingBytes = try staging.remainingBytes(for: manifest.files)
                }

                let requiredBytes: Int64
                if remainingBytes == 0 {
                    requiredBytes = 0
                } else {
                    let (required, overflow) = remainingBytes.addingReportingOverflow(diskSafetyAllowance)
                    guard !overflow else { throw ModelInstallerError.diskFull }
                    requiredBytes = required
                }
                let availableBytes: Int64
                do {
                    availableBytes = try diskSpaceProvider.availableBytes(at: store.root)
                } catch {
                    throw ModelInstallerError.directoryOperationFailed
                }
                guard remainingBytes == 0 || availableBytes >= requiredBytes else {
                    throw ModelInstallerError.diskFull
                }
                return ModelInstallPreflight(
                    totalBytes: manifest.totalSize,
                    remainingBytes: remainingBytes,
                    safetyAllowance: diskSafetyAllowance,
                    requiredBytes: requiredBytes,
                    availableBytes: availableBytes
                )
            }
        } catch is CancellationError {
            throw ModelInstallerError.cancelled
        }
    }

    private func performInstall(activate: Bool, verifiedAt: Date) async throws -> ModelInstallResult {
        try Task.checkCancellation()
        try store.prepareDirectories()

        let target = store.revisionsDirectory.appendingPathComponent(manifest.immutableCommit, isDirectory: true)
        var createdTarget = false
        if try targetExists(target) {
            guard targetVerifies(target) else { throw ModelInstallerError.targetConflict }
        } else {
            let staging = try DescriptorRelativeStagingSession(
                store: store,
                immutableCommit: manifest.immutableCommit,
                accessHook: stagingAccessHook,
                postRenameSyncHook: postRenameSyncHook
            )
            let missingBytes = try staging.remainingBytes(for: manifest.files)
            let (requiredBytes, overflow) = missingBytes.addingReportingOverflow(diskSafetyAllowance)
            guard !overflow else { throw ModelInstallerError.diskFull }
            do {
                let available = try diskSpaceProvider.availableBytes(at: store.root)
                guard available >= requiredBytes else { throw ModelInstallerError.diskFull }
            } catch let error as ModelInstallerError {
                throw error
            } catch {
                throw ModelInstallerError.directoryOperationFailed
            }

            for file in manifest.files {
                try Task.checkCancellation()
                do {
                    try await download(file, using: staging)
                } catch {
                    throw mapDownloadError(error)
                }
            }

            do {
                try staging.verify(manifest: manifest, verifier: ModelVerifier())
            } catch {
                throw ModelInstallerError.verificationFailed
            }
            try staging.syncTree()
            if try targetExists(target) {
                guard targetVerifies(target) else { throw ModelInstallerError.targetConflict }
            } else {
                do {
                    try staging.commit(to: manifest.immutableCommit)
                    createdTarget = true
                    try staging.syncCommitParents()
                } catch let error as ModelInstallerError where error == .targetConflict {
                    guard targetVerifies(target) else { throw error }
                } catch {
                    if createdTarget {
                        try staging.removeCommittedTarget(manifest.immutableCommit)
                        createdTarget = false
                    }
                    throw error
                }
            }
        }

        let oldInstalled = try store.installedStateData()
        let oldSelection = try store.selectionStateData()
        do {
            _ = try store.recordVerifiedRevision(manifest: manifest, verifiedAt: verifiedAt)
        } catch {
            try? store.restoreInstalledState(oldInstalled)
            if createdTarget { try? removeCommittedTarget(target) }
            throw mapStateError(error)
        }

        guard activate else {
            return ModelInstallResult(immutableCommit: manifest.immutableCommit, activated: false)
        }

        do {
            _ = try store.activate(manifest: manifest, verifiedAt: verifiedAt)
        } catch {
            try? store.restoreInstalledState(oldInstalled)
            try? store.restoreSelectionState(oldSelection)
            if createdTarget { try? removeCommittedTarget(target) }
            throw mapStateError(error)
        }
        return ModelInstallResult(immutableCommit: manifest.immutableCommit, activated: true)
    }

    private func download(_ file: ModelManifest.File, using staging: DescriptorRelativeStagingSession) async throws {
        guard (!enforceHTTPS || file.url.hasPrefix("https://")),
              file.url == expectedURL(for: file.relativePath)
        else { throw ModelDownloadClientError.URLMismatch }

        let existingInfo = try staging.existingFileInfo(for: file.relativePath)
        let existing = existingInfo.size
        guard existing <= file.size else { throw ModelInstallerError.partialSizeExceedsManifest }

        if existing == file.size, existing > 0 {
            if try staging.fileHash(for: file.relativePath) == file.sha256 { return }
        }

        var prefix = existing
        if prefix == file.size {
            try staging.truncateFile(for: file.relativePath, to: 0)
            prefix = 0
        }
        let request = ModelDownloadRequest(
            url: file.url,
            expectedURL: expectedURL(for: file.relativePath),
            rangeStart: prefix > 0 ? prefix : nil,
            timeout: timeout
        )
        let response: ModelDownloadResponse
        do {
            response = try await downloadClient.response(for: request)
        } catch is CancellationError {
            throw ModelInstallerError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw ModelInstallerError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw ModelInstallerError.cancelled
        } catch let error as URLError where [.networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) {
            throw ModelInstallerError.connectionLost
        } catch {
            throw ModelInstallerError.connectionLost
        }
        try Task.checkCancellation()
        defer { response.body.cancel() }

        let ranged = request.rangeStart != nil
        let restart = ranged && response.statusCode == 200
        if !ranged && response.statusCode != 200 {
            throw ModelInstallerError.responseStatus(response.statusCode)
        }
        if ranged && response.statusCode != 200 && response.statusCode != 206 {
            throw ModelInstallerError.responseStatus(response.statusCode)
        }
        if response.statusCode == 206 {
            guard let range = parseContentRange(response.headers["content-range"]),
                  range.start == prefix,
                  range.end == file.size - 1,
                  range.total == file.size
            else { throw ModelInstallerError.invalidContentRange }
            try validateContentLength(response.headers, equals: file.size - prefix)
        } else {
            try validateContentLength(response.headers, equals: file.size)
        }

        if restart {
            try staging.truncateFile(for: file.relativePath, to: 0)
        }
        let startingOffset = restart ? 0 : prefix
        let descriptor = try staging.openDownloadFile(for: file.relativePath, appendFrom: startingOffset)
        defer { close(descriptor) }
        var hasher = SHA256()
        if startingOffset > 0 {
            try hashFilePrefix(descriptor: descriptor, count: startingOffset, into: &hasher)
            guard lseek(descriptor, off_t(startingOffset), SEEK_SET) == startingOffset else {
                throw ModelInstallerError.partialIsNotRegular
            }
        }

        var written = startingOffset
        do {
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard Int64(chunk.count) <= file.size - written else {
                    throw ModelInstallerError.responseOverrun
                }
                try write(chunk, to: descriptor)
                hasher.update(data: chunk)
                written += Int64(chunk.count)
            }
        } catch is CancellationError {
            _ = ftruncate(descriptor, off_t(written))
            throw ModelInstallerError.cancelled
        } catch let error as ModelInstallerError {
            _ = ftruncate(descriptor, off_t(error == .responseOverrun ? startingOffset : written))
            throw error
        } catch let error as URLError where error.code == .timedOut {
            _ = ftruncate(descriptor, off_t(written))
            throw ModelInstallerError.timeout
        } catch {
            _ = ftruncate(descriptor, off_t(written))
            throw ModelInstallerError.connectionLost
        }
        guard written == file.size else {
            _ = ftruncate(descriptor, off_t(written))
            throw ModelInstallerError.truncatedResponse
        }
        guard fsync(descriptor) == 0 else {
            throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.directoryOperationFailed
        }
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == file.sha256 else {
            _ = ftruncate(descriptor, 0)
            throw ModelInstallerError.hashMismatch
        }
    }

    private func expectedURL(for relativePath: String) -> String {
        if enforceHTTPS {
            return "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(manifest.immutableCommit)/\(relativePath)"
        }
        return manifest.files.first(where: { $0.relativePath == relativePath })?.url ?? ""
    }

    private func targetExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw ModelInstallerError.targetConflict
        }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw ModelInstallerError.targetConflict }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ModelInstallerError.targetConflict }
        return true
    }

    private func targetVerifies(_ target: URL) -> Bool {
        let root = target.appendingPathComponent(ModelManifest.supportedRepositoryFolder, isDirectory: true)
        do {
            try ModelVerifier().verify(manifest: manifest, at: root)
        } catch {
            return false
        }
        return privateTreeModes(target)
    }

    private func privateTreeModes(_ root: URL) -> Bool {
        guard let entries = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else { return false }
        for path in entries + [""] {
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) != S_IFLNK,
                  (info.st_mode & 0o077) == 0
            else { return false }
        }
        return true
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.connectionLost
                }
                offset += count
            }
        }
    }

    private func hashFilePrefix(descriptor: Int32, count: Int64, into hasher: inout SHA256) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw ModelInstallerError.partialIsNotRegular }
        var remaining = count
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let requested = min(Int64(buffer.count), remaining)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, Int(requested))
            }
            guard readCount > 0 else { throw ModelInstallerError.truncatedResponse }
            hasher.update(data: Data(buffer[0..<readCount]))
            remaining -= Int64(readCount)
        }
    }

    private func validateContentLength(_ headers: [String: String], equals expected: Int64) throws {
        if let value = headers["content-length"] {
            guard Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) == expected else {
                throw ModelInstallerError.wrongContentLength
            }
            return
        }
        // URLSession may consume chunk framing and report an identity transfer.
        // The streaming byte count below remains the authoritative size check.
    }

    private struct ContentRange {
        let start: Int64
        let end: Int64
        let total: Int64
    }

    private func parseContentRange(_ value: String?) -> ContentRange? {
        guard let value else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "bytes" else { return nil }
        let rangeParts = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard rangeParts.count == 2 else { return nil }
        let bounds = rangeParts[0].split(separator: "-", maxSplits: 1).compactMap { Int64($0) }
        guard bounds.count == 2, let total = Int64(rangeParts[1]), total >= 0 else { return nil }
        return ContentRange(start: bounds[0], end: bounds[1], total: total)
    }

    private func removeCommittedTarget(_ target: URL) throws {
        var info = stat()
        guard lstat(target.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ModelInstallerError.targetConflict
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & S_IFMT) != S_IFLNK
        else { throw ModelInstallerError.targetConflict }
        try FileManager.default.removeItem(at: target)
        let descriptor = open(store.revisionsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ModelInstallerError.directoryOperationFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw errno == ENOSPC ? ModelInstallerError.diskFull : ModelInstallerError.directoryOperationFailed
        }
    }

    private func mapDownloadError(_ error: Error) -> ModelInstallerError {
        if let error = error as? ModelInstallerError { return error }
        if let error = error as? ModelDownloadClientError {
            if case .URLMismatch = error { return .manifestInvalid }
            return .connectionLost
        }
        if error is CancellationError { return .cancelled }
        return .connectionLost
    }

    private func mapStateError(_ error: Error) -> ModelInstallerError {
        if error is ModelStoreError { return .stateUpdateFailed }
        return .stateUpdateFailed
    }
}
