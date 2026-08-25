import Darwin
import Foundation

/// Owns one read-only descriptor. Descriptor handoff is consuming: the
/// caller must not close the descriptor after this type accepts it.
final class AudioFileAccess: @unchecked Sendable {
    let handle: FileHandle
    let byteCount: UInt64

    private init(handle: FileHandle, byteCount: UInt64) {
        self.handle = handle
        self.byteCount = byteCount
    }

    static func openReadOnlyRegular(fileURL: URL) throws -> AudioFileAccess {
        guard fileURL.isFileURL else { throw AudioPreparationError.inputNotRegularFile }

        let descriptor = fileURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw errno == ELOOP
                ? AudioPreparationError.inputNotRegularFile
                : AudioPreparationError.inputUnreadable
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            close(descriptor)
            throw AudioPreparationError.inputUnreadable
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw AudioPreparationError.inputNotRegularFile
        }
        guard fileStatus.st_size >= 0 else {
            close(descriptor)
            throw AudioPreparationError.arithmeticOverflow
        }

        return AudioFileAccess(
            handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            byteCount: UInt64(fileStatus.st_size)
        )
    }

    static func openReadOnly(fileDescriptor descriptor: Int32) throws -> AudioFileAccess {
        guard descriptor >= 0 else { throw AudioPreparationError.inputUnreadable }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            close(descriptor)
            throw AudioPreparationError.inputUnreadable
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_size >= 0
        else {
            close(descriptor)
            throw AudioPreparationError.inputNotRegularFile
        }

        return AudioFileAccess(
            handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            byteCount: UInt64(fileStatus.st_size)
        )
    }

    func duplicateDescriptorURL() throws -> (url: URL, descriptor: Int32) {
        // F_DUPFD_CLOEXEC keeps close-on-exec on the AVFoundation duplicate.
        // dup shares the open file description, so every consumer seeks first
        // and the admission gate keeps RIFF, metadata, and conversion serial.
        let duplicate = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw AudioPreparationError.inputUnreadable }
        guard lseek(duplicate, 0, SEEK_SET) >= 0 else {
            close(duplicate)
            throw AudioPreparationError.inputUnreadable
        }
        return (URL(fileURLWithPath: "/dev/fd/\(duplicate)"), duplicate)
    }

    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 else { throw AudioPreparationError.arithmeticOverflow }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            do {
                guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                    throw AudioPreparationError.truncatedInput
                }
                result.append(chunk)
            } catch let error as AudioPreparationError {
                throw error
            } catch {
                throw AudioPreparationError.inputUnreadable
            }
        }
        return result
    }

    func seek(toOffset offset: UInt64) throws {
        do {
            try handle.seek(toOffset: offset)
        } catch {
            throw AudioPreparationError.inputUnreadable
        }
    }

    func skip(_ count: UInt64) throws {
        let current = handle.offsetInFile
        guard count <= UInt64.max - current else { throw AudioPreparationError.arithmeticOverflow }
        let destination = current + count
        guard destination <= byteCount else { throw AudioPreparationError.truncatedInput }
        try seek(toOffset: destination)
    }
}
