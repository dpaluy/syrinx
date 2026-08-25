import Darwin
import Foundation

public struct InstalledRevision: Codable, Equatable, Sendable {
    public let immutableCommit: String
    public let modelId: String
    public let variantId: String
    public let verifiedAt: Date

    public init(immutableCommit: String, modelId: String, variantId: String, verifiedAt: Date) {
        self.immutableCommit = immutableCommit
        self.modelId = modelId
        self.variantId = variantId
        self.verifiedAt = verifiedAt
    }
}

public struct InstalledState: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let modelId: String
    public let variantId: String
    public let revisions: [InstalledRevision]

    public init(
        schemaVersion: Int = InstalledState.supportedSchemaVersion,
        modelId: String,
        variantId: String,
        revisions: [InstalledRevision]
    ) {
        self.schemaVersion = schemaVersion
        self.modelId = modelId
        self.variantId = variantId
        self.revisions = revisions
    }
}

public struct SelectionState: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let modelId: String
    public let variantId: String
    public let currentRevision: String
    public let priorRevision: String?
    public let verifiedAt: Date

    public init(
        schemaVersion: Int = SelectionState.supportedSchemaVersion,
        modelId: String,
        variantId: String,
        currentRevision: String,
        priorRevision: String?,
        verifiedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.modelId = modelId
        self.variantId = variantId
        self.currentRevision = currentRevision
        self.priorRevision = priorRevision
        self.verifiedAt = verifiedAt
    }
}

public enum ModelStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case rootMissing
    case rootIsSymlink
    case rootIsNotDirectory
    case stateIsSymlink
    case stateIsNotRegular
    case stateIsNotPrivate
    case malformedState
    case unsupportedSchema(Int)
    case invalidCommit
    case inconsistentModelVariant
    case duplicateRevision
    case emptyInstalledState
    case selectionNotInstalled
    case selectionMatchesCurrent
    case revisionNotInstalled
    case revisionAlreadyRecorded
    case stateWriteFailed

    public var description: String {
        switch self {
        case .rootMissing:
            return "model store root is missing"
        case .rootIsSymlink:
            return "model store root must not be a symlink"
        case .rootIsNotDirectory:
            return "model store root must be a directory"
        case .stateIsSymlink:
            return "model store state must not be a symlink"
        case .stateIsNotRegular:
            return "model store state must be a regular file"
        case .stateIsNotPrivate:
            return "model store state must be private"
        case .malformedState:
            return "model store state is malformed"
        case let .unsupportedSchema(schema):
            return "model store state has unsupported schema \(schema)"
        case .invalidCommit:
            return "model store state has an invalid immutable commit"
        case .inconsistentModelVariant:
            return "model store state has inconsistent model metadata"
        case .duplicateRevision:
            return "model store state has duplicate revisions"
        case .emptyInstalledState:
            return "model store state has no installed revisions"
        case .selectionNotInstalled:
            return "model selection is not installed"
        case .selectionMatchesCurrent:
            return "model selection already uses this revision"
        case .revisionNotInstalled:
            return "model revision is not installed"
        case .revisionAlreadyRecorded:
            return "model revision is already recorded"
        case .stateWriteFailed:
            return "model store state could not be written"
        }
    }
}

public protocol ModelStoreLock: Sendable {
    func withLock<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
}

/// This lock is retained for deterministic in-process tests.
public actor InProcessModelStoreLock: ModelStoreLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}

public final class ModelStore: @unchecked Sendable {
    public let root: URL
    public let modelsDirectory: URL
    public let revisionsDirectory: URL
    public let downloadsDirectory: URL
    public let locksDirectory: URL

    private let writer: AtomicStateWriter

    public init(root: URL, writer: AtomicStateWriter = AtomicStateWriter()) {
        self.root = root
        modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        revisionsDirectory = root.appendingPathComponent("models/revisions", isDirectory: true)
        downloadsDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        locksDirectory = root.appendingPathComponent("locks", isDirectory: true)
        self.writer = writer
    }

    public func prepareDirectories() throws {
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(modelsDirectory)
        try ensurePrivateDirectory(revisionsDirectory)
        try ensurePrivateDirectory(downloadsDirectory)
        try ensurePrivateDirectory(locksDirectory)
    }

    public func readInstalled() throws -> InstalledState? {
        try validateRootIfPresent()
        guard let data = try readState(named: "installed.json") else { return nil }
        let state = try decode(InstalledState.self, data: data)
        try validate(state)
        return state
    }

    public func readSelection() throws -> SelectionState? {
        try validateRootIfPresent()
        guard let data = try readState(named: "selection.json") else { return nil }
        let selection = try decode(SelectionState.self, data: data)
        try validate(selection)
        guard let installed = try readInstalled(),
              installed.revisions.contains(where: { $0.immutableCommit == selection.currentRevision }),
              selection.priorRevision == nil || installed.revisions.contains(where: { $0.immutableCommit == selection.priorRevision })
        else {
            throw ModelStoreError.selectionNotInstalled
        }
        return selection
    }

