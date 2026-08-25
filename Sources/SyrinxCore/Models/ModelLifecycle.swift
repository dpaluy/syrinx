import Darwin
import Foundation

public enum ModelLifecycleError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidCommit
    case installedStateUnavailable
    case selectionUnavailable
    case candidateNotInstalled
    case candidateVerificationFailed
    case selectionWriteFailed
    case rollbackUnavailable
    case rollbackVerificationFailed
    case runtimeUnavailable
    case unsafeRevision
    case leaseBusy
    case journalWriteFailed
    case deletionFailed
    case installedStateWriteFailed

    public var description: String {
        switch self {
        case .invalidCommit:
            return "model lifecycle received an invalid immutable commit"
        case .installedStateUnavailable:
            return "model lifecycle installed state is unavailable"
        case .selectionUnavailable:
            return "model lifecycle selection is unavailable"
        case .candidateNotInstalled:
            return "model lifecycle candidate revision is not installed"
        case .candidateVerificationFailed:
            return "model lifecycle candidate revision failed verification"
        case .selectionWriteFailed:
            return "model lifecycle selection could not be committed"
        case .rollbackUnavailable:
            return "model lifecycle rollback is unavailable"
        case .rollbackVerificationFailed:
            return "model lifecycle rollback revision failed verification"
        case .runtimeUnavailable:
            return "model lifecycle selected runtime is unavailable"
        case .unsafeRevision:
            return "model lifecycle revision tree is unsafe"
        case .leaseBusy:
            return "model lifecycle revision lease is busy"
        case .journalWriteFailed:
            return "model lifecycle recovery journal could not be committed"
        case .deletionFailed:
            return "model lifecycle revision deletion failed"
        case .installedStateWriteFailed:
            return "model lifecycle installed state could not be committed"
        }
    }
}

public final class ModelRuntimeLease: @unchecked Sendable {
    public let repositoryURL: URL
    public let immutableCommit: String
    public let modelId: String
    public let variantId: String

    private let stateLock = NSLock()
    private var lease: ModelRevisionLease?

    fileprivate init(
        repositoryURL: URL,
        immutableCommit: String,
        modelId: String,
        variantId: String,
        lease: ModelRevisionLease
    ) {
        self.repositoryURL = repositoryURL
        self.immutableCommit = immutableCommit
        self.modelId = modelId
        self.variantId = variantId
        self.lease = lease
    }

    deinit {
        close()
    }

    public func close() {
        stateLock.lock()
        let lease = self.lease
        self.lease = nil
        stateLock.unlock()
        lease?.close()
    }
}

public enum ModelGarbageCollectionSkip: Equatable, Sendable {
    case busy(String)
    case becameLive(String)
    case noLongerInstalled(String)
    case unsafe(String)
}

public struct ModelGarbageCollectionResult: Equatable, Sendable {
    public let deleted: [String]
    public let skipped: [ModelGarbageCollectionSkip]

    public init(deleted: [String], skipped: [ModelGarbageCollectionSkip]) {
        self.deleted = deleted
        self.skipped = skipped
    }
}

@_spi(Testing) public enum ModelLifecycleTestingEvent: Equatable, Sendable {
    case afterRuntimeValidation(String)
    case afterRuntimeLease(String)
    case afterSelectionCommit(String)
    case afterExclusiveLease(String)
    case beforeRevisionDelete(String)
    case afterRevisionDelete(String)
}

@_spi(Testing) public typealias ModelLifecycleTestingHook = @Sendable (ModelLifecycleTestingEvent) async throws -> Void
internal typealias ModelLifecycleHookEvent = ModelLifecycleTestingEvent
internal typealias ModelLifecycleHook = ModelLifecycleTestingHook

private struct ModelLifecycleJournal: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case selection
        case garbageCollection
    }

    let operation: Operation
    let commit: String?
    let oldSelection: Data?
    let newSelection: Data?
}

