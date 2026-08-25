import Darwin
import Foundation

enum ServiceFileSystemError: Error, Equatable, Sendable {
    case invalidPath
    case symlink
    case pathEscape
    case notFound
    case notDirectory
    case notRegularFile
    case ownership
    case hardLink
    case unsafePermissions
    case malformedPlist
    case writeFailed
    case readFailed
    case deleteFailed
}

struct ServicePrivateFileSnapshot {
    let data: Data
    let mode: mode_t
}

struct ServiceFileSystem: @unchecked Sendable {
    let currentUserID: uid_t
    let beforeOpeningComponent: (@Sendable (String) -> Void)?
    let afterOpeningPrivateLock: (@Sendable (URL, Int32) -> Void)?
    let beforeAcquiringPrivateReadLock: (@Sendable (URL, Int32) -> Void)?
    let afterOpeningPrivateRead: (@Sendable (URL, Int32) -> Void)?

    init(
        currentUserID: uid_t = getuid(),
        beforeOpeningComponent: (@Sendable (String) -> Void)? = nil,
        afterOpeningPrivateLock: (@Sendable (URL, Int32) -> Void)? = nil,
        beforeAcquiringPrivateReadLock: (@Sendable (URL, Int32) -> Void)? = nil,
        afterOpeningPrivateRead: (@Sendable (URL, Int32) -> Void)? = nil
    ) {
        self.currentUserID = currentUserID
        self.beforeOpeningComponent = beforeOpeningComponent
        self.afterOpeningPrivateLock = afterOpeningPrivateLock
        self.beforeAcquiringPrivateReadLock = beforeAcquiringPrivateReadLock
        self.afterOpeningPrivateRead = afterOpeningPrivateRead
    }

    func ensureDirectory(_ url: URL, privateMode: Bool) throws {
        let path = try canonicalPath(url)
        guard path != "/" else { throw ServiceFileSystemError.pathEscape }
        let descriptor = try openDirectory(path, create: true, privateMode: privateMode)
        close(descriptor)
    }

    func openPrivateLock(_ url: URL) throws -> Int32 {
        try withParentDescriptor(url, createParents: true, privateParents: true) { parent, name in
            var before = stat()
            let existed = fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0
            let failureErrno = errno
            if existed {
                try validateRegular(before, privateMode: true)
            } else if failureErrno != ENOENT {
                throw ServiceFileSystemError.readFailed
            }
            let descriptor = name.withCString {
                openat(
                    parent,
                    $0,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.writeFailed }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else {
                close(descriptor)
                throw ServiceFileSystemError.readFailed
            }
            guard opened.st_uid == currentUserID,
                  opened.st_nlink == 1,
                  (opened.st_mode & S_IFMT) == S_IFREG,
                  (opened.st_mode & 0o077) == 0,
                  !existed || (opened.st_dev == before.st_dev && opened.st_ino == before.st_ino)
            else {
                close(descriptor)
                throw ServiceFileSystemError.ownership
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                close(descriptor)
                throw ServiceFileSystemError.unsafePermissions
            }
            afterOpeningPrivateLock?(url, descriptor)
            return descriptor
        }
    }

    func openLifecycleAuthority(_ url: URL) throws -> Int32 {
        let path = try canonicalPath(url)
        guard path != "/" else { throw ServiceFileSystemError.invalidPath }
        let parentPath = String(path.dropLast(path.split(separator: "/").last!.count + 1))
        return try openDirectory(
            parentPath.isEmpty ? "/" : parentPath,
            create: true,
            privateMode: true
        )
    }

    func privateLockIdentityMatches(_ url: URL, descriptor: Int32) throws -> Bool {
        do {
            return try withParentDescriptor(url, createParents: false) { parent, name in
                var entry = stat()
                guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0 else { return false }
                return entry.st_dev == opened.st_dev && entry.st_ino == opened.st_ino
            }
        } catch ServiceFileSystemError.notFound {
            return false
        }
    }

    func directoryIdentityMatches(_ url: URL, descriptor: Int32) throws -> Bool {
        let path = URL(fileURLWithPath: try canonicalPath(url), isDirectory: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR
        else { return false }
        let parentPath = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        let parent = try openDirectory(parentPath.path, create: false, privateMode: false)
        defer { close(parent) }
        var entry = stat()
        guard name.withCString({ fstatat(parent, $0, &entry, AT_SYMLINK_NOFOLLOW) == 0 }) else {
            return false
        }
        return sameIdentity(opened, entry)
    }

    func validateRegularFile(_ url: URL, privateMode: Bool) throws {
        try withParentDescriptor(url, createParents: false) { parent, name in
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw errno == ENOENT ? ServiceFileSystemError.notRegularFile : ServiceFileSystemError.readFailed
            }
            try validateRegular(info, privateMode: privateMode)
        }
    }

    func validateRegularFileIfPresent(_ url: URL, privateMode: Bool) throws -> Bool {
        do {
            return try withParentDescriptor(url, createParents: false) { parent, name in
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    let failureErrno = errno
                    if failureErrno == ENOENT { return false }
                    throw ServiceFileSystemError.readFailed
                }
                try validateRegular(info, privateMode: privateMode)
                return true
            }
        } catch ServiceFileSystemError.notFound {
            return false
        }
    }

