import Darwin
import Foundation

public enum AtomicStateWriterOperation: Sendable {
    case open
    case write
    case fsyncFile
    case rename
    case fsyncDirectory
}

public enum AtomicStateWriterError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDestination
    case openFailed
    case writeFailed
    case fileSyncFailed
    case renameFailed
    case directorySyncFailed

    public var description: String {
        switch self {
        case .invalidDestination:
            return "atomic state destination is invalid"
        case .openFailed:
            return "atomic state file could not be opened"
        case .writeFailed:
            return "atomic state file could not be written"
        case .fileSyncFailed:
            return "atomic state file could not be synced"
        case .renameFailed:
            return "atomic state file could not be committed"
        case .directorySyncFailed:
            return "atomic state directory could not be synced"
        }
    }
}

/// Writes one private file with POSIX atomic replacement semantics.
public struct AtomicStateWriter: Sendable {
    public typealias FailureInjector = @Sendable (AtomicStateWriterOperation) -> Bool

    private let failureInjector: FailureInjector?

    public init(failureInjector: FailureInjector? = nil) {
        self.failureInjector = failureInjector
    }

    public func write<T: Encodable>(
        _ value: T,
        to destination: URL,
        encoder: JSONEncoder = AtomicStateWriter.defaultEncoder
    ) throws {
        try write(encoder.encode(value), to: destination)
    }

    public func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw AtomicStateWriterError.invalidDestination
        }

        let directoryDescriptor = try openDirectory(directory)
        defer { close(directoryDescriptor) }

        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        var temporaryDescriptor: Int32 = -1
        var renamed = false
        defer {
            if temporaryDescriptor >= 0 {
                close(temporaryDescriptor)
            }
            if !renamed {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        if shouldFail(.open) {
            throw AtomicStateWriterError.openFailed
        }
        temporaryDescriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else {
            throw AtomicStateWriterError.openFailed
        }
        guard fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
            throw AtomicStateWriterError.openFailed
        }

        if shouldFail(.write) {
            throw AtomicStateWriterError.writeFailed
        }
        try writeAll(data, to: temporaryDescriptor)

        if shouldFail(.fsyncFile) {
            throw AtomicStateWriterError.fileSyncFailed
        }
        guard fsync(temporaryDescriptor) == 0 else {
            throw AtomicStateWriterError.fileSyncFailed
        }

        if shouldFail(.rename) {
            throw AtomicStateWriterError.renameFailed
        }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, name) == 0 else {
            throw AtomicStateWriterError.renameFailed
        }
        renamed = true

        if shouldFail(.fsyncDirectory) {
            throw AtomicStateWriterError.directorySyncFailed
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw AtomicStateWriterError.directorySyncFailed
        }
    }

    public static var defaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func shouldFail(_ operation: AtomicStateWriterOperation) -> Bool {
        failureInjector?(operation) == true
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AtomicStateWriterError.openFailed
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR
        else {
            close(descriptor)
            throw AtomicStateWriterError.openFailed
        }
        guard fchmod(descriptor, mode_t(0o700)) == 0 else {
            close(descriptor)
            throw AtomicStateWriterError.openFailed
        }
        return descriptor
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    throw AtomicStateWriterError.writeFailed
                }
                offset += written
            }
        }
    }
}