public final class ModelLifecycleCoordinator: @unchecked Sendable {
    public let manifest: ModelManifest
    public let store: ModelStore

    private let verifier: ModelVerifier
    private let lock: any ModelStoreLock
    private let leases: ModelRevisionLeaseManager
    private let hook: ModelLifecycleHook?

    public convenience init(store: ModelStore) throws {
        guard let manifestURL = Bundle.module.url(
            forResource: "parakeet-tdt-0.6b-v3-int8",
            withExtension: "json"
        ) else {
            throw ModelLifecycleError.installedStateUnavailable
        }
        let manifest: ModelManifest
        do {
            manifest = try ModelManifest(data: Data(contentsOf: manifestURL))
        } catch {
            throw ModelLifecycleError.installedStateUnavailable
        }
        try self.init(validatedManifest: manifest, store: store)
    }

    private init(
        validatedManifest manifest: ModelManifest,
        store: ModelStore
    ) throws {
        self.manifest = manifest
        self.store = store
        self.verifier = ModelVerifier()
        self.lock = try OSBackedModelStoreLock(store: store)
        self.leases = try ModelRevisionLeaseManager(store: store)
        self.hook = nil
    }

    @_spi(Testing) public init(
        testingManifest manifest: ModelManifest,
        store: ModelStore,
        hook: ModelLifecycleTestingHook? = nil
    ) throws {
        self.manifest = manifest
        self.store = store
        self.verifier = ModelVerifier()
        self.lock = try OSBackedModelStoreLock(store: store)
        self.leases = try ModelRevisionLeaseManager(store: store)
        self.hook = hook
    }

    internal init(
        unvalidatedManifestForTesting manifest: ModelManifest,
        store: ModelStore,
        lock: any ModelStoreLock = InProcessModelStoreLock(),
        hook: ModelLifecycleHook? = nil
    ) throws {
        self.manifest = manifest
        self.store = store
        self.verifier = ModelVerifier()
        self.lock = lock
        self.leases = try ModelRevisionLeaseManager(store: store)
        self.hook = hook
    }

    public func activate(
        immutableCommit: String,
        verifiedAt: Date = Date()
    ) async throws -> SelectionState {
        guard ModelStore.isValidImmutableCommit(immutableCommit) else {
            throw ModelLifecycleError.invalidCommit
        }
        do {
            return try await lock.withLock { [self] in
                try recoverSelectionJournalIfNeeded()
                let installed = try installedState()
                guard let candidate = installed.revisions.first(where: { $0.immutableCommit == immutableCommit }) else {
                    throw ModelLifecycleError.candidateNotInstalled
                }
                guard candidate.modelId == manifest.modelId,
                      candidate.variantId == manifest.variantId,
                      verifyCandidate(immutableCommit)
                else {
                    throw ModelLifecycleError.candidateVerificationFailed
                }

                let previous = try store.readSelection()
                if previous?.currentRevision == immutableCommit {
                    guard let previous else { throw ModelLifecycleError.selectionUnavailable }
                    return previous
                }
                let selection = SelectionState(
                    modelId: manifest.modelId,
                    variantId: manifest.variantId,
                    currentRevision: immutableCommit,
                    priorRevision: previous?.currentRevision,
                    verifiedAt: verifiedAt
                )
                try commitSelection(selection, previousData: try store.selectionStateData())
                try await hook?(.afterSelectionCommit(selection.currentRevision))
                return selection
            }
        } catch let error as ModelLifecycleError {
            throw error
        } catch {
            throw mapReadError(error)
        }
    }