    func validateSecretFile(_ url: URL) throws {
        try withParentDescriptor(url, createParents: false) { parent, name in
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ServiceFileSystemError.notRegularFile
            }
            try validateRegular(info, privateMode: true)
            guard (info.st_mode & 0o177) == 0 else {
                throw ServiceFileSystemError.unsafePermissions
            }
        }
    }

    func validateExecutableFile(_ url: URL) throws {
        try withParentDescriptor(url, createParents: false) { parent, name in
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ServiceFileSystemError.notRegularFile
            }
            try validateRegular(info, privateMode: false)
            guard (info.st_mode & 0o111) != 0 else {
                throw ServiceFileSystemError.unsafePermissions
            }
        }
    }

    func validateDirectory(_ url: URL, requirePrivate: Bool = false) throws {
        try withParentDescriptor(url, createParents: false) { parent, name in
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw errno == ENOENT ? ServiceFileSystemError.notDirectory : ServiceFileSystemError.readFailed
            }
            try validateDirectory(info, requirePrivate: requirePrivate)
        }
    }

    func writePrivateFileAtomically(_ data: Data, to url: URL) throws {
        try withParentDescriptor(url, createParents: true) { parent, name in
            var prior = stat()
            let hadPrior = fstatat(parent, name, &prior, AT_SYMLINK_NOFOLLOW) == 0
            let failureErrno = errno
            if hadPrior {
                try validateRegular(prior, privateMode: true)
            } else if failureErrno != ENOENT {
                throw ServiceFileSystemError.writeFailed
            }

            let temporaryName = ".\(name).\(UUID().uuidString).tmp"
            let descriptor = temporaryName.withCString { cName in
                openat(
                    parent,
                    cName,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.writeFailed }

            var renamed = false
            defer {
                close(descriptor)
                if !renamed {
                    _ = temporaryName.withCString { unlinkat(parent, $0, 0) }
                }
            }

            let wrote = data.withUnsafeBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return true }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard wrote, fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
                throw ServiceFileSystemError.writeFailed
            }

            var temporaryInfo = stat()
            guard fstat(descriptor, &temporaryInfo) == 0 else {
                throw ServiceFileSystemError.writeFailed
            }
            try validateRegular(temporaryInfo, privateMode: true)

            var beforeRename = stat()
            let stillSame = fstatat(parent, name, &beforeRename, AT_SYMLINK_NOFOLLOW) == 0
            if hadPrior {
                guard stillSame,
                      beforeRename.st_dev == prior.st_dev,
                      beforeRename.st_ino == prior.st_ino
                else { throw ServiceFileSystemError.writeFailed }
            } else if stillSame {
                throw ServiceFileSystemError.writeFailed
            } else if errno != ENOENT {
                throw ServiceFileSystemError.writeFailed
            }

            guard renameat(parent, temporaryName, parent, name) == 0 else {
                throw ServiceFileSystemError.writeFailed
            }
            renamed = true
            guard fsync(parent) == 0 else { throw ServiceFileSystemError.writeFailed }

            var finalInfo = stat()
            guard fstatat(parent, name, &finalInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  finalInfo.st_dev == temporaryInfo.st_dev,
                  finalInfo.st_ino == temporaryInfo.st_ino
            else { throw ServiceFileSystemError.writeFailed }
            try validateRegular(finalInfo, privateMode: true)
        }
    }

    func ensurePrivateFile(_ url: URL) throws {
        try withParentDescriptor(url, createParents: true, privateParents: true) { parent, name in
            var prior = stat()
            let exists = name.withCString {
                fstatat(parent, $0, &prior, AT_SYMLINK_NOFOLLOW) == 0
            }
            if exists {
                try validateRegular(prior, privateMode: true)
                let descriptor = name.withCString {
                    openat(parent, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else { throw ServiceFileSystemError.writeFailed }
                defer { close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0,
                      sameIdentity(prior, opened),
                      opened.st_nlink == 1
                else { throw ServiceFileSystemError.writeFailed }
                guard fchmod(descriptor, mode_t(0o600)) == 0,
                      fsync(descriptor) == 0
                else { throw ServiceFileSystemError.writeFailed }
                var final = stat()
                guard name.withCString({ fstatat(parent, $0, &final, AT_SYMLINK_NOFOLLOW) == 0 }),
                      sameIdentity(opened, final),
                      final.st_nlink == 1,
                      (final.st_mode & S_IFMT) == S_IFREG
                else { throw ServiceFileSystemError.writeFailed }
                return
            }
            guard errno == ENOENT else { throw ServiceFileSystemError.writeFailed }
            let descriptor = name.withCString {
                openat(
                    parent,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.writeFailed }
            defer { close(descriptor) }
            var created = stat()
            guard fstat(descriptor, &created) == 0 else { throw ServiceFileSystemError.writeFailed }
            try validateRegular(created, privateMode: true)
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fsync(descriptor) == 0
            else { throw ServiceFileSystemError.writeFailed }
            var final = stat()
            guard name.withCString({ fstatat(parent, $0, &final, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameIdentity(created, final),
                  final.st_nlink == 1
            else { throw ServiceFileSystemError.writeFailed }
        }
    }

    func privateFileMode(_ url: URL) throws -> mode_t {
        try withParentDescriptor(url, createParents: false) { parent, name in
            var info = stat()
            guard name.withCString({ fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }) else {
                throw ServiceFileSystemError.readFailed
            }
            try validateRegular(info, privateMode: true)
            return info.st_mode & 0o7777
        }
    }

    func restorePrivateFileMode(_ mode: mode_t, at url: URL) throws {
        guard (mode & 0o077) == 0 else { throw ServiceFileSystemError.unsafePermissions }
        try withParentDescriptor(url, createParents: false) { parent, name in
            var expected = stat()
            guard name.withCString({ fstatat(parent, $0, &expected, AT_SYMLINK_NOFOLLOW) == 0 }) else {
                throw ServiceFileSystemError.readFailed
            }
            try validateRegular(expected, privateMode: true)
            let descriptor = name.withCString {
                openat(parent, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.writeFailed }
            defer { close(descriptor) }

            var opened = stat()
            guard fstat(descriptor, &opened) == 0, sameIdentity(expected, opened) else {
                throw ServiceFileSystemError.writeFailed
            }
            guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else {
                throw ServiceFileSystemError.writeFailed
            }
            var final = stat()
            guard name.withCString({ fstatat(parent, $0, &final, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameIdentity(opened, final),
                  (final.st_mode & 0o7777) == mode
            else { throw ServiceFileSystemError.writeFailed }
            try validateRegular(final, privateMode: true)
        }
    }

    func readExactPrivateFile(_ url: URL, limit: Int) throws -> String {
        String(decoding: try readExactPrivateData(url, limit: limit), as: UTF8.self)
    }

    func readExactPrivateData(_ url: URL, limit: Int) throws -> Data {
        try readPrivateData(url, limit: limit, secret: false, tail: false)
    }

    func snapshotPrivateLogFileIfPresent(
        _ url: URL,
        limit: Int
    ) throws -> ServicePrivateFileSnapshot? {
        guard limit > 0 else { throw ServiceFileSystemError.readFailed }
        do {
            return try withParentDescriptor(url, createParents: false) { parent, name in
            var before = stat()
            guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) == 0 }) else {
                if errno == ENOENT { return nil }
                throw ServiceFileSystemError.readFailed
            }
            try validateRegular(before, privateMode: true)

            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.readFailed }
            defer { close(descriptor) }

            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  sameIdentity(before, opened)
            else { throw ServiceFileSystemError.readFailed }
            try validateRegular(opened, privateMode: true)
            beforeAcquiringPrivateReadLock?(url, descriptor)
            guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceFileSystemError.readFailed }
            defer { _ = flock(descriptor, LOCK_UN) }

            afterOpeningPrivateRead?(url, descriptor)
            var locked = stat()
            var lockedEntry = stat()
            guard fstat(descriptor, &locked) == 0,
                  sameIdentity(opened, locked),
                  name.withCString({ fstatat(parent, $0, &lockedEntry, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameReadState(locked, lockedEntry)
            else { throw ServiceFileSystemError.readFailed }
            try validateRegular(locked, privateMode: true)

            let data = try readAtMost(descriptor, limit: limit, allowOneOver: false)
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  sameReadState(locked, after)
            else { throw ServiceFileSystemError.readFailed }
            var afterEntry = stat()
            guard name.withCString({ fstatat(parent, $0, &afterEntry, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameReadState(locked, afterEntry)
            else { throw ServiceFileSystemError.readFailed }
            return ServicePrivateFileSnapshot(
                data: data,
                mode: locked.st_mode & 0o7777
            )
            }
        } catch ServiceFileSystemError.notFound {
            return nil
        }
    }

    func readExactSecretData(_ url: URL, limit: Int) throws -> Data {
        try readPrivateData(url, limit: limit, secret: true, tail: false)
    }

    func readBoundedLogFile(_ url: URL, limit: Int) throws -> String {
        String(decoding: try readPrivateData(url, limit: limit, secret: false, tail: true), as: UTF8.self)
    }

    func readBoundedPrivateFile(_ url: URL, limit: Int) throws -> String {
        try readExactPrivateFile(url, limit: limit)
    }

    func readBoundedPrivateData(_ url: URL, limit: Int) throws -> Data {
        try readExactPrivateData(url, limit: limit)
    }

    func appendPrivateLogRecord(_ record: String, to url: URL, limit: Int) throws {
        let marker = Data("[truncated]\n".utf8)
        guard limit >= marker.count else { throw ServiceFileSystemError.writeFailed }
        var redactedRecord = Data(ServiceRedactor.redactLog(record, paths: []).utf8)
        if !redactedRecord.isEmpty, redactedRecord.last != 0x0A {
            redactedRecord.append(0x0A)
        }
        if redactedRecord.count > limit {
            redactedRecord = marker
        }

        try withParentDescriptor(url, createParents: true, privateParents: true) { parent, name in
            var before = stat()
            let existed = name.withCString {
                fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) == 0
            }
            if existed {
                try validateRegular(before, privateMode: true)
            } else if errno != ENOENT {
                throw ServiceFileSystemError.writeFailed
            }

            let descriptor = name.withCString {
                openat(
                    parent,
                    $0,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.writeFailed }
            defer { close(descriptor) }

            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else {
                throw ServiceFileSystemError.writeFailed
            }
            try validateRegular(opened, privateMode: true)
            guard opened.st_uid == currentUserID,
                  opened.st_nlink == 1,
                  !existed || sameIdentity(before, opened)
            else { throw ServiceFileSystemError.writeFailed }
            guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceFileSystemError.writeFailed }
            defer { _ = flock(descriptor, LOCK_UN) }
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  lseek(descriptor, 0, SEEK_SET) >= 0
            else { throw ServiceFileSystemError.writeFailed }

            let sampleOffset = max(off_t(0), opened.st_size - off_t(limit + 1))
            guard lseek(descriptor, sampleOffset, SEEK_SET) >= 0 else {
                throw ServiceFileSystemError.writeFailed
            }
            let sample = try readAtMost(descriptor, limit: limit, allowOneOver: true)
            let redactedSample = Data(
                ServiceRedactor.redactLog(
                    String(decoding: sample, as: UTF8.self),
                    paths: []
                ).utf8
            )
            let oversized = opened.st_size > off_t(limit)
            let priorData: Data
            if oversized {
                let trimmed = completeLogRecords(redactedSample, limit: limit, truncated: true)
                priorData = trimmed.starts(with: marker) ? Data(trimmed.dropFirst(marker.count)) : trimmed
            } else {
                priorData = Data(completeLogRecordList(redactedSample).joined())
            }
            let hadIncompleteRecord = !redactedSample.isEmpty && redactedSample.last != 0x0A
            let combined = priorData + redactedRecord
            let bounded = boundedLogRecords(
                combined,
                limit: limit,
                truncated: oversized || hadIncompleteRecord || combined.count > limit
            )

            guard ftruncate(descriptor, 0) == 0,
                  lseek(descriptor, 0, SEEK_SET) >= 0,
                  writeAll(bounded, to: descriptor),
                  fsync(descriptor) == 0
            else { throw ServiceFileSystemError.writeFailed }

            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  sameIdentity(opened, after),
                  after.st_nlink == 1,
                  name.withCString({ fstatat(parent, $0, &after, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameIdentity(opened, after)
            else { throw ServiceFileSystemError.writeFailed }
            try validateRegular(after, privateMode: true)
        }
    }

    func trimPrivateLogFile(_ url: URL, limit: Int) throws {
        guard limit > 0 else { throw ServiceFileSystemError.writeFailed }
        try withParentDescriptor(url, createParents: false) { parent, name in
            var before = stat()
            guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) == 0 }) else {
                if errno == ENOENT { return }
                throw ServiceFileSystemError.writeFailed
            }
            try validateRegular(before, privateMode: true)
            let descriptor = name.withCString {
                openat(parent, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.writeFailed }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  sameIdentity(before, opened),
                  opened.st_nlink == 1
            else { throw ServiceFileSystemError.writeFailed }
            guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceFileSystemError.writeFailed }
            defer { _ = flock(descriptor, LOCK_UN) }
            afterOpeningPrivateRead?(url, descriptor)
            var checked = stat()
            guard fstat(descriptor, &checked) == 0,
                  sameIdentity(opened, checked),
                  name.withCString({ fstatat(parent, $0, &checked, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameIdentity(opened, checked)
            else { throw ServiceFileSystemError.writeFailed }
            guard opened.st_size > off_t(limit) else { return }

            let offset = max(off_t(0), opened.st_size - off_t(limit + 1))
            guard lseek(descriptor, offset, SEEK_SET) >= 0 else {
                throw ServiceFileSystemError.writeFailed
            }
            let tail = try readAtMost(descriptor, limit: limit, allowOneOver: true)
            let retained = completeLogRecords(tail, limit: limit, truncated: true)
            let redacted = Data(
                ServiceRedactor.redactLog(
                    String(decoding: retained, as: UTF8.self),
                    paths: []
                ).utf8
            )
            let bounded = redacted.count <= limit
                ? redacted
                : completeLogRecords(redacted, limit: limit, truncated: true)
            guard ftruncate(descriptor, 0) == 0,
                  lseek(descriptor, 0, SEEK_SET) >= 0,
                  writeAll(bounded, to: descriptor),
                  fsync(descriptor) == 0
            else { throw ServiceFileSystemError.writeFailed }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  sameIdentity(opened, after),
                  after.st_nlink == 1,
                  (after.st_mode & S_IFMT) == S_IFREG,
                  name.withCString({ fstatat(parent, $0, &checked, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameIdentity(after, checked)
            else { throw ServiceFileSystemError.writeFailed }
        }
    }

    private func readPrivateData(
        _ url: URL,
        limit: Int,
        secret: Bool,
        tail: Bool
    ) throws -> Data {
        guard limit > 0 else { throw ServiceFileSystemError.readFailed }
        return try withParentDescriptor(url, createParents: false) { parent, name in
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ServiceFileSystemError.readFailed
            }
            try validateRegular(before, privateMode: true)
            if secret, (before.st_mode & 0o177) != 0 {
                throw ServiceFileSystemError.unsafePermissions
            }

            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw ServiceFileSystemError.readFailed }
            defer { close(descriptor) }

            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  opened.st_dev == before.st_dev,
                  opened.st_ino == before.st_ino
            else { throw ServiceFileSystemError.readFailed }
            try validateRegular(opened, privateMode: true)
            if secret, (opened.st_mode & 0o177) != 0 {
                throw ServiceFileSystemError.unsafePermissions
            }

            afterOpeningPrivateRead?(url, descriptor)
            if tail {
                guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceFileSystemError.readFailed }
            }
            defer {
                if tail { _ = flock(descriptor, LOCK_UN) }
            }
            if tail {
                let offset = max(off_t(0), opened.st_size - off_t(limit + 1))
                guard lseek(descriptor, offset, SEEK_SET) >= 0 else {
                    throw ServiceFileSystemError.readFailed
                }
            }
            let result = try readAtMost(descriptor, limit: limit, allowOneOver: tail)
            var descriptorAfter = stat()
            guard fstat(descriptor, &descriptorAfter) == 0,
                  sameReadState(opened, descriptorAfter)
            else { throw ServiceFileSystemError.readFailed }
            var after = stat()
            guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  sameReadState(descriptorAfter, after)
            else { throw ServiceFileSystemError.readFailed }
            if tail {
                let complete = completeLogRecords(
                    result,
                    limit: limit,
                    truncated: opened.st_size > off_t(limit)
                )
                let redacted = Data(ServiceRedactor.redactLog(
                    String(decoding: complete, as: UTF8.self)
                ).utf8)
                return boundedLogRecords(
                    redacted,
                    limit: limit,
                    truncated: opened.st_size > off_t(limit) || redacted.count > limit
                )
            }
            return result
        }
    }

    private func readAtMost(
        _ descriptor: Int32,
        limit: Int,
        allowOneOver: Bool
    ) throws -> Data {
        let maximum = limit + 1
        var result = Data()
        while true {
            let remaining = maximum - result.count
            guard remaining > 0 else { return result }
            var buffer = [UInt8](repeating: 0, count: min(16 * 1024, remaining))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw ServiceFileSystemError.readFailed
            }
            if count == 0 { break }
            result.append(contentsOf: buffer[0..<count])
            if result.count > limit + (allowOneOver ? 1 : 0) {
                throw ServiceFileSystemError.readFailed
            }
            if allowOneOver, result.count == maximum { return result }
        }
        return result
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private func completeLogRecords(_ data: Data, limit: Int, truncated: Bool) -> Data {
        guard truncated else { return data }
        let marker = Data("[truncated]\n".utf8)
        guard let firstNewline = data.firstIndex(of: 0x0A) else { return marker }
        let afterBoundary = data.index(after: firstNewline)
        guard afterBoundary < data.endIndex,
              let lastNewline = data.lastIndex(of: 0x0A),
              lastNewline >= afterBoundary
        else { return marker }
        let completeEnd = data.index(after: lastNewline)
        guard afterBoundary < completeEnd else { return marker }
        var records: [Data] = []
        var cursor = afterBoundary
        while cursor < completeEnd {
            var newline = cursor
            while newline < completeEnd, data[newline] != 0x0A {
                newline = data.index(after: newline)
            }
            guard newline < completeEnd else { break }
            let recordEnd = data.index(after: newline)
            records.append(Data(data[cursor..<recordEnd]))
            cursor = recordEnd
        }

        var selected = Data()
        for record in records.reversed() {
            guard marker.count + selected.count + record.count <= limit else { break }
            selected = record + selected
        }
        return marker + selected
    }

    private func completeLogRecordList(_ data: Data) -> [Data] {
        var records: [Data] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let newline = data[cursor...].firstIndex(of: 0x0A) else { break }
            let end = data.index(after: newline)
            records.append(Data(data[cursor..<end]))
            cursor = end
        }
        return records
    }

    private func boundedLogRecords(_ data: Data, limit: Int, truncated: Bool) -> Data {
        let marker = Data("[truncated]\n".utf8)
        let records = completeLogRecordList(data)
        var selected = Data()
        let prefix = truncated ? marker : Data()
        for record in records.reversed() {
            guard prefix.count + selected.count + record.count <= limit else { break }
            selected = record + selected
        }
        return prefix + selected
    }

    private func sameReadState(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    func removeTreeIfPresent(_ url: URL) throws {
        try ServiceRecoveryContext.consume()
        do {
            try withParentDescriptor(url, createParents: false) { parent, name in
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { return }
                    throw ServiceFileSystemError.deleteFailed
                }
                try deleteNode(parent: parent, name: name, expected: info)
            }
        } catch ServiceFileSystemError.notFound {
            return
        }
    }

    func validateTreeIfPresent(_ url: URL) throws {
        try withParentDescriptor(url, createParents: false) { parent, name in
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return }
                throw ServiceFileSystemError.readFailed
            }
            try validateNode(parent: parent, name: name, expected: info)
        }
    }

    func exists(_ url: URL) throws -> Bool {
        do {
            return try withParentDescriptor(url, createParents: false) { parent, name in
                var info = stat()
                if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
                let failureErrno = errno
                if failureErrno == ENOENT { return false }
                throw ServiceFileSystemError.readFailed
            }
        } catch ServiceFileSystemError.notFound {
            return false
        }
    }

    private func validateNode(parent: Int32, name: String, expected: stat) throws {
        let type = expected.st_mode & S_IFMT
        if type == S_IFLNK { throw ServiceFileSystemError.symlink }
        if type == S_IFREG {
            try validateRegular(expected, privateMode: true)
            return
        }
        guard type == S_IFDIR else { throw ServiceFileSystemError.notDirectory }
        try validateDirectory(expected, requirePrivate: false)
        let directory = try openChild(parent: parent, name: name, expected: expected)
        defer { close(directory) }
        for child in try directoryNames(directory) {
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ServiceFileSystemError.readFailed
            }
            try validateNode(parent: directory, name: child, expected: info)
        }
    }

    private func deleteNode(parent: Int32, name: String, expected: stat) throws {
        try ServiceRecoveryContext.consume()
        let type = expected.st_mode & S_IFMT
        if type == S_IFLNK { throw ServiceFileSystemError.symlink }
        if type == S_IFREG {
            try validateRegular(expected, privateMode: true)
            try unlinkIfSame(parent: parent, name: name, expected: expected, directory: false)
            return
        }
        guard type == S_IFDIR else { throw ServiceFileSystemError.notDirectory }
        try validateDirectory(expected, requirePrivate: false)
        let directory = try openChild(parent: parent, name: name, expected: expected)
        defer { close(directory) }
        for child in try directoryNames(directory) {
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw ServiceFileSystemError.deleteFailed
            }
            try deleteNode(parent: directory, name: child, expected: info)
        }
        try unlinkIfSame(parent: parent, name: name, expected: expected, directory: true)
    }

    private func unlinkIfSame(
        parent: Int32,
        name: String,
        expected: stat,
        directory: Bool
    ) throws {
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == expected.st_dev,
              current.st_ino == expected.st_ino
        else { throw ServiceFileSystemError.deleteFailed }
        let flags = directory ? AT_REMOVEDIR : 0
        guard name.withCString({ unlinkat(parent, $0, flags) }) == 0 else {
            throw ServiceFileSystemError.deleteFailed
        }
    }

    private func openChild(parent: Int32, name: String, expected: stat) throws -> Int32 {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ServiceFileSystemError.notDirectory }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino
        else {
            close(descriptor)
            throw ServiceFileSystemError.deleteFailed
        }
        return descriptor
    }

    private func directoryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw ServiceFileSystemError.readFailed
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
            if name != "." && name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw ServiceFileSystemError.readFailed }
        return names.sorted()
    }

    private func withParentDescriptor<T>(
        _ url: URL,
        createParents: Bool,
        privateParents: Bool = false,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        let path = try canonicalPath(url)
        guard path != "/", let name = path.split(separator: "/").last.map(String.init),
              name != ".", name != "..", !name.contains("/")
        else { throw ServiceFileSystemError.invalidPath }
        let parentPath = String(path.dropLast(name.count + 1))
        let parent = try openDirectory(
            parentPath.isEmpty ? "/" : parentPath,
            create: createParents,
            privateMode: privateParents
        )
        defer { close(parent) }
        return try body(parent, name)
    }

    private func openDirectory(_ path: String, create: Bool, privateMode: Bool) throws -> Int32 {
        guard path.hasPrefix("/") else { throw ServiceFileSystemError.invalidPath }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw ServiceFileSystemError.readFailed }
        var current = root
        var closeOnExit = true
        defer {
            if closeOnExit { close(current) }
        }
        let components = path.split(separator: "/").map(String.init)

        for (index, component) in components.enumerated() {
            beforeOpeningComponent?(component)
            var info = stat()
            let found = component.withCString { fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }
            if !found {
                let failureErrno = errno
                guard failureErrno == ENOENT, create else {
                    throw failureErrno == ENOENT ? ServiceFileSystemError.notFound : ServiceFileSystemError.readFailed
                }
                let mode = privateMode && index == components.count - 1 ? mode_t(0o700) : mode_t(0o755)
                guard component.withCString({ mkdirat(current, $0, mode) == 0 || errno == EEXIST }) else {
                    throw ServiceFileSystemError.writeFailed
                }
                guard component.withCString({ fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }) else {
                    throw ServiceFileSystemError.writeFailed
                }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw (info.st_mode & S_IFMT) == S_IFLNK ? ServiceFileSystemError.symlink : ServiceFileSystemError.notDirectory
            }
            try validateDirectory(info, requirePrivate: privateMode && index == components.count - 1)
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                throw ServiceFileSystemError.notDirectory
            }
            var opened = stat()
            guard fstat(next, &opened) == 0,
                  opened.st_dev == info.st_dev,
                  opened.st_ino == info.st_ino
            else {
                close(next)
                throw ServiceFileSystemError.pathEscape
            }
            close(current)
            current = next
        }
        closeOnExit = false
        return current
    }

    private func canonicalPath(_ url: URL) throws -> String {
        guard url.isFileURL else { throw ServiceFileSystemError.invalidPath }
        let raw = url.path
        guard raw.hasPrefix("/"), !raw.contains("\0") else {
            throw ServiceFileSystemError.invalidPath
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw ServiceFileSystemError.pathEscape
        }
        let lexical = "/" + components.joined(separator: "/")
        if lexical == "/var" || lexical.hasPrefix("/var/") {
            return "/private\(lexical)"
        }
        if lexical == "/tmp" || lexical.hasPrefix("/tmp/") {
            return "/private\(lexical)"
        }
        if lexical == "/etc" || lexical.hasPrefix("/etc/") {
            return "/private\(lexical)"
        }
        return lexical
    }

    private func validateDirectory(_ info: stat, requirePrivate: Bool) throws {
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ServiceFileSystemError.notDirectory }
        guard info.st_uid == currentUserID || info.st_uid == 0 else { throw ServiceFileSystemError.ownership }
        guard (info.st_mode & 0o022) == 0 else { throw ServiceFileSystemError.unsafePermissions }
        if requirePrivate, (info.st_mode & 0o077) != 0 {
            throw ServiceFileSystemError.unsafePermissions
        }
    }

    private func validateRegular(_ info: stat, privateMode: Bool) throws {
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG else {
            if type == S_IFLNK { throw ServiceFileSystemError.symlink }
            throw ServiceFileSystemError.notRegularFile
        }
        guard info.st_uid == currentUserID else { throw ServiceFileSystemError.ownership }
        guard info.st_nlink == 1 else { throw ServiceFileSystemError.hardLink }
        guard (info.st_mode & 0o022) == 0 else { throw ServiceFileSystemError.unsafePermissions }
        if privateMode, (info.st_mode & 0o077) != 0 {
            throw ServiceFileSystemError.unsafePermissions
        }
    }
}
