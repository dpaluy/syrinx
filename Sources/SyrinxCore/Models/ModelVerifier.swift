import CryptoKit
import Darwin
import Foundation

public enum ModelVerifierError: Error, Equatable, Sendable, CustomStringConvertible {
    case rootMissing
    case rootIsSymlink
    case rootIsNotDirectory
    case symlink(relativePath: String)
    case specialFile(relativePath: String)
    case unexpectedDirectory(relativePath: String)
    case extraFile(relativePath: String)
    case missingFile(relativePath: String)
    case hardLink(relativePath: String)
    case wrongSize(relativePath: String)
    case wrongHash(relativePath: String)
    case unreadableFile(relativePath: String)
    case raceDetected(relativePath: String)
    case directoryReadFailed

    public var description: String {
        switch self {
        case .rootMissing:
            return "model tree is missing"
        case .rootIsSymlink:
            return "model tree root must not be a symlink"
        case .rootIsNotDirectory:
            return "model tree root must be a directory"
        case let .symlink(relativePath):
            return "model tree contains a symlink at \(Self.redactedPath(relativePath))"
        case let .specialFile(relativePath):
            return "model tree contains a special file at \(Self.redactedPath(relativePath))"
        case let .unexpectedDirectory(relativePath):
            return "model tree contains an unexpected directory at \(Self.redactedPath(relativePath))"
        case let .extraFile(relativePath):
            return "model tree contains an extra file at \(Self.redactedPath(relativePath))"
        case let .missingFile(relativePath):
            return "model tree is missing \(Self.redactedPath(relativePath))"
        case let .hardLink(relativePath):
            return "model tree contains a hard-link alias at \(Self.redactedPath(relativePath))"
        case let .wrongSize(relativePath):
            return "model tree has the wrong size for \(Self.redactedPath(relativePath))"
        case let .wrongHash(relativePath):
            return "model tree has the wrong SHA-256 for \(Self.redactedPath(relativePath))"
        case let .unreadableFile(relativePath):
            return "model tree could not read \(Self.redactedPath(relativePath))"
        case let .raceDetected(relativePath):
            return "model tree changed while it was verified at \(Self.redactedPath(relativePath))"
        case .directoryReadFailed:
            return "model tree could not be inspected"
        }
    }

    private static func redactedPath(_ path: String) -> String {
        path.hasPrefix("/") ? "<redacted>" : path
    }
}

struct ModelVerifierEntryMetadata: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let fileType: UInt32
    let linkCount: UInt64
    let size: Int64

    static let regularFileType = UInt32(S_IFREG)
    static let directoryFileType = UInt32(S_IFDIR)

    init(device: UInt64, inode: UInt64, mode: UInt32, fileType: UInt32, linkCount: UInt64, size: Int64) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.fileType = fileType
        self.linkCount = linkCount
        self.size = size
    }

    init(stat: stat) {
        device = UInt64(stat.st_dev)
        inode = UInt64(stat.st_ino)
        mode = UInt32(stat.st_mode)
        fileType = UInt32(stat.st_mode & S_IFMT)
        linkCount = UInt64(stat.st_nlink)
        size = Int64(stat.st_size)
    }
}

public struct ModelVerifier: Sendable {
    public init() {}

    public func verify(manifest: ModelManifest, at root: URL) throws {
        try verify(files: manifest.files.map(\.expectation), at: root)
    }