    public func rollback(verifiedAt: Date = Date()) async throws -> SelectionState {
        do {
            return try await lock.withLock { [self] in
                try recoverSelectionJournalIfNeeded()
                let installed = try installedState()
                guard let current = try store.readSelection(),
                      let prior = current.priorRevision,
                      installed.revisions.contains(where: { $0.immutableCommit == current.currentRevision }),
                      installed.revisions.contains(where: { $0.immutableCommit == prior })
                else {
                    throw ModelLifecycleError.rollbackUnavailable
                }
                guard verifyCandidate(prior) else {
                    throw ModelLifecycleError.rollbackVerificationFailed
                }
                let selection = SelectionState(
                    modelId: manifest.modelId,
                    variantId: manifest.variantId,
                    currentRevision: prior,
                    priorRevision: current.currentRevision,
                    verifiedAt: verifiedAt
                )
                try commitSelection(selection, previousData: try store.selectionStateData())
                try await hook?(.afterSelectionCommit(selection.currentRevision))
                return selection
            }
        } catch let error as ModelLifecycleError {
            throw error
        } catch {
            throw mapReadError(error)
        }
    }

    public func resolveRuntime() async throws -> ModelRuntimeLease {
        do {
            return try await lock.withLock { [self] in
                try recoverSelectionJournalIfNeeded()
                let installed = try installedState()
                guard let selection = try store.readSelection(),
                      let current = installed.revisions.first(where: { $0.immutableCommit == selection.currentRevision }),
                      current.modelId == manifest.modelId,
                      current.variantId == manifest.variantId
                else {
                    throw ModelLifecycleError.runtimeUnavailable
                }
                let repositoryURL = store.revisionURL(for: selection.currentRevision)
                do {
                    try verifier.verifyStructure(manifest: manifest, at: repositoryURL)
                } catch {
                    throw ModelLifecycleError.runtimeUnavailable
                }
                try await hook?(.afterRuntimeValidation(selection.currentRevision))
                let acquisition = try leases.tryAcquireShared(selection.currentRevision)
                guard case .acquired(let lease) = acquisition else {
                    throw ModelLifecycleError.leaseBusy
                }
                do {
                    try verifier.verifyStructure(manifest: manifest, at: repositoryURL)
                    try await hook?(.afterRuntimeLease(selection.currentRevision))
                } catch {
                    lease.close()
                    throw ModelLifecycleError.runtimeUnavailable
                }
                return ModelRuntimeLease(
                    repositoryURL: repositoryURL,
                    immutableCommit: selection.currentRevision,
                    modelId: current.modelId,
                    variantId: current.variantId,
                    lease: lease
                )
            }
        } catch let error as ModelLifecycleError {
            throw error
        } catch {
            throw ModelLifecycleError.runtimeUnavailable
        }
    }

