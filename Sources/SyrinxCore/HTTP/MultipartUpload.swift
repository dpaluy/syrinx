import Darwin
import Foundation

public enum MultipartUploadError: Error, Equatable, Sendable {
    case malformedMultipart
    case truncatedMultipart
    case unsupportedMultipart
    case uploadTooLarge
    case uploadFailed
}

private struct DirectoryIdentity: Sendable {
    let device: UInt64
    let inode: UInt64
}

private struct FileIdentity: Sendable {
    let device: UInt64
    let inode: UInt64
}

private struct OpenDirectory: Sendable {
    let descriptor: Int32
    let identity: DirectoryIdentity
}

public struct MultipartLimits: Equatable, Sendable {
    public static let `default` = Self(
        envelopeBytes: ServiceConfiguration.defaultMaxEnvelopeBytes,
        fileBytes: ServiceConfiguration.defaultMaxUploadBytes,
        fieldBytes: 64 * 1024,
        parts: 8,
        fileParts: 1,
        textFields: 7,
        boundaryBytes: 70,
        partHeaderLineBytes: 8 * 1024,
        partHeaderBytes: 16 * 1024,
        bodyBufferBytes: 64 * 1024,
        delimiterBytes: 74
    )

    public let envelopeBytes: Int
    public let fileBytes: Int
    public let fieldBytes: Int
    public let parts: Int
    public let fileParts: Int
    public let textFields: Int
    public let boundaryBytes: Int
    public let partHeaderLineBytes: Int
    public let partHeaderBytes: Int
    public let bodyBufferBytes: Int
    public let delimiterBytes: Int

    public init(
        envelopeBytes: Int = ServiceConfiguration.defaultMaxEnvelopeBytes,
        fileBytes: Int = ServiceConfiguration.defaultMaxUploadBytes,
        fieldBytes: Int = 64 * 1024,
        parts: Int = 8,
        fileParts: Int = 1,
        textFields: Int = 7,
        boundaryBytes: Int = 70,
        partHeaderLineBytes: Int = 8 * 1024,
        partHeaderBytes: Int = 16 * 1024,
        bodyBufferBytes: Int = 64 * 1024,
        delimiterBytes: Int = 74
    ) {
        self.envelopeBytes = envelopeBytes
        self.fileBytes = fileBytes
        self.fieldBytes = fieldBytes
        self.parts = parts
        self.fileParts = fileParts
        self.textFields = textFields
        self.boundaryBytes = boundaryBytes
        self.partHeaderLineBytes = partHeaderLineBytes
        self.partHeaderBytes = partHeaderBytes
        self.bodyBufferBytes = bodyBufferBytes
        self.delimiterBytes = delimiterBytes
    }
}

/// A private uploaded file. The URL is metadata only and is not the handler's
/// authoritative file access path. Use `withReadOnlyDescriptor` while the
/// handler runs, then call `cleanup()`.
public final class UploadedFile: @unchecked Sendable {
    public let url: URL

    private let fileHandle: FileHandle
    private let directoryDescriptor: Int32
    private let parentDescriptor: Int32
    private let directoryURL: URL
    private let fileName: String
    private let directoryName: String
    private let directoryIdentity: DirectoryIdentity
    private let fileIdentity: FileIdentity
    private let lock = NSLock()
    private var cleaned = false
    private var handedOff = false
    private var readOnlyDescriptor: Int32 = -1

    fileprivate init(
        url: URL,
        fileHandle: FileHandle,
        directoryDescriptor: Int32,
        directoryURL: URL,
        fileName: String,
        parentDescriptor: Int32,
        directoryName: String,
        directoryIdentity: DirectoryIdentity,
        fileIdentity: FileIdentity
    ) {
        self.url = url
        self.fileHandle = fileHandle
        self.directoryDescriptor = directoryDescriptor
        self.directoryURL = directoryURL
        self.fileName = fileName
        self.parentDescriptor = parentDescriptor
        self.directoryName = directoryName
        self.directoryIdentity = directoryIdentity
        self.fileIdentity = fileIdentity
    }