    public func verify(files: [ModelFileExpectation], at root: URL) throws {
        try validate(files)

        var rootStat = stat()
        let rootResult = lstat(root.path, &rootStat)
        guard rootResult == 0 else {
            if errno == ENOENT {
                throw ModelVerifierError.rootMissing
            }
            throw ModelVerifierError.directoryReadFailed
        }
        if (rootStat.st_mode & S_IFMT) == S_IFLNK {
            throw ModelVerifierError.rootIsSymlink
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ModelVerifierError.rootIsNotDirectory
        }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw ModelVerifierError.rootIsSymlink
        }
        defer { close(rootDescriptor) }
        var openedRootStat = stat()
        guard fstat(rootDescriptor, &openedRootStat) == 0 else {
            throw ModelVerifierError.directoryReadFailed
        }
        try Self.validateOpenedDirectory(
            inspected: ModelVerifierEntryMetadata(stat: rootStat),
            opened: ModelVerifierEntryMetadata(stat: openedRootStat),
            relativePath: ""
        )
        try verifyOpened(files: files, descriptor: rootDescriptor, verifyContents: true)
    }

    internal func verify(files: [ModelFileExpectation], descriptor: Int32) throws {
        try validate(files)
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw ModelVerifierError.directoryReadFailed }
        defer { close(duplicate) }
        var openedRootStat = stat()
        guard fstat(duplicate, &openedRootStat) == 0 else {
            throw ModelVerifierError.directoryReadFailed
        }
        guard (openedRootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ModelVerifierError.rootIsNotDirectory
        }
        try verifyOpened(files: files, descriptor: duplicate, verifyContents: true)
    }

    internal func verifyStructure(manifest: ModelManifest, at root: URL) throws {
        try verifyStructure(files: manifest.files.map(\.expectation), at: root)
    }

    internal func verifyStructure(files: [ModelFileExpectation], at root: URL) throws {
        try validate(files)
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else {
            if errno == ENOENT { throw ModelVerifierError.rootMissing }
            throw ModelVerifierError.directoryReadFailed
        }
        if (rootStat.st_mode & S_IFMT) == S_IFLNK { throw ModelVerifierError.rootIsSymlink }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else { throw ModelVerifierError.rootIsNotDirectory }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw ModelVerifierError.rootIsSymlink }
        defer { close(rootDescriptor) }
        var openedRootStat = stat()
        guard fstat(rootDescriptor, &openedRootStat) == 0 else {
            throw ModelVerifierError.directoryReadFailed
        }
        try Self.validateOpenedDirectory(
            inspected: ModelVerifierEntryMetadata(stat: rootStat),
            opened: ModelVerifierEntryMetadata(stat: openedRootStat),
            relativePath: ""
        )
        try verifyOpened(files: files, descriptor: rootDescriptor, verifyContents: false)
    }

    private func validate(_ files: [ModelFileExpectation]) throws {
        for file in files {
            try ModelManifest.validate(relativePath: file.relativePath)
            guard ModelManifest.isAllowedArtifactPath(file.relativePath) else {
                throw ModelManifestError.invalidPath(file.relativePath)
            }
            guard ModelManifest.isSHA256(file.sha256) else {
                throw ModelManifestError.invalidSHA256(file.relativePath)
            }
        }
        guard Set(files.map(\.relativePath)).count == files.count else {
            throw ModelManifestError.duplicatePath("model file expectations")
        }
    }

    private func verifyOpened(
        files: [ModelFileExpectation],
        descriptor: Int32,
        verifyContents: Bool
    ) throws {
        let expected = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
        var expectedDirectories = Set<String>([""])
        for path in expected.keys {
            var component = path
            while let slash = component.lastIndex(of: "/") {
                component = String(component[..<slash])
                expectedDirectories.insert(component)
            }
        }

        var actualFiles = Set<String>()
        var seenInodes = Set<String>()
        try inspectDirectory(
            descriptor: descriptor,
            relativePath: "",
            expected: expected,
            expectedDirectories: expectedDirectories,
            actualFiles: &actualFiles,
            seenInodes: &seenInodes,
            verifyContents: verifyContents
        )

        for path in expected.keys where !actualFiles.contains(path) {
            throw ModelVerifierError.missingFile(relativePath: path)
        }
    }

    private func inspectDirectory(
        descriptor: Int32,
        relativePath: String,
        expected: [String: ModelFileExpectation],
        expectedDirectories: Set<String>,
        actualFiles: inout Set<String>,
        seenInodes: inout Set<String>,
        verifyContents: Bool
    ) throws {
        var directoryStat = stat()
        guard fstat(descriptor, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR
        else {
            throw ModelVerifierError.directoryReadFailed
        }

        let names = try directoryEntries(descriptor)

        for name in names {
            let childRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            var childStat = stat()
            guard fstatat(descriptor, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ModelVerifierError.directoryReadFailed
            }
            let fileType = childStat.st_mode & S_IFMT

            if fileType == S_IFLNK {
                throw ModelVerifierError.symlink(relativePath: childRelativePath)
            }
            if fileType == S_IFDIR {
                guard expectedDirectories.contains(childRelativePath) else {
                    throw ModelVerifierError.unexpectedDirectory(relativePath: childRelativePath)
                }
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard childDescriptor >= 0 else {
                    throw ModelVerifierError.symlink(relativePath: childRelativePath)
                }
                do {
                    defer { close(childDescriptor) }
                    var openedDirectoryStat = stat()
                    guard fstat(childDescriptor, &openedDirectoryStat) == 0 else {
                        throw ModelVerifierError.raceDetected(relativePath: childRelativePath)
                    }
                    try Self.validateOpenedDirectory(
                        inspected: ModelVerifierEntryMetadata(stat: childStat),
                        opened: ModelVerifierEntryMetadata(stat: openedDirectoryStat),
                        relativePath: childRelativePath
                    )
                    try inspectDirectory(
                        descriptor: childDescriptor,
                        relativePath: childRelativePath,
                        expected: expected,
                        expectedDirectories: expectedDirectories,
                        actualFiles: &actualFiles,
                        seenInodes: &seenInodes,
                        verifyContents: verifyContents
                    )
                }
                continue
            }
            guard fileType == S_IFREG else {
                throw ModelVerifierError.specialFile(relativePath: childRelativePath)
            }
            guard let expectation = expected[childRelativePath] else {
                throw ModelVerifierError.extraFile(relativePath: childRelativePath)
            }
            guard childStat.st_nlink == 1 else {
                throw ModelVerifierError.hardLink(relativePath: childRelativePath)
            }
            let inodeKey = "\(childStat.st_dev):\(childStat.st_ino)"
            guard seenInodes.insert(inodeKey).inserted else {
                throw ModelVerifierError.hardLink(relativePath: childRelativePath)
            }
            actualFiles.insert(childRelativePath)
            if verifyContents {
                try verifyFile(
                    parentDescriptor: descriptor,
                    name: name,
                    inspected: ModelVerifierEntryMetadata(stat: childStat),
                    expectation: expectation
                )
            } else {
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_NOFOLLOW)
                guard childDescriptor >= 0 else {
                    throw ModelVerifierError.unreadableFile(relativePath: expectation.relativePath)
                }
                defer { close(childDescriptor) }
                var openedFileStat = stat()
                guard fstat(childDescriptor, &openedFileStat) == 0 else {
                    throw ModelVerifierError.raceDetected(relativePath: expectation.relativePath)
                }
                try Self.validateOpenedFile(
                    inspected: ModelVerifierEntryMetadata(stat: childStat),
                    opened: ModelVerifierEntryMetadata(stat: openedFileStat),
                    expectedSize: expectation.size,
                    relativePath: expectation.relativePath
                )
            }
        }
    }

    private func verifyFile(
        parentDescriptor: Int32,
        name: String,
        inspected: ModelVerifierEntryMetadata,
        expectation: ModelFileExpectation
    ) throws {
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ModelVerifierError.unreadableFile(relativePath: expectation.relativePath)
        }
        defer { close(descriptor) }

        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else {
            throw ModelVerifierError.raceDetected(relativePath: expectation.relativePath)
        }
        try Self.validateOpenedFile(
            inspected: inspected,
            opened: ModelVerifierEntryMetadata(stat: fileStat),
            expectedSize: expectation.size,
            relativePath: expectation.relativePath
        )

        var hasher = SHA256()
        var totalRead: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                throw ModelVerifierError.unreadableFile(relativePath: expectation.relativePath)
            }
            if count == 0 { break }
            totalRead += Int64(count)
            if totalRead > expectation.size {
                throw ModelVerifierError.wrongSize(relativePath: expectation.relativePath)
            }
            hasher.update(data: Data(bytes: buffer, count: count))
        }
        guard totalRead == expectation.size else {
            throw ModelVerifierError.wrongSize(relativePath: expectation.relativePath)
        }

        var finalStat = stat()
        guard fstat(descriptor, &finalStat) == 0 else {
            throw ModelVerifierError.raceDetected(relativePath: expectation.relativePath)
        }
        try Self.validateFinalFile(
            opened: ModelVerifierEntryMetadata(stat: fileStat),
            final: ModelVerifierEntryMetadata(stat: finalStat),
            expectedSize: expectation.size,
            relativePath: expectation.relativePath
        )
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectation.sha256 else {
            throw ModelVerifierError.wrongHash(relativePath: expectation.relativePath)
        }
    }

    static func validateOpenedDirectory(
        inspected: ModelVerifierEntryMetadata,
        opened: ModelVerifierEntryMetadata,
        relativePath: String
    ) throws {
        guard opened.fileType == ModelVerifierEntryMetadata.directoryFileType,
              opened.device == inspected.device,
              opened.inode == inspected.inode
        else {
            throw ModelVerifierError.raceDetected(relativePath: relativePath)
        }
    }

    static func validateOpenedFile(
        inspected: ModelVerifierEntryMetadata,
        opened: ModelVerifierEntryMetadata,
        expectedSize: Int64,
        relativePath: String
    ) throws {
        guard inspected.fileType == ModelVerifierEntryMetadata.regularFileType,
              inspected.linkCount == 1,
              opened.fileType == ModelVerifierEntryMetadata.regularFileType,
              opened.device == inspected.device,
              opened.inode == inspected.inode,
              opened.mode == inspected.mode,
              opened.linkCount == 1,
              opened.size == inspected.size
        else {
            throw ModelVerifierError.raceDetected(relativePath: relativePath)
        }
        guard opened.size == expectedSize else {
            throw ModelVerifierError.wrongSize(relativePath: relativePath)
        }
    }

    static func validateFinalFile(
        opened: ModelVerifierEntryMetadata,
        final: ModelVerifierEntryMetadata,
        expectedSize: Int64,
        relativePath: String
    ) throws {
        guard final.fileType == ModelVerifierEntryMetadata.regularFileType,
              final.device == opened.device,
              final.inode == opened.inode,
              final.mode == opened.mode,
              final.linkCount == opened.linkCount,
              final.linkCount == 1,
              final.size == opened.size,
              final.size == expectedSize
        else {
            throw ModelVerifierError.raceDetected(relativePath: relativePath)
        }
    }

    private func directoryEntries(_ descriptor: Int32) throws -> [String] {
        let fresh = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fresh >= 0 else {
            throw ModelVerifierError.directoryReadFailed
        }
        var anchor = stat()
        var opened = stat()
        guard fstat(descriptor, &anchor) == 0,
              fstat(fresh, &opened) == 0,
              anchor.st_dev == opened.st_dev,
              anchor.st_ino == opened.st_ino
        else {
            close(fresh)
            throw ModelVerifierError.raceDetected(relativePath: "")
        }
        guard let directory = fdopendir(fresh) else {
            close(fresh)
            throw ModelVerifierError.directoryReadFailed
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }
}