    public func garbageCollect() async throws -> ModelGarbageCollectionResult {
        do {
            let pendingInfo = try await lock.withLock { [self] in
                try recoverSelectionJournalIfNeeded(allowGarbageCollection: true)
                var journalCandidates = try pendingGarbageCollectionCommits()
                let installed = try installedState()
                guard let selection = try store.readSelection() else {
                    throw ModelLifecycleError.selectionUnavailable
                }
                let live = Set([selection.currentRevision, selection.priorRevision].compactMap { $0 })
                for commit in journalCandidates where !installed.revisions.contains(where: { $0.immutableCommit == commit }) {
                    if try !DescriptorRelativeRevisionDeletion.exists(store: store, immutableCommit: commit) {
                        try store.clearLifecycleJournal()
                        journalCandidates.removeAll { $0 == commit }
                    }
                }
                return (
                    commits: installed.revisions.map(\.immutableCommit).filter { !live.contains($0) } + journalCandidates,
                    journalCandidates: Set(journalCandidates)
                )
            }
            let pending = Array(Set(pendingInfo.commits)).sorted()

            var deleted: [String] = []
            var skipped: [ModelGarbageCollectionSkip] = []
            for commit in pending {
                switch try leases.tryAcquireExclusive(commit) {
                case .busy:
                    skipped.append(.busy(commit))
                case .acquired(let lease):
                    do {
                        let deletionAnchor = try DescriptorRelativeRevisionDeletion.capture(
                            store: store,
                            immutableCommit: commit
                        )
                        try await hook?(.afterExclusiveLease(commit))
                        let outcome = try await lock.withLock { [self] in
                            try recoverSelectionJournalIfNeeded(allowGarbageCollection: true)
                            let installed = try installedState()
                            guard let selection = try store.readSelection() else {
                                throw ModelLifecycleError.selectionUnavailable
                            }
                            let live = Set([selection.currentRevision, selection.priorRevision].compactMap { $0 })
                            guard !live.contains(commit) else { return GarbageCollectionOutcome.becameLive }
                            let isInstalled = installed.revisions.contains(where: { $0.immutableCommit == commit })
                            let isJournalCandidate = pendingInfo.journalCandidates.contains(commit)
                            guard isInstalled || isJournalCandidate else {
                                return GarbageCollectionOutcome.noLongerInstalled
                            }
                            if !isInstalled && isJournalCandidate {
                                if try !DescriptorRelativeRevisionDeletion.exists(store: store, immutableCommit: commit) {
                                    try store.clearLifecycleJournal()
                                    return GarbageCollectionOutcome.noLongerInstalled
                                }
                            }
                            do {
                                try DescriptorRelativeRevisionDeletion.validate(
                                    store: store,
                                    immutableCommit: commit,
                                    anchor: deletionAnchor
                                )
                            } catch let error as ModelLifecycleError where error == .unsafeRevision {
                                return GarbageCollectionOutcome.unsafe
                            }
                            let remaining = InstalledState(
                                modelId: installed.modelId,
                                variantId: installed.variantId,
                                revisions: installed.revisions.filter { $0.immutableCommit != commit }
                            )
                            try beginGarbageCollection(commit: commit)
                            do {
                                try store.writeInstalledState(remaining)
                            } catch {
                                throw ModelLifecycleError.installedStateWriteFailed
                            }
                            do {
                                try await hook?(.beforeRevisionDelete(commit))
                                try DescriptorRelativeRevisionDeletion.delete(
                                    store: store,
                                    immutableCommit: commit,
                                    anchor: deletionAnchor
                                )
                                try await hook?(.afterRevisionDelete(commit))
                            } catch let error as ModelLifecycleError {
                                throw error
                            } catch {
                                throw ModelLifecycleError.deletionFailed
                            }
                            try store.clearLifecycleJournal()
                            return GarbageCollectionOutcome.deleted
                        }
                        lease.close()
                        switch outcome {
                        case .deleted:
                            deleted.append(commit)
                        case .becameLive:
                            skipped.append(.becameLive(commit))
                        case .noLongerInstalled:
                            skipped.append(.noLongerInstalled(commit))
                        case .unsafe:
                            skipped.append(.unsafe(commit))
                        }
                    } catch let error as ModelLifecycleError where error == .unsafeRevision {
                        lease.close()
                        skipped.append(.unsafe(commit))
                    } catch {
                        lease.close()
                        throw error
                    }
                }
            }
            return ModelGarbageCollectionResult(deleted: deleted, skipped: skipped)
        } catch let error as ModelLifecycleError {
            throw error
        } catch let error as ModelStoreError where error == .stateWriteFailed {
            throw ModelLifecycleError.journalWriteFailed
        } catch {
            throw ModelLifecycleError.installedStateUnavailable
        }
    }

    private enum GarbageCollectionOutcome {
        case deleted
        case becameLive
        case noLongerInstalled
        case unsafe
    }

    private func installedState() throws -> InstalledState {
        guard let state = try store.readInstalled() else {
            throw ModelLifecycleError.installedStateUnavailable
        }
        guard state.modelId == manifest.modelId, state.variantId == manifest.variantId else {
            throw ModelLifecycleError.installedStateUnavailable
        }
        return state
    }