    public func revisionURL(for immutableCommit: String) -> URL {
        revisionsDirectory.appendingPathComponent(immutableCommit, isDirectory: true)
            .appendingPathComponent(ModelManifest.supportedRepositoryFolder, isDirectory: true)
    }

    @discardableResult
    public func recordVerifiedRevision(
        manifest: ModelManifest,
        verifiedAt: Date
    ) throws -> InstalledState {
        try prepareDirectories()
        guard Self.isValidImmutableCommit(manifest.immutableCommit) else {
            throw ModelStoreError.invalidCommit
        }
        let oldData = try readState(named: "installed.json")
        let oldState: InstalledState?
        if let oldData {
            oldState = try decode(InstalledState.self, data: oldData)
            if let oldState { try validate(oldState) }
        } else {
            oldState = nil
        }

        let revision = InstalledRevision(
            immutableCommit: manifest.immutableCommit,
            modelId: manifest.modelId,
            variantId: manifest.variantId,
            verifiedAt: verifiedAt
        )
        var revisions = oldState?.revisions ?? []
        if let index = revisions.firstIndex(where: { $0.immutableCommit == revision.immutableCommit }) {
            revisions[index] = revision
        } else {
            revisions.append(revision)
        }
        let state = InstalledState(
            modelId: manifest.modelId,
            variantId: manifest.variantId,
            revisions: revisions
        )
        try validate(state)
        do {
            try writer.write(state, to: installedURL)
        } catch {
            throw mapWriterError(error)
        }
        return state
    }

    public func activate(manifest: ModelManifest, verifiedAt: Date) throws -> SelectionState {
        guard let installed = try readInstalled(),
              installed.revisions.contains(where: { $0.immutableCommit == manifest.immutableCommit })
        else {
            throw ModelStoreError.revisionNotInstalled
        }
        let previous = try readSelection()
        if previous?.currentRevision == manifest.immutableCommit {
            throw ModelStoreError.selectionMatchesCurrent
        }
        let selection = SelectionState(
            modelId: manifest.modelId,
            variantId: manifest.variantId,
            currentRevision: manifest.immutableCommit,
            priorRevision: previous?.currentRevision,
            verifiedAt: verifiedAt
        )
        try validate(selection)
        do {
            try writer.write(selection, to: selectionURL)
        } catch {
            throw mapWriterError(error)
        }
        return selection
    }

    internal func restoreInstalledState(_ data: Data?) throws {
        try prepareDirectories()
        if let data {
            try AtomicStateWriter().write(data, to: installedURL)
        } else {
            let descriptor = open(modelsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ModelStoreError.stateWriteFailed }
            defer { close(descriptor) }
            guard unlinkat(descriptor, "installed.json", 0) == 0 || errno == ENOENT,
                  fsync(descriptor) == 0
            else {
                throw ModelStoreError.stateWriteFailed
            }
        }
    }

    internal func installedStateData() throws -> Data? {
        try validateRootIfPresent()
        return try readState(named: "installed.json")
    }

    internal func selectionStateData() throws -> Data? {
        try validateRootIfPresent()
        return try readState(named: "selection.json")
    }

    internal func lifecycleJournalData() throws -> Data? {
        try validateRootIfPresent()
        return try readState(named: "lifecycle.json")
    }

    internal func writeInstalledState(_ state: InstalledState) throws {
        try validate(state)
        do {
            try writer.write(state, to: installedURL)
        } catch {
            throw mapWriterError(error)
        }
    }

    internal func writeSelectionState(_ selection: SelectionState) throws {
        try validate(selection)
        do {
            try writer.write(selection, to: selectionURL)
        } catch {
            throw mapWriterError(error)
        }
    }

    internal func writeLifecycleJournal(_ data: Data) throws {
        try prepareDirectories()
        do {
            try writer.write(data, to: modelsDirectory.appendingPathComponent("lifecycle.json"))
        } catch {
            throw mapWriterError(error)
        }
    }

    internal func clearLifecycleJournal() throws {
        try prepareDirectories()
        let descriptor = open(modelsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ModelStoreError.stateWriteFailed }
        defer { close(descriptor) }
        guard unlinkat(descriptor, "lifecycle.json", 0) == 0 || errno == ENOENT,
              fsync(descriptor) == 0
        else {
            throw ModelStoreError.stateWriteFailed
        }
    }

    internal func restoreSelectionState(_ data: Data?) throws {
        try prepareDirectories()
        if let data {
            try AtomicStateWriter().write(data, to: selectionURL)
        } else {
            let descriptor = open(modelsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ModelStoreError.stateWriteFailed }
            defer { close(descriptor) }
            guard unlinkat(descriptor, "selection.json", 0) == 0 || errno == ENOENT,
                  fsync(descriptor) == 0
            else {
                throw ModelStoreError.stateWriteFailed
            }
        }
    }

