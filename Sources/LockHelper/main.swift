import Darwin
import Foundation
@_spi(Testing) import SyrinxCore

@main
struct LockHelper {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            print("error:\(String(describing: error))")
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let mode = arguments.first else { throw HelperError.invalidArguments }
        switch mode {
        case "global-hold":
            let root = try rootURL(arguments, at: 1)
            let ready = try fileURL(arguments, at: 2)
            let release = try fileURL(arguments, at: 3)
            let lock = try OSBackedModelStoreLock(store: ModelStore(root: root))
            try await lock.withLock {
                touch(ready)
                try await waitForFile(release)
            }
            print("released")
        case "global-attempt":
            let root = try rootURL(arguments, at: 1)
            let timeout = try duration(arguments, at: 2)
            let lock = try OSBackedModelStoreLock(store: ModelStore(root: root))
            do {
                _ = try await lock.withLock(timeout: timeout) { "acquired" }
                exit(0)
            } catch let error as ModelStoreLockError where error == .timedOut {
                exit(2)
            }
        case "shared-hold":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let ready = try fileURL(arguments, at: 3)
            let release = try fileURL(arguments, at: 4)
            let manager = try ModelRevisionLeaseManager(store: ModelStore(root: root))
            let lease = try await manager.acquireShared(commit)
            touch(ready)
            try await waitForFile(release)
            lease.close()
            print("released")
        case "shared-attempt":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let manager = try ModelRevisionLeaseManager(store: ModelStore(root: root))
            switch try manager.tryAcquireShared(commit) {
            case .acquired(let lease):
                lease.close()
                exit(0)
            case .busy:
                exit(3)
            }
        case "exclusive-attempt":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let manager = try ModelRevisionLeaseManager(store: ModelStore(root: root))
            switch try manager.tryAcquireExclusive(commit) {
            case .acquired(let lease):
                lease.close()
                exit(0)
            case .busy:
                exit(3)
            }
        case "dual-hold":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let ready = try fileURL(arguments, at: 3)
            let release = try fileURL(arguments, at: 4)
            let store = ModelStore(root: root)
            let lock = try OSBackedModelStoreLock(store: store)
            let manager = try ModelRevisionLeaseManager(store: store)
            try await lock.withLock {
                let lease = try await manager.acquireShared(commit)
                defer { lease.close() }
                touch(ready)
                try await waitForFile(release)
            }
            print("released")
        case "gc-hold":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let ready = try fileURL(arguments, at: 3)
            let release = try fileURL(arguments, at: 4)
            let store = ModelStore(root: root)
            let lock = try OSBackedModelStoreLock(store: store)
            let manager = try ModelRevisionLeaseManager(store: store)
            try await lock.withLock {
                let lease = try manager.tryAcquireExclusive(commit)
                guard case .acquired(let lease) = lease else { throw HelperError.busy }
                defer { lease.close() }
                touch(ready)
                try await waitForFile(release)
            }
            print("released")
        case "runtime-hold":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let ready = try fileURL(arguments, at: 3)
            let release = try fileURL(arguments, at: 4)
            let store = ModelStore(root: root)
            let lock = try OSBackedModelStoreLock(store: store)
            let manager = try ModelRevisionLeaseManager(store: store)
            let lease = try await lock.withLock {
                try await manager.acquireShared(commit)
            }
            defer { lease.close() }
            touch(ready)
            try await waitForFile(release)
            print("released")
        case "gc-attempt":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let timeout = try duration(arguments, at: 3)
            let store = ModelStore(root: root)
            let lock = try OSBackedModelStoreLock(store: store)
            let manager = try ModelRevisionLeaseManager(store: store)
            do {
                let status = try await lock.withLock(timeout: timeout) {
                    switch try manager.tryAcquireExclusive(commit) {
                    case .acquired(let lease):
                        lease.close()
                        return 0
                    case .busy:
                        return 3
                    }
                }
                exit(Int32(status))
            } catch let error as ModelStoreLockError where error == .timedOut {
                exit(2)
            }
        case "lifecycle-gc-hold":
            let root = try rootURL(arguments, at: 1)
            let ready = try fileURL(arguments, at: 2)
            let release = try fileURL(arguments, at: 3)
            let heldCommit = arguments.count > 4
                ? try string(arguments, at: 4)
                : lifecycleSecondCommit
            let store = ModelStore(root: root)
            let manifest = lifecycleFixtureManifest(commit: lifecycleFirstCommit)
            let coordinator = try ModelLifecycleCoordinator(
                testingManifest: manifest,
                store: store,
                hook: { event in
                    guard event == .beforeRevisionDelete(heldCommit) else { return }
                    touch(ready)
                    try await waitForFile(release)
                }
            )
            let result = try await coordinator.garbageCollect()
            guard result.deleted.contains(lifecycleSecondCommit) else { throw HelperError.unexpectedResult }
        case "lifecycle-gc":
            let root = try rootURL(arguments, at: 1)
            let store = ModelStore(root: root)
            let coordinator = try ModelLifecycleCoordinator(
                testingManifest: lifecycleFixtureManifest(commit: lifecycleFirstCommit),
                store: store
            )
            _ = try await coordinator.garbageCollect()
        case "lifecycle-runtime-hold":
            let root = try rootURL(arguments, at: 1)
            let ready = try fileURL(arguments, at: 2)
            let release = try fileURL(arguments, at: 3)
            let store = ModelStore(root: root)
            let coordinator = try ModelLifecycleCoordinator(
                testingManifest: lifecycleFixtureManifest(commit: lifecycleFirstCommit),
                store: store
            )
            let runtime = try await coordinator.resolveRuntime()
            touch(ready)
            try await waitForFile(release)
            runtime.close()
        case "installer-hold":
            let root = try rootURL(arguments, at: 1)
            let manifestURL = URL(fileURLWithPath: try string(arguments, at: 2))
            let ready = try fileURL(arguments, at: 3)
            let release = try fileURL(arguments, at: 4)
            let manifest = try ModelManifest(data: Data(contentsOf: manifestURL))
            let client = BlockingDownloadClient(ready: ready, release: release)
            let installer = try ModelInstaller(
                manifest: manifest,
                store: ModelStore(root: root),
                downloadClient: client,
                diskSafetyAllowance: 0
            )
            do {
                _ = try await installer.install()
            } catch {
                print("error:\(String(describing: error))")
                exit(1)
            }
            print("released")
        case "model-activate":
            let root = try rootURL(arguments, at: 1)
            let commit = try string(arguments, at: 2)
            let store = ModelStore(root: root)
            let manifest = ModelManifest(
                testingFiles: [("Preprocessor.mlmodelc/metadata.json", Data("good".utf8))],
                baseURL: "https://fixture.invalid/model",
                immutableCommit: lifecycleFirstCommit
            )
            let commands = try ModelCommands(testingManifest: manifest, store: store)
            let result = await commands.run(arguments: ["activate", commit, "--json"])
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
            FileHandle.standardError.write(Data(result.stderr.utf8))
            exit(Int32(result.exitCode))
        default:
            throw HelperError.invalidArguments
        }
    }

    private static func waitForFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else { throw HelperError.timeout }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func touch(_ url: URL) {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        fflush(stdout)
    }

    private static func rootURL(_ arguments: [String], at index: Int) throws -> URL {
        URL(fileURLWithPath: try string(arguments, at: index), isDirectory: true)
    }

    private static func fileURL(_ arguments: [String], at index: Int) throws -> URL {
        URL(fileURLWithPath: try string(arguments, at: index))
    }

    private static func string(_ arguments: [String], at index: Int) throws -> String {
        guard arguments.indices.contains(index) else { throw HelperError.invalidArguments }
        return arguments[index]
    }

    private static func duration(_ arguments: [String], at index: Int) throws -> TimeInterval {
        guard let value = TimeInterval(try string(arguments, at: index)), value > 0 else {
            throw HelperError.invalidArguments
        }
        return value
    }
}

private actor BlockingDownloadClient: ModelDownloadClient {
    let ready: URL
    let release: URL

    init(ready: URL, release: URL) {
        self.ready = ready
        self.release = release
    }

    func response(for request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        let ready = ready
        let release = release
        _ = FileManager.default.createFile(atPath: ready.path, contents: Data())
        fflush(stdout)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: release.path) {
            guard Date() < deadline else { throw HelperError.timeout }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ModelDownloadClientError.transport("test stop")
    }
}

private enum HelperError: Error {
    case invalidArguments
    case timeout
    case busy
    case unexpectedResult
}

private let lifecycleFirstCommit = String(repeating: "a", count: 40)
private let lifecycleSecondCommit = String(repeating: "b", count: 40)

private func lifecycleFixtureManifest(commit: String) -> ModelManifest {
    ModelManifest(
        testingFiles: [("Preprocessor.mlmodelc/metadata.json", Data("fixture".utf8))],
        baseURL: "https://fixture.invalid/model",
        immutableCommit: commit
    )
}