    private func verifyCandidate(_ commit: String) -> Bool {
        do {
            try verifier.verify(manifest: manifest, at: store.revisionURL(for: commit))
            return true
        } catch {
            return false
        }
    }

    private func commitSelection(_ selection: SelectionState, previousData: Data?) throws {
        let newData: Data
        do {
            newData = try AtomicStateWriter.defaultEncoder.encode(selection)
        } catch {
            throw ModelLifecycleError.selectionWriteFailed
        }
        let journal = ModelLifecycleJournal(
            operation: .selection,
            commit: nil,
            oldSelection: previousData,
            newSelection: newData
        )
        try writeJournal(journal, error: .selectionWriteFailed)
        do {
            try store.writeSelectionState(selection)
        } catch {
            throw ModelLifecycleError.selectionWriteFailed
        }
        do {
            try store.clearLifecycleJournal()
        } catch {
            throw ModelLifecycleError.journalWriteFailed
        }
    }

    private func beginGarbageCollection(commit: String) throws {
        try writeJournal(
            ModelLifecycleJournal(
                operation: .garbageCollection,
                commit: commit,
                oldSelection: nil,
                newSelection: nil
            ),
            error: .journalWriteFailed
        )
    }

    private func writeJournal(_ journal: ModelLifecycleJournal, error: ModelLifecycleError) throws {
        do {
            let data = try AtomicStateWriter.defaultEncoder.encode(journal)
            try store.writeLifecycleJournal(data)
        } catch {
            throw error
        }
    }

    private func recoverSelectionJournalIfNeeded(allowGarbageCollection: Bool = false) throws {
        guard let data = try store.lifecycleJournalData() else { return }
        let journal: ModelLifecycleJournal
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            journal = try decoder.decode(ModelLifecycleJournal.self, from: data)
        } catch {
            throw ModelLifecycleError.journalWriteFailed
        }
        switch journal.operation {
        case .selection:
            let current = try store.selectionStateData()
            if current != journal.oldSelection && current != journal.newSelection {
                do {
                    if let oldSelection = journal.oldSelection {
                        try AtomicStateWriter().write(oldSelection, to: store.selectionURL)
                    } else {
                        try store.restoreSelectionState(nil)
                    }
                } catch {
                    throw ModelLifecycleError.selectionWriteFailed
                }
            }
            do {
                try store.clearLifecycleJournal()
            } catch {
                throw ModelLifecycleError.journalWriteFailed
            }
        case .garbageCollection:
            guard allowGarbageCollection else {
                throw ModelLifecycleError.journalWriteFailed
            }
        }
    }

    private func pendingGarbageCollectionCommits() throws -> [String] {
        guard let data = try store.lifecycleJournalData() else { return [] }
        let journal: ModelLifecycleJournal
        do {
            journal = try JSONDecoder().decode(ModelLifecycleJournal.self, from: data)
        } catch {
            throw ModelLifecycleError.journalWriteFailed
        }
        guard journal.operation == .garbageCollection,
              let commit = journal.commit,
              ModelStore.isValidImmutableCommit(commit)
        else {
            return []
        }
        return [commit]
    }

    private func mapReadError(_ error: Error) -> ModelLifecycleError {
        if let error = error as? ModelLifecycleError { return error }
        if let error = error as? ModelStoreError, error == .stateWriteFailed {
            return .selectionWriteFailed
        }
        return .installedStateUnavailable
    }
}

