import Foundation

final class ServiceLogWriter: @unchecked Sendable {
    static let defaultLimit = 256 * 1024

    private let fileSystem: ServiceFileSystem
    private let paths: [URL]
    private let limit: Int
    private let lock = NSLock()

    init(
        fileSystem: ServiceFileSystem = .init(),
        paths: [URL],
        limit: Int = ServiceLogWriter.defaultLimit
    ) {
        self.fileSystem = fileSystem
        self.paths = paths
        self.limit = limit
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        for path in paths {
            try fileSystem.ensurePrivateFile(path)
            try fileSystem.appendPrivateLogRecord("", to: path, limit: limit)
        }
    }

    func append(_ record: String, to path: URL? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let destination = path ?? paths[0]
        try fileSystem.appendPrivateLogRecord(record, to: destination, limit: limit)
    }
}
