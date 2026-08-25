import Darwin
import Foundation

public enum StandardPathsError: Error, Equatable, Sendable {
    case unavailable
}

public struct WritablePathStatus: Codable, Equatable, Sendable {
    public let path: String
    public let writable: Bool
    public let checkedPath: String

    public init(path: String, writable: Bool, checkedPath: String) {
        self.path = path
        self.writable = writable
        self.checkedPath = checkedPath
    }
}

public struct StandardPaths: Equatable, Sendable {
    public let data: URL
    public let cache: URL
    public let logs: URL

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.init(
            data: URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Syrinx", isDirectory: true),
            cache: URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("Syrinx", isDirectory: true),
            logs: URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("Syrinx", isDirectory: true)
        )
    }

    public static func trustedCurrentUserHome() throws -> URL {
        let uid = getuid()
        guard let passwd = getpwuid(uid), let rawHome = passwd.pointee.pw_dir else {
            throw StandardPathsError.unavailable
        }
        return try validateTrustedHome(
            URL(fileURLWithPath: String(cString: rawHome), isDirectory: true),
            uid: uid
        )
    }

    static func validateTrustedHome(_ candidate: URL, uid: uid_t) throws -> URL {
        let home = candidate.standardizedFileURL
        guard home.path.hasPrefix("/"), home.path != "/" else {
            throw StandardPathsError.unavailable
        }
        let descriptor = home.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw StandardPathsError.unavailable }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == uid,
              (opened.st_mode & 0o022) == 0
        else {
            throw StandardPathsError.unavailable
        }

        var entry = stat()
        guard lstat(home.path, &entry) == 0,
              (entry.st_mode & S_IFMT) == S_IFDIR,
              entry.st_uid == uid,
              (entry.st_mode & 0o022) == 0,
              entry.st_dev == opened.st_dev,
              entry.st_ino == opened.st_ino
        else {
            throw StandardPathsError.unavailable
        }
        return home
    }

    public init(data: URL, cache: URL, logs: URL) {
        self.data = data
        self.cache = cache
        self.logs = logs
    }

    public func writableStatuses(fileManager: FileManager) -> [WritablePathStatus] {
        [data, cache, logs].map { url in
            let checkedPath = nearestExistingParent(for: url, fileManager: fileManager)
            return WritablePathStatus(
                path: url.path,
                writable: fileManager.isWritableFile(atPath: checkedPath),
                checkedPath: checkedPath
            )
        }
    }

    public func validate(fileManager: FileManager = .default) throws {
        for url in [data, cache, logs] {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue, fileManager.isWritableFile(atPath: url.path) else {
                    throw StandardPathsError.unavailable
                }
                continue
            }

            let parent = nearestExistingParent(for: url, fileManager: fileManager)
            var parentIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent, isDirectory: &parentIsDirectory),
                  parentIsDirectory.boolValue,
                  fileManager.isWritableFile(atPath: parent)
            else {
                throw StandardPathsError.unavailable
            }
        }
    }

    private func nearestExistingParent(for url: URL, fileManager: FileManager) -> String {
        var candidate = url
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate.path
    }
}