    public var isClosedForHandoff: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handedOff
    }

    public func closeForHandoff() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned, !handedOff else { return }
        var writerStatus = stat()
        guard fstat(fileHandle.fileDescriptor, &writerStatus) == 0,
              (writerStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              writerStatus.st_nlink == 1,
              (writerStatus.st_mode & 0o777) == 0o600,
              UInt64(writerStatus.st_dev) == fileIdentity.device,
              UInt64(writerStatus.st_ino) == fileIdentity.inode
        else {
            throw MultipartUploadError.uploadFailed
        }
        let descriptor = try Self.openAndValidateReadOnlyDescriptor(
            directoryDescriptor: directoryDescriptor,
            fileName: fileName,
            identity: fileIdentity,
            expectedSize: writerStatus.st_size
        )
        readOnlyDescriptor = descriptor
        do {
            try fileHandle.close()
        } catch {
            _ = Darwin.close(descriptor)
            readOnlyDescriptor = -1
            throw MultipartUploadError.uploadFailed
        }
        handedOff = true
    }

    /// Open a read-only descriptor pinned to the service-created directory.
    /// The returned descriptor is authoritative for the handler lifetime.
    public func openReadOnlyDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned, handedOff, readOnlyDescriptor >= 0 else {
            throw MultipartUploadError.uploadFailed
        }
        let descriptor = fcntl(readOnlyDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw MultipartUploadError.uploadFailed
        }
        guard Self.validateRegularFileDescriptor(descriptor, identity: fileIdentity, allowUnlinked: true) else {
            _ = Darwin.close(descriptor)
            throw MultipartUploadError.uploadFailed
        }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            _ = Darwin.close(descriptor)
            throw MultipartUploadError.uploadFailed
        }
        return descriptor
    }

    /// Run a synchronous read operation with a descriptor pinned to this
    /// upload. The descriptor closes before this method returns.
    public func withReadOnlyDescriptor<T>(_ operation: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned, handedOff, readOnlyDescriptor >= 0 else {
            throw MultipartUploadError.uploadFailed
        }
        let descriptor = fcntl(readOnlyDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw MultipartUploadError.uploadFailed
        }
        guard Self.validateRegularFileDescriptor(descriptor, identity: fileIdentity, allowUnlinked: true),
              lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            _ = Darwin.close(descriptor)
            throw MultipartUploadError.uploadFailed
        }
        defer { _ = Darwin.close(descriptor) }
        return try operation(descriptor)
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned, !handedOff else {
            throw MultipartUploadError.uploadFailed
        }
        try fileHandle.write(contentsOf: data)
    }

    public func cleanup() {
        lock.lock()
        guard !cleaned else {
            lock.unlock()
            return
        }
        cleaned = true
        lock.unlock()

        try? fileHandle.close()
        lock.lock()
        let readDescriptor = readOnlyDescriptor
        readOnlyDescriptor = -1
        lock.unlock()
        if readDescriptor >= 0 { _ = Darwin.close(readDescriptor) }
        _ = fileName.withCString { unlinkat(directoryDescriptor, $0, 0) }
        if Self.isOriginalDirectory(
            parentDescriptor: parentDescriptor,
            directoryName: directoryName,
            identity: directoryIdentity
        ) {
            _ = directoryName.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
        }
        _ = Darwin.close(directoryDescriptor)
        _ = Darwin.close(parentDescriptor)
    }

    deinit {
        cleanup()
    }

    private static func openAndValidateReadOnlyDescriptor(
        directoryDescriptor: Int32,
        fileName: String,
        identity: FileIdentity,
        expectedSize: Int64? = nil
    ) throws -> Int32 {
        let descriptor = fileName.withCString { pointer in
            openat(directoryDescriptor, pointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0, validateRegularFileDescriptor(descriptor, identity: identity, expectedSize: expectedSize) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw MultipartUploadError.uploadFailed
        }
        return descriptor
    }

    private static func validateRegularFileDescriptor(
        _ descriptor: Int32,
        identity: FileIdentity? = nil,
        expectedSize: Int64? = nil,
        allowUnlinked: Bool = false
    ) -> Bool {
        var status = stat()
        let valid = fstat(descriptor, &status) == 0
            && (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && (status.st_nlink == 1 || (allowUnlinked && status.st_nlink == 0))
            && (status.st_mode & 0o777) == 0o600
        guard valid else { return false }
        guard let identity else { return true }
        return UInt64(status.st_dev) == identity.device
            && UInt64(status.st_ino) == identity.inode
            && (expectedSize == nil || status.st_size == expectedSize)
    }

    private static func isOriginalDirectory(
        parentDescriptor: Int32,
        directoryName: String,
        identity: DirectoryIdentity
    ) -> Bool {
        let descriptor = directoryName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        var status = stat()
        let matches = fstat(descriptor, &status) == 0
            && UInt64(status.st_dev) == identity.device
            && UInt64(status.st_ino) == identity.inode
        _ = Darwin.close(descriptor)
        return matches
    }
}

public struct MultipartUpload: Sendable {
    public let fields: [String: [String]]
    public let file: UploadedFile

    public func cleanup() {
        file.cleanup()
    }
}

public struct MultipartUploadParser: Sendable {
    private enum State: Sendable {
        case preamble(index: Int)
        case headers
        case body
        case boundarySuffix
        case nextPart
        case finalBoundary
        case finalBoundaryCR
        case finalBoundaryLF
        case done
        case error
    }

    private struct Part: Sendable {
        let name: String
        let isFile: Bool
    }

    private let boundary: [UInt8]
    private let initialBoundary: [UInt8]
    private let delimiter: [UInt8]
    private let limits: MultipartLimits
    private let serviceDirectory: URL
    private let directoryName: String
    private let directoryIdentity: DirectoryIdentity
    private var directoryDescriptor: Int32
    private var parentDescriptor: Int32
    private let parentOpenHook: (@Sendable (URL) throws -> Void)?
    private let fileHandoffHook: (@Sendable (URL) throws -> Void)?

    private var state: State
    private var headerBuffer: [UInt8] = []
    private var currentHeaderLineBytes = 0
    private var previousHeaderByte: UInt8?
    private var delimiterBuffer: [UInt8] = []
    private var currentPart: Part?
    private var file: UploadedFile?
    private var fields: [String: [String]] = [:]
    private var fieldBuffer: [UInt8] = []
    private var fileBuffer: [UInt8] = []
    private var fileByteCount = 0
    private var aggregateFieldByteCount = 0
    private var partCount = 0
    private var filePartCount = 0
    private var textFieldCount = 0
    private var envelopeByteCount = 0

    public init(
        boundary: String,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        limits: MultipartLimits = .default,
        directoryOpenHook: (@Sendable (URL) throws -> Void)? = nil,
        parentOpenHook: (@Sendable (URL) throws -> Void)? = nil,
        fileHandoffHook: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        let bytes = Array(boundary.utf8)
        guard Self.isValidBoundary(bytes, maximum: limits.boundaryBytes) else {
            throw MultipartUploadError.malformedMultipart
        }
        guard limits.partHeaderBytes > 0,
              limits.partHeaderLineBytes > 0,
              limits.bodyBufferBytes > 0,
              limits.delimiterBytes >= bytes.count + 4
        else {
            throw MultipartUploadError.uploadFailed
        }

        guard let parent = Self.openDirectory(at: temporaryRoot, requirePrivate: false) else {
            throw MultipartUploadError.uploadFailed
        }
        let directoryName = "syrinx-upload-\(UUID().uuidString)"
        let directory = temporaryRoot.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try parentOpenHook?(temporaryRoot)
            guard mkdirat(parent.descriptor, directoryName, mode_t(0o700)) == 0 else {
                throw MultipartUploadError.uploadFailed
            }
            try directoryOpenHook?(directory)
        } catch {
            _ = directoryName.withCString { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
            _ = Darwin.close(parent.descriptor)
            throw MultipartUploadError.uploadFailed
        }

        guard let openedDirectory = Self.openDirectory(
            parentDescriptor: parent.descriptor,
            directoryName: directoryName,
            requirePrivate: true
        ) else {
            _ = directoryName.withCString { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
            _ = Darwin.close(parent.descriptor)
            throw MultipartUploadError.uploadFailed
        }

        self.boundary = bytes
        self.initialBoundary = Array("--".utf8) + bytes + Array("\r\n".utf8)
        self.delimiter = Array("\r\n--".utf8) + bytes
        self.limits = limits
        self.serviceDirectory = directory
        self.directoryName = directoryName
        self.directoryIdentity = openedDirectory.identity
        self.directoryDescriptor = openedDirectory.descriptor
        self.parentDescriptor = parent.descriptor
        self.parentOpenHook = parentOpenHook
        self.fileHandoffHook = fileHandoffHook
        self.state = .preamble(index: 0)
        self.fileBuffer.reserveCapacity(limits.bodyBufferBytes)
        self.fieldBuffer.reserveCapacity(limits.bodyBufferBytes)
        self.headerBuffer.reserveCapacity(limits.partHeaderBytes)
        self.delimiterBuffer.reserveCapacity(limits.delimiterBytes)
    }

    public mutating func consume(_ bytes: some Collection<UInt8>) throws {
        do {
            for byte in bytes {
                try consume(byte)
            }
        } catch {
            state = .error
            cleanup()
            throw error
        }
    }

    public mutating func finish() throws -> MultipartUpload {
        guard case .done = state else {
            state = .error
            cleanup()
            throw MultipartUploadError.truncatedMultipart
        }
        guard let file else {
            state = .error
            cleanup()
            throw MultipartUploadError.malformedMultipart
        }
        do {
            try fileHandoffHook?(serviceDirectory)
            try file.closeForHandoff()
        } catch {
            state = .error
            cleanup()
            throw MultipartUploadError.uploadFailed
        }
        return MultipartUpload(fields: fields, file: file)
    }

    public mutating func cleanup() {
        state = .error
        file?.cleanup()
        file = nil
        if directoryDescriptor >= 0 {
            _ = Darwin.close(directoryDescriptor)
            directoryDescriptor = -1
        }
        if parentDescriptor >= 0 {
            if Self.isOriginalDirectory(
                parentDescriptor: parentDescriptor,
                directoryName: directoryName,
                identity: directoryIdentity
            ) {
                _ = directoryName.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            }
            _ = Darwin.close(parentDescriptor)
            parentDescriptor = -1
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard envelopeByteCount < limits.envelopeBytes else {
            throw MultipartUploadError.uploadTooLarge
        }
        envelopeByteCount += 1
        switch state {
        case .preamble(let index):
            guard byte == initialBoundary[index] else {
                throw MultipartUploadError.malformedMultipart
            }
            state = index + 1 == initialBoundary.count ? .headers : .preamble(index: index + 1)
        case .headers:
            try consumeHeaderByte(byte)
        case .body:
            try consumeBodyByte(byte)
        case .boundarySuffix:
            try consumeBoundarySuffix(byte)
        case .nextPart:
            guard byte == 0x0A else {
                throw MultipartUploadError.malformedMultipart
            }
            resetPartState()
            state = .headers
        case .finalBoundary:
            guard byte == 0x2D else {
                throw MultipartUploadError.malformedMultipart
            }
            state = .finalBoundaryCR
        case .finalBoundaryCR:
            guard byte == 0x0D else {
                throw MultipartUploadError.malformedMultipart
            }
            state = .finalBoundaryLF
        case .finalBoundaryLF:
            guard byte == 0x0A else {
                throw MultipartUploadError.malformedMultipart
            }
            state = .done
        case .done:
            throw MultipartUploadError.malformedMultipart
        case .error:
            throw MultipartUploadError.uploadFailed
        }
    }

    private mutating func consumeHeaderByte(_ byte: UInt8) throws {
        guard headerBuffer.count < limits.partHeaderBytes,
              currentHeaderLineBytes < limits.partHeaderLineBytes
        else {
            throw MultipartUploadError.uploadTooLarge
        }
        guard byte >= 0x20 || byte == 0x0D || byte == 0x0A || byte == 0x09 else {
            throw MultipartUploadError.malformedMultipart
        }
        headerBuffer.append(byte)
        currentHeaderLineBytes += 1
        if byte == 0x0A {
            guard previousHeaderByte == 0x0D else {
                throw MultipartUploadError.malformedMultipart
            }
            if currentHeaderLineBytes == 2 {
                let part = try parsePartHeaders(headerBuffer)
                headerBuffer.removeAll(keepingCapacity: true)
                currentHeaderLineBytes = 0
                previousHeaderByte = nil
                currentPart = part
                partCount += 1
                guard partCount <= limits.parts else {
                    throw MultipartUploadError.uploadTooLarge
                }
                if part.isFile {
                    filePartCount += 1
                    guard filePartCount <= limits.fileParts else {
                        throw MultipartUploadError.uploadTooLarge
                    }
                    try createFile()
                } else {
                    textFieldCount += 1
                    guard textFieldCount <= limits.textFields else {
                        throw MultipartUploadError.uploadTooLarge
                    }
                }
                state = .body
            }
            currentHeaderLineBytes = 0
        }
        previousHeaderByte = byte
    }

    private mutating func consumeBodyByte(_ byte: UInt8) throws {
        if delimiterBuffer.isEmpty {
            if byte == delimiter[0] {
                delimiterBuffer.append(byte)
            } else {
                try appendBodyByte(byte)
            }
            return
        }

        if delimiterBuffer.count < delimiter.count,
           byte == delimiter[delimiterBuffer.count]
        {
            delimiterBuffer.append(byte)
            if delimiterBuffer.count == delimiter.count {
                try finishCurrentPart()
                delimiterBuffer.removeAll(keepingCapacity: true)
                state = .boundarySuffix
            }
            return
        }

        let pending = delimiterBuffer
        delimiterBuffer.removeAll(keepingCapacity: true)
        for pendingByte in pending {
            try appendBodyByte(pendingByte)
        }
        try consumeBodyByte(byte)
    }

    private mutating func consumeBoundarySuffix(_ byte: UInt8) throws {
        if byte == 0x2D {
            state = .finalBoundary
        } else if byte == 0x0D {
            state = .nextPart
        } else {
            throw MultipartUploadError.malformedMultipart
        }
    }

    private mutating func appendBodyByte(_ byte: UInt8) throws {
        guard let currentPart else {
            throw MultipartUploadError.malformedMultipart
        }
        if currentPart.isFile {
            guard fileByteCount < limits.fileBytes else {
                throw MultipartUploadError.uploadTooLarge
            }
            fileByteCount += 1
            fileBuffer.append(byte)
            if fileBuffer.count == limits.bodyBufferBytes {
                try flushFileBuffer()
            }
        } else {
            guard aggregateFieldByteCount < limits.fieldBytes else {
                throw MultipartUploadError.uploadTooLarge
            }
            guard fieldBuffer.count < limits.bodyBufferBytes else {
                throw MultipartUploadError.uploadTooLarge
            }
            aggregateFieldByteCount += 1
            fieldBuffer.append(byte)
        }
    }

    private mutating func finishCurrentPart() throws {
        guard let currentPart else {
            throw MultipartUploadError.malformedMultipart
        }
        if currentPart.isFile {
            try flushFileBuffer()
        } else {
            guard let value = String(bytes: fieldBuffer, encoding: .utf8) else {
                throw MultipartUploadError.malformedMultipart
            }
            fields[currentPart.name, default: []].append(value)
            fieldBuffer.removeAll(keepingCapacity: true)
        }
    }

    private mutating func flushFileBuffer() throws {
        guard !fileBuffer.isEmpty else { return }
        guard let file else {
            throw MultipartUploadError.uploadFailed
        }
        do {
            try file.write(Data(fileBuffer))
        } catch {
            throw MultipartUploadError.uploadFailed
        }
        fileBuffer.removeAll(keepingCapacity: true)
    }

    private mutating func createFile() throws {
        let name = UUID().uuidString
        let descriptor = name.withCString { pointer in
            openat(
                directoryDescriptor,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw MultipartUploadError.uploadFailed
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            _ = Darwin.close(descriptor)
            _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
            throw MultipartUploadError.uploadFailed
        }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1,
              (fileStatus.st_mode & 0o777) == 0o600
        else {
            _ = Darwin.close(descriptor)
            _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
            throw MultipartUploadError.uploadFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        file = UploadedFile(
            url: serviceDirectory.appendingPathComponent(name),
            fileHandle: handle,
            directoryDescriptor: directoryDescriptor,
            directoryURL: serviceDirectory,
            fileName: name,
            parentDescriptor: parentDescriptor,
            directoryName: directoryName,
            directoryIdentity: directoryIdentity,
            fileIdentity: FileIdentity(
                device: UInt64(fileStatus.st_dev),
                inode: UInt64(fileStatus.st_ino)
            )
        )
        directoryDescriptor = -1
        parentDescriptor = -1
    }

    private mutating func resetPartState() {
        currentPart = nil
        fieldBuffer.removeAll(keepingCapacity: true)
        fileBuffer.removeAll(keepingCapacity: true)
        delimiterBuffer.removeAll(keepingCapacity: true)
        currentHeaderLineBytes = 0
        previousHeaderByte = nil
    }

    private func parsePartHeaders(_ bytes: [UInt8]) throws -> Part {
        guard bytes.count >= 2 else {
            throw MultipartUploadError.malformedMultipart
        }
        let content = bytes.dropLast(2)
        var headers: [String: String] = [:]
        var start = content.startIndex
        while start < content.endIndex {
            guard let lineEnd = content[start...].firstIndex(of: 0x0D),
                  lineEnd + 1 < content.endIndex,
                  content[lineEnd + 1] == 0x0A
            else {
                throw MultipartUploadError.malformedMultipart
            }
            let line = Array(content[start..<lineEnd])
            guard let colon = line.firstIndex(of: 0x3A), colon > 0 else {
                throw MultipartUploadError.malformedMultipart
            }
            let name = String(decoding: line[..<colon], as: UTF8.self).lowercased()
            let value = String(decoding: line[(colon + 1)...], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else {
                throw MultipartUploadError.malformedMultipart
            }
            headers[name] = value
            start = lineEnd + 2
        }

        guard let disposition = headers["content-disposition"] else {
            throw MultipartUploadError.malformedMultipart
        }
        if let contentType = headers["content-type"], contentType.lowercased().hasPrefix("multipart/") {
            throw MultipartUploadError.unsupportedMultipart
        }
        let parameters = try parseDisposition(disposition)
        guard parameters.type == "form-data", let name = parameters.name, !name.isEmpty else {
            throw MultipartUploadError.malformedMultipart
        }
        if parameters.filename != nil {
            guard name == "file" else {
                throw MultipartUploadError.unsupportedMultipart
            }
        } else if name == "file" {
            throw MultipartUploadError.unsupportedMultipart
        }
        return Part(name: name, isFile: parameters.filename != nil)
    }

    private func parseDisposition(_ value: String) throws -> (type: String, name: String?, filename: String?) {
        let components = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = components.first else {
            throw MultipartUploadError.malformedMultipart
        }
        var name: String?
        var filename: String?
        var seen: Set<String> = []
        for component in components.dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                throw MultipartUploadError.malformedMultipart
            }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard seen.insert(key).inserted, key == "name" || key == "filename" else {
                throw MultipartUploadError.unsupportedMultipart
            }
            let raw = pair[1].trimmingCharacters(in: .whitespaces)
            guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else {
                throw MultipartUploadError.malformedMultipart
            }
            let parsed = String(raw.dropFirst().dropLast())
            guard !parsed.contains("\r"), !parsed.contains("\n"), !parsed.contains("\0") else {
                throw MultipartUploadError.malformedMultipart
            }
            if key == "name" { name = parsed } else { filename = parsed }
        }
        return (first.trimmingCharacters(in: .whitespaces).lowercased(), name, filename)
    }

    private static func isValidBoundary(_ bytes: [UInt8], maximum: Int) -> Bool {
        guard (1...maximum).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            guard (0x21...0x7E).contains(byte) else { return false }
            return ![0x22, 0x28, 0x29, 0x2C, 0x2F, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x5B, 0x5C, 0x5D].contains(byte)
        }
    }

    private static func openDirectory(at directory: URL, requirePrivate: Bool) -> OpenDirectory? {
        var pathStatus = stat()
        let pathStatusResult = directory.path.withCString { lstat($0, &pathStatus) }
        guard pathStatusResult == 0, isDirectory(pathStatus, requirePrivate: requirePrivate) else { return nil }
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              isDirectory(descriptorStatus, requirePrivate: requirePrivate),
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino
        else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return OpenDirectory(
            descriptor: descriptor,
            identity: DirectoryIdentity(device: UInt64(descriptorStatus.st_dev), inode: UInt64(descriptorStatus.st_ino))
        )
    }

    private static func openDirectory(
        parentDescriptor: Int32,
        directoryName: String,
        requirePrivate: Bool
    ) -> OpenDirectory? {
        guard parentDescriptor >= 0 else { return nil }
        var pathStatus = stat()
        let pathStatusResult = directoryName.withCString {
            fstatat(parentDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard pathStatusResult == 0, isDirectory(pathStatus, requirePrivate: requirePrivate) else { return nil }

        let descriptor = directoryName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }

        var descriptorStatus = stat()
        let validDescriptor = fstat(descriptor, &descriptorStatus) == 0
            && isDirectory(descriptorStatus, requirePrivate: requirePrivate)
            && descriptorStatus.st_dev == pathStatus.st_dev
            && descriptorStatus.st_ino == pathStatus.st_ino
        guard validDescriptor else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return OpenDirectory(
            descriptor: descriptor,
            identity: DirectoryIdentity(device: UInt64(descriptorStatus.st_dev), inode: UInt64(descriptorStatus.st_ino))
        )
    }

    private static func isOriginalDirectory(
        parentDescriptor: Int32,
        directoryName: String,
        identity: DirectoryIdentity
    ) -> Bool {
        let descriptor = directoryName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        var status = stat()
        let matches = fstat(descriptor, &status) == 0
            && UInt64(status.st_dev) == identity.device
            && UInt64(status.st_ino) == identity.inode
        _ = Darwin.close(descriptor)
        return matches
    }

    private static func isDirectory(_ status: stat, requirePrivate: Bool) -> Bool {
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (!requirePrivate || (status.st_mode & 0o777) == 0o700)
    }
}

public func parseMultipartBoundary(_ contentType: String, maximum: Int = 70) throws -> String {
    let components = contentType.split(separator: ";", omittingEmptySubsequences: false)
    guard let mediaType = components.first?.trimmingCharacters(in: .whitespaces).lowercased(),
          mediaType == "multipart/form-data"
    else {
        throw MultipartUploadError.unsupportedMultipart
    }
    var boundary: String?
    for component in components.dropFirst() {
        let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { throw MultipartUploadError.malformedMultipart }
        let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "boundary", boundary == nil else {
            throw MultipartUploadError.malformedMultipart
        }
        let raw = pair[1].trimmingCharacters(in: .whitespaces)
        if raw.first == "\"" && raw.last == "\"" {
            boundary = String(raw.dropFirst().dropLast())
        } else {
            boundary = raw
        }
    }
    guard let boundary, MultipartUploadParser.isValidBoundaryForPublicUse(boundary, maximum: maximum) else {
        throw MultipartUploadError.malformedMultipart
    }
    return boundary
}

extension MultipartUploadParser {
    fileprivate static func isValidBoundaryForPublicUse(_ value: String, maximum: Int) -> Bool {
        isValidBoundary(Array(value.utf8), maximum: maximum)
    }
}