    internal var installedURL: URL { modelsDirectory.appendingPathComponent("installed.json") }
    internal var selectionURL: URL { modelsDirectory.appendingPathComponent("selection.json") }

    private func validateRootIfPresent() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ModelStoreError.rootIsNotDirectory
        }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw ModelStoreError.rootIsSymlink }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ModelStoreError.rootIsNotDirectory }
    }

    private func readState(named name: String) throws -> Data? {
        try validateModelsDirectoryIfPresent()
        let url = modelsDirectory.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ModelStoreError.stateIsNotRegular
        }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw ModelStoreError.stateIsSymlink }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ModelStoreError.stateIsNotRegular }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ModelStoreError.stateIsNotRegular }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_dev == info.st_dev,
              opened.st_ino == info.st_ino
        else { throw ModelStoreError.stateIsNotRegular }
        guard (opened.st_mode & 0o077) == 0 else {
            throw ModelStoreError.stateIsNotPrivate
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 { throw ModelStoreError.malformedState }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            if case let .keyNotFound(key, _) = error,
               key.stringValue == "schemaVersion" {
                throw ModelStoreError.malformedState
            }
            throw ModelStoreError.malformedState
        } catch {
            throw ModelStoreError.malformedState
        }
    }

    private func validate(_ state: InstalledState) throws {
        guard state.schemaVersion == InstalledState.supportedSchemaVersion else {
            throw ModelStoreError.unsupportedSchema(state.schemaVersion)
        }
        guard state.modelId == ModelManifest.supportedModelID,
              state.variantId == ModelManifest.supportedVariantID
        else { throw ModelStoreError.inconsistentModelVariant }
        guard !state.revisions.isEmpty else { throw ModelStoreError.emptyInstalledState }
        var commits = Set<String>()
        for revision in state.revisions {
            guard Self.isValidImmutableCommit(revision.immutableCommit) else {
                throw ModelStoreError.invalidCommit
            }
            guard revision.modelId == state.modelId,
                  revision.variantId == state.variantId
            else { throw ModelStoreError.inconsistentModelVariant }
            guard commits.insert(revision.immutableCommit).inserted else {
                throw ModelStoreError.duplicateRevision
            }
        }
    }

    private func validate(_ selection: SelectionState) throws {
        guard selection.schemaVersion == SelectionState.supportedSchemaVersion else {
            throw ModelStoreError.unsupportedSchema(selection.schemaVersion)
        }
        guard selection.modelId == ModelManifest.supportedModelID,
              selection.variantId == ModelManifest.supportedVariantID
        else { throw ModelStoreError.inconsistentModelVariant }
        guard Self.isValidImmutableCommit(selection.currentRevision) else {
            throw ModelStoreError.invalidCommit
        }
        if let priorRevision = selection.priorRevision, !Self.isValidImmutableCommit(priorRevision) {
            throw ModelStoreError.invalidCommit
        }
        if selection.priorRevision == selection.currentRevision {
            throw ModelStoreError.inconsistentModelVariant
        }
    }

    internal static func isValidImmutableCommit(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private func ensurePrivateDirectory(_ url: URL, chmodExisting: Bool = true) throws {
        var info = stat()
        let result = lstat(url.path, &info)
        if result == 0 {
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { throw ModelStoreError.rootIsSymlink }
            guard type == S_IFDIR else { throw ModelStoreError.rootIsNotDirectory }
            if chmodExisting, chmod(url.path, mode_t(0o700)) != 0 {
                throw ModelStoreError.rootIsNotDirectory
            }
            return
        }
        let lstatError = errno
        guard lstatError == ENOENT else { throw ModelStoreError.rootIsNotDirectory }
        let parent = url.deletingLastPathComponent()
        try ensurePrivateDirectory(parent, chmodExisting: false)
        let mkdirResult = mkdir(url.path, mode_t(0o700))
        let mkdirError = errno
        guard mkdirResult == 0 || mkdirError == EEXIST else {
            throw ModelStoreError.rootIsNotDirectory
        }
        let verifyResult = lstat(url.path, &info)
        let verifyType = info.st_mode & S_IFMT
        let chmodResult = chmod(url.path, mode_t(0o700))
        guard verifyResult == 0, verifyType == S_IFDIR, chmodResult == 0 else { throw ModelStoreError.rootIsNotDirectory }
    }

    private func validateModelsDirectoryIfPresent() throws {
        var info = stat()
        guard lstat(modelsDirectory.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ModelStoreError.rootIsNotDirectory
        }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw ModelStoreError.rootIsSymlink }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ModelStoreError.rootIsNotDirectory }
    }

    private func mapWriterError(_ error: Error) -> ModelStoreError {
        if error is AtomicStateWriterError { return .stateWriteFailed }
        return .stateWriteFailed
    }
}