private enum DescriptorRelativeRevisionDeletion {
    fileprivate struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(stat: stat) {
            device = stat.st_dev
            inode = stat.st_ino
        }
    }

    fileprivate struct Anchor: Sendable {
        let root: Identity
        let models: Identity
        let revisions: Identity
        let candidate: Identity
    }

    fileprivate static func exists(store: ModelStore, immutableCommit: String) throws -> Bool {
        var info = stat()
        guard lstat(store.revisionsDirectory.appendingPathComponent(immutableCommit).path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw ModelLifecycleError.unsafeRevision
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ModelLifecycleError.unsafeRevision
        }
        return true
    }

    fileprivate static func capture(store: ModelStore, immutableCommit: String) throws -> Anchor {
        guard ModelStore.isValidImmutableCommit(immutableCommit) else {
            throw ModelLifecycleError.invalidCommit
        }
        let root = try openDirectory(store.root.path)
        defer { close(root) }
        let models = try openChildDirectory(root, name: "models")
        defer { close(models) }
        let revisions = try openChildDirectory(models, name: "revisions")
        defer { close(revisions) }
        let candidate = try openPinnedDirectory(revisions, name: immutableCommit)
        defer { close(candidate) }
        var rootInfo = stat()
        var modelsInfo = stat()
        var revisionsInfo = stat()
        var candidateInfo = stat()
        guard fstat(root, &rootInfo) == 0,
              fstat(models, &modelsInfo) == 0,
              fstat(revisions, &revisionsInfo) == 0,
              fstat(candidate, &candidateInfo) == 0
        else { throw ModelLifecycleError.unsafeRevision }
        return Anchor(
            root: Identity(stat: rootInfo),
            models: Identity(stat: modelsInfo),
            revisions: Identity(stat: revisionsInfo),
            candidate: Identity(stat: candidateInfo)
        )
    }

    fileprivate static func delete(
        store: ModelStore,
        immutableCommit: String,
        anchor: Anchor
    ) throws {
        guard ModelStore.isValidImmutableCommit(immutableCommit) else {
            throw ModelLifecycleError.invalidCommit
        }
        let root = try openDirectory(store.root.path)
        defer { close(root) }
        try validatePathIdentity(store.root.path, descriptor: root, expected: anchor.root)
        let models = try openChildDirectory(root, name: "models")
        defer { close(models) }
        try validatePathIdentity(store.root.appendingPathComponent("models").path, descriptor: models, expected: anchor.models)
        let revisions = try openChildDirectory(models, name: "revisions")
        defer { close(revisions) }
        try validatePathIdentity(store.revisionsDirectory.path, descriptor: revisions, expected: anchor.revisions)
        let candidate = try openPinnedDirectory(revisions, name: immutableCommit)
        defer { close(candidate) }
        try validatePathIdentity(store.revisionsDirectory.appendingPathComponent(immutableCommit).path, descriptor: candidate, expected: anchor.candidate)
        try preflight(candidate)
        try removeContents(candidate)
        try validatePathIdentity(
            store.revisionsDirectory.appendingPathComponent(immutableCommit).path,
            descriptor: candidate,
            expected: anchor.candidate
        )
        guard unlinkat(revisions, immutableCommit, AT_REMOVEDIR) == 0 else {
            throw ModelLifecycleError.deletionFailed
        }
        guard fsync(revisions) == 0 else { throw ModelLifecycleError.deletionFailed }
    }

    fileprivate static func validate(
        store: ModelStore,
        immutableCommit: String,
        anchor: Anchor
    ) throws {
        guard ModelStore.isValidImmutableCommit(immutableCommit) else {
            throw ModelLifecycleError.invalidCommit
        }
        let root = try openDirectory(store.root.path)
        defer { close(root) }
        try validatePathIdentity(store.root.path, descriptor: root, expected: anchor.root)
        let models = try openChildDirectory(root, name: "models")
        defer { close(models) }
        try validatePathIdentity(store.root.appendingPathComponent("models").path, descriptor: models, expected: anchor.models)
        let revisions = try openChildDirectory(models, name: "revisions")
        defer { close(revisions) }
        try validatePathIdentity(store.revisionsDirectory.path, descriptor: revisions, expected: anchor.revisions)
        let candidate = try openPinnedDirectory(revisions, name: immutableCommit)
        defer { close(candidate) }
        try validatePathIdentity(store.revisionsDirectory.appendingPathComponent(immutableCommit).path, descriptor: candidate, expected: anchor.candidate)
        try preflight(candidate)
    }

    private static func preflight(_ descriptor: Int32) throws {
        let names = try entries(descriptor)
        for name in names {
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ModelLifecycleError.unsafeRevision
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { throw ModelLifecycleError.unsafeRevision }
            if type == S_IFDIR {
                let child = try openPinnedDirectory(descriptor, name: name, expected: info)
                defer { close(child) }
                try preflight(child)
            } else if type == S_IFREG {
                guard info.st_nlink == 1 else { throw ModelLifecycleError.unsafeRevision }
            } else {
                throw ModelLifecycleError.unsafeRevision
            }
        }
    }

    private static func removeContents(_ descriptor: Int32) throws {
        let names = try entries(descriptor)
        for name in names {
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ModelLifecycleError.deletionFailed
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { throw ModelLifecycleError.unsafeRevision }
            if type == S_IFDIR {
                let child = try openPinnedDirectory(descriptor, name: name, expected: info)
                defer { close(child) }
                try removeContents(child)
                guard directoryIdentity(descriptor, name: name, expected: info) else {
                    throw ModelLifecycleError.deletionFailed
                }
                guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                    throw ModelLifecycleError.deletionFailed
                }
            } else if type == S_IFREG {
                guard info.st_nlink == 1,
                      regularIdentity(descriptor, name: name, expected: info),
                      unlinkat(descriptor, name, 0) == 0
                else {
                    throw ModelLifecycleError.deletionFailed
                }
            } else {
                throw ModelLifecycleError.unsafeRevision
            }
        }
        guard fsync(descriptor) == 0 else { throw ModelLifecycleError.deletionFailed }
    }

    private static func entries(_ descriptor: Int32) throws -> [String] {
        let fresh = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fresh >= 0 else { throw ModelLifecycleError.deletionFailed }
        var anchor = stat()
        var opened = stat()
        guard fstat(descriptor, &anchor) == 0,
              fstat(fresh, &opened) == 0,
              anchor.st_dev == opened.st_dev,
              anchor.st_ino == opened.st_ino,
              let directory = fdopendir(fresh)
        else {
            close(fresh)
            throw ModelLifecycleError.deletionFailed
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

    private static func openDirectory(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelLifecycleError.unsafeRevision }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw ModelLifecycleError.unsafeRevision
        }
        return descriptor
    }

    private static func openChildDirectory(_ parent: Int32, name: String) throws -> Int32 {
        try openPinnedDirectory(parent, name: name)
    }

    private static func openPinnedDirectory(_ parent: Int32, name: String, expected: stat? = nil) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelLifecycleError.unsafeRevision }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              expected.map({ $0.st_dev == opened.st_dev && $0.st_ino == opened.st_ino }) ?? true
        else {
            close(descriptor)
            throw ModelLifecycleError.unsafeRevision
        }
        return descriptor
    }

    private static func validatePathIdentity(_ path: String, descriptor: Int32, expected: Identity) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ModelLifecycleError.unsafeRevision }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_dev == opened.st_dev,
              info.st_ino == opened.st_ino,
              info.st_dev == expected.device,
              info.st_ino == expected.inode
        else { throw ModelLifecycleError.unsafeRevision }
    }

    private static func directoryIdentity(_ parent: Int32, name: String, expected: stat) -> Bool {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
            (info.st_mode & S_IFMT) == S_IFDIR &&
            info.st_dev == expected.st_dev && info.st_ino == expected.st_ino
    }

    private static func regularIdentity(_ parent: Int32, name: String, expected: stat) -> Bool {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
            (info.st_mode & S_IFMT) == S_IFREG &&
            info.st_nlink == 1 &&
            info.st_dev == expected.st_dev && info.st_ino == expected.st_ino
    }
}
