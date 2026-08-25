import Foundation

public protocol ModelCommandInstalling: Sendable {
    func preflight() async throws -> ModelInstallPreflight
    func install(activate: Bool, verifiedAt: Date) async throws -> ModelInstallResult
}

public protocol ModelCommandLifecycle: Sendable {
    func activate(immutableCommit: String, verifiedAt: Date) async throws -> SelectionState
    func rollback(verifiedAt: Date) async throws -> SelectionState
    func garbageCollect() async throws -> ModelGarbageCollectionResult
}

public protocol ModelCommandVerifying: Sendable {
    func verify(manifest: ModelManifest, at root: URL) throws
}

extension ModelInstaller: ModelCommandInstalling {}
extension ModelLifecycleCoordinator: ModelCommandLifecycle {}
extension ModelVerifier: ModelCommandVerifying {}

struct ModelCommandFactories: Sendable {
    let makeInstaller: @Sendable () throws -> any ModelCommandInstalling
    let makeLifecycle: @Sendable () throws -> any ModelCommandLifecycle

    init(
        makeInstaller: @escaping @Sendable () throws -> any ModelCommandInstalling,
        makeLifecycle: @escaping @Sendable () throws -> any ModelCommandLifecycle
    ) {
        self.makeInstaller = makeInstaller
        self.makeLifecycle = makeLifecycle
    }
}

public struct ModelCommandDependencies: Sendable {
    let manifest: ModelManifest
    let store: ModelStore
    let factories: ModelCommandFactories
    let verifier: any ModelCommandVerifying
    let now: @Sendable () -> Date

    init(
        manifest: ModelManifest,
        store: ModelStore,
        installer: any ModelCommandInstalling,
        lifecycle: any ModelCommandLifecycle,
        verifier: any ModelCommandVerifying = ModelVerifier(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            manifest: manifest,
            store: store,
            factories: ModelCommandFactories(
                makeInstaller: { installer },
                makeLifecycle: { lifecycle }
            ),
            verifier: verifier,
            now: now
        )
    }

    init(
        manifest: ModelManifest,
        store: ModelStore,
        factories: ModelCommandFactories,
        verifier: any ModelCommandVerifying = ModelVerifier(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.manifest = manifest
        self.store = store
        self.factories = factories
        self.verifier = verifier
        self.now = now
    }
}

enum ParsedModelCommand: Sendable {
    case install(activate: Bool, json: Bool)
    case list(json: Bool)
    case verify(revision: String?, json: Bool)
    case path(revision: String?, json: Bool)
    case activate(revision: String, json: Bool)
    case rollback(json: Bool)
    case garbageCollect(json: Bool)

    var json: Bool {
        switch self {
        case let .install(_, json), let .list(json), let .verify(_, json), let .path(_, json),
             let .activate(_, json), let .rollback(json), let .garbageCollect(json):
            return json
        }
    }
}

enum ModelCommandUsage: Error, Sendable {
    case line(String)
}

public enum ModelCommandError: Error, Equatable, Sendable, CustomStringConvertible {
    case embeddedManifestUnavailable
    case embeddedManifestInvalid
    case selectionUnavailable
    case revisionNotInstalled
    case revisionVerificationFailed
    case modelPathUnavailable
    case preflightFailed
    case unexpectedInstallResult
    case cancelled

    public var description: String {
        switch self {
        case .embeddedManifestUnavailable:
            return "embedded model manifest is unavailable"
        case .embeddedManifestInvalid:
            return "embedded model manifest is invalid"
        case .selectionUnavailable:
            return "model selection is unavailable"
        case .revisionNotInstalled:
            return "model revision is not installed"
        case .revisionVerificationFailed:
            return "model revision failed verification"
        case .modelPathUnavailable:
            return "model path is unavailable"
        case .preflightFailed:
            return "model install preflight failed"
        case .unexpectedInstallResult:
            return "model installer returned an invalid result"
        case .cancelled:
            return "model command was cancelled"
        }
    }
}

struct ModelInstallCommandPreflight: Codable, Equatable, Sendable {
    let modelId: String
    let variantId: String
    let immutableCommit: String
    let sourceRepository: String
    let licenseIdentifier: String
    let attribution: String
    let totalBytes: Int64
    let remainingBytes: Int64
    let safetyAllowance: Int64
    let requiredBytes: Int64
    let availableBytes: Int64

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case variantId = "variant_id"
        case immutableCommit = "immutable_commit"
        case sourceRepository = "source_repository"
        case licenseIdentifier = "license_identifier"
        case attribution
        case totalBytes = "total_bytes"
        case remainingBytes = "remaining_bytes"
        case safetyAllowance = "safety_allowance"
        case requiredBytes = "required_bytes"
        case availableBytes = "available_bytes"
    }
}

struct ModelInstallCommandResult: Codable, Equatable, Sendable {
    let activated: Bool
    let immutableCommit: String
    let preflight: ModelInstallCommandPreflight

    enum CodingKeys: String, CodingKey {
        case activated
        case immutableCommit = "immutable_commit"
        case preflight
    }
}

struct ModelRevisionCommandRecord: Codable, Equatable, Sendable {
    let current: Bool
    let immutableCommit: String
    let prior: Bool
    let verifiedAt: Date

    enum CodingKeys: String, CodingKey {
        case current
        case immutableCommit = "immutable_commit"
        case prior
        case verifiedAt = "verified_at"
    }
}

struct ModelListCommandResult: Codable, Equatable, Sendable {
    let modelId: String
    let revisions: [ModelRevisionCommandRecord]
    let variantId: String

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case revisions
        case variantId = "variant_id"
    }
}

struct ModelVerificationRecord: Codable, Equatable, Sendable {
    let error: String?
    let immutableCommit: String
    let valid: Bool

    enum CodingKeys: String, CodingKey {
        case error
        case immutableCommit = "immutable_commit"
        case valid
    }
}

struct ModelVerifyCommandResult: Codable, Equatable, Sendable {
    let modelId: String
    let revisions: [ModelVerificationRecord]
    let valid: Bool
    let variantId: String

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case revisions
        case valid
        case variantId = "variant_id"
    }
}

struct ModelPathCommandResult: Codable, Equatable, Sendable {
    let immutableCommit: String
    let path: String

    enum CodingKeys: String, CodingKey {
        case immutableCommit = "immutable_commit"
        case path
    }
}

struct ModelSelectionCommandResult: Codable, Equatable, Sendable {
    let currentRevision: String
    let priorRevision: String?

    enum CodingKeys: String, CodingKey {
        case currentRevision = "current_revision"
        case priorRevision = "prior_revision"
    }
}

struct ModelGarbageCollectionCommandResult: Codable, Equatable, Sendable {
    let deleted: [String]
    let skipped: [ModelGarbageCollectionCommandSkip]
}

struct ModelGarbageCollectionCommandSkip: Codable, Equatable, Sendable {
    let reason: String
    let immutableCommit: String

    enum CodingKeys: String, CodingKey {
        case reason
        case immutableCommit = "immutable_commit"
    }
}

struct ModelCommandJSONError: Codable, Equatable, Sendable {
    let error: String
}

public struct ModelCommands: Sendable {
    private let dependencies: ModelCommandDependencies

    public init(paths: StandardPaths) throws {
        let manifest = try Self.loadEmbeddedManifest()
        let store = ModelStore(root: paths.data)
        self.init(
            dependencies: ModelCommandDependencies(
                manifest: manifest,
                store: store,
                factories: ModelCommandFactories(
                    makeInstaller: {
                        try ModelInstaller(
                            manifest: manifest,
                            store: store,
                            downloadClient: URLSessionModelDownloadClient()
                        )
                    },
                    makeLifecycle: {
                        try ModelLifecycleCoordinator(store: store)
                    }
                )
            )
        )
    }

    @_spi(Testing) public init(testingManifest manifest: ModelManifest, store: ModelStore) throws {
        self.init(
            dependencies: ModelCommandDependencies(
                manifest: manifest,
                store: store,
                factories: ModelCommandFactories(
                    makeInstaller: {
                        try ModelInstaller(
                            manifest: manifest,
                            store: store,
                            downloadClient: URLSessionModelDownloadClient()
                        )
                    },
                    makeLifecycle: {
                        try ModelLifecycleCoordinator(testingManifest: manifest, store: store)
                    }
                )
            )
        )
    }

    init(dependencies: ModelCommandDependencies) {
        self.dependencies = dependencies
    }

    static func parse(arguments: [String]) throws -> ParsedModelCommand {
        guard let subcommand = arguments.first else {
            throw ModelCommandUsage.line(Self.modelsUsage)
        }
        let options = Array(arguments.dropFirst())
        switch subcommand {
        case "install":
            let flags = try parseFlags(options, allowed: ["--activate", "--json"], usage: usageLine(for: subcommand))
            guard flags.positionals.isEmpty else { throw usage(for: subcommand) }
            return .install(activate: flags.contains("--activate"), json: flags.contains("--json"))
        case "list":
            let flags = try parseFlags(options, allowed: ["--json"], usage: usageLine(for: subcommand))
            guard flags.positionals.isEmpty else { throw usage(for: subcommand) }
            return .list(json: flags.contains("--json"))
        case "verify", "path":
            let flags = try parseRevisionFlags(options, usage: usageLine(for: subcommand))
            guard flags.positionals.isEmpty else { throw usage(for: subcommand) }
            if subcommand == "verify" {
                return .verify(revision: flags.revision, json: flags.json)
            }
            return .path(revision: flags.revision, json: flags.json)
        case "activate":
            let flags = try parseFlags(options, allowed: ["--json"], usage: usageLine(for: subcommand))
            guard flags.positionals.count == 1,
                  ModelStore.isValidImmutableCommit(flags.positionals[0])
            else { throw usage(for: subcommand) }
            return .activate(revision: flags.positionals[0], json: flags.contains("--json"))
        case "rollback":
            let flags = try parseFlags(options, allowed: ["--json"], usage: usageLine(for: subcommand))
            guard flags.positionals.isEmpty else { throw usage(for: subcommand) }
            return .rollback(json: flags.contains("--json"))
        case "gc":
            let flags = try parseFlags(options, allowed: ["--json"], usage: usageLine(for: subcommand))
            guard flags.positionals.isEmpty else { throw usage(for: subcommand) }
            return .garbageCollect(json: flags.contains("--json"))
        default:
            throw ModelCommandUsage.line(Self.modelsUsage)
        }
    }

    static func usageResult(for arguments: [String]) -> CommandResult {
        do {
            _ = try parse(arguments: arguments)
            return CommandResult(exitCode: 2, stderr: modelsUsage)
        } catch let ModelCommandUsage.line(line) {
            return CommandResult(exitCode: 2, stderr: line)
        } catch {
            return CommandResult(exitCode: 2, stderr: modelsUsage)
        }
    }

    @_spi(Testing) public func run(arguments: [String]) async -> CommandResult {
        do {
            let command = try Self.parse(arguments: arguments)
            return await run(parsed: command)
        } catch let ModelCommandUsage.line(line) {
            return CommandResult(exitCode: 2, stderr: line)
        } catch {
            return CommandResult(exitCode: 2, stderr: Self.modelsUsage)
        }
    }

    func run(parsed command: ParsedModelCommand) async -> CommandResult {
        do {
            switch command {
            case let .install(activate, json):
                return try await install(activate: activate, json: json)
            case let .list(json):
                return try list(json: json)
            case let .verify(revision, json):
                return try verify(revision: revision, json: json)
            case let .path(revision, json):
                return try path(revision: revision, json: json)
            case let .activate(revision, json):
                return try await activate(revision: revision, json: json)
            case let .rollback(json):
                return try await rollback(json: json)
            case let .garbageCollect(json):
                return try await garbageCollect(json: json)
            }
        } catch is CancellationError {
            return Self.failureResult(ModelCommandError.cancelled, json: command.json)
        } catch {
            return Self.failureResult(error, json: command.json)
        }
    }

    private func install(activate: Bool, json: Bool) async throws -> CommandResult {
        let installer = try dependencies.factories.makeInstaller()
        let installerPreflight = try await installer.preflight()
        guard installerPreflight.totalBytes == dependencies.manifest.totalSize,
              installerPreflight.remainingBytes >= 0,
              installerPreflight.safetyAllowance >= 0,
              installerPreflight.requiredBytes >= installerPreflight.remainingBytes,
              installerPreflight.availableBytes >= 0
        else {
            throw ModelCommandError.preflightFailed
        }
        guard installerPreflight.remainingBytes == 0 ||
            installerPreflight.availableBytes >= installerPreflight.requiredBytes
        else {
            throw ModelInstallerError.diskFull
        }
        let preflight = ModelInstallCommandPreflight(
            modelId: dependencies.manifest.modelId,
            variantId: dependencies.manifest.variantId,
            immutableCommit: dependencies.manifest.immutableCommit,
            sourceRepository: bounded(dependencies.manifest.repository),
            licenseIdentifier: bounded(dependencies.manifest.license.spdx),
            attribution: bounded(dependencies.manifest.attribution.notice),
            totalBytes: dependencies.manifest.totalSize,
            remainingBytes: installerPreflight.remainingBytes,
            safetyAllowance: installerPreflight.safetyAllowance,
            requiredBytes: installerPreflight.requiredBytes,
            availableBytes: installerPreflight.availableBytes
        )
        let result = try await installer.install(
            activate: false,
            verifiedAt: dependencies.now()
        )
        guard result.immutableCommit == dependencies.manifest.immutableCommit,
              !result.activated
        else {
            throw ModelCommandError.unexpectedInstallResult
        }

        var selection: SelectionState?
        if activate {
            let lifecycle = try dependencies.factories.makeLifecycle()
            selection = try await lifecycle.activate(
                immutableCommit: result.immutableCommit,
                verifiedAt: dependencies.now()
            )
        } else {
            selection = nil
        }

        let output = ModelInstallCommandResult(
            activated: selection != nil,
            immutableCommit: result.immutableCommit,
            preflight: preflight
        )
        if json {
            return encoded(output)
        }
        var text = "model: \(output.immutableCommit)\n"
        text += "preflight: total \(preflight.totalBytes) bytes, remaining \(preflight.remainingBytes) bytes, required \(preflight.requiredBytes) bytes, available \(preflight.availableBytes) bytes\n"
        text += "source: \(preflight.sourceRepository)\n"
        text += "license: \(preflight.licenseIdentifier)\n"
        text += "attribution: \(preflight.attribution)\n"
        text += "activated: \(output.activated ? "yes" : "no")\n"
        return CommandResult(exitCode: 0, stdout: text)
    }

    private func list(json: Bool) throws -> CommandResult {
        let installed = try dependencies.store.readInstalled()
        let selection = try dependencies.store.readSelection()
        let current = selection?.currentRevision
        let prior = selection?.priorRevision
        let records = (installed?.revisions ?? []).sorted { $0.immutableCommit < $1.immutableCommit }.map {
            ModelRevisionCommandRecord(
                current: $0.immutableCommit == current,
                immutableCommit: $0.immutableCommit,
                prior: $0.immutableCommit == prior,
                verifiedAt: $0.verifiedAt
            )
        }
        let output = ModelListCommandResult(
            modelId: dependencies.manifest.modelId,
            revisions: records,
            variantId: dependencies.manifest.variantId
        )
        if json { return encoded(output) }
        guard !records.isEmpty else { return CommandResult(exitCode: 0, stdout: "no installed model revisions\n") }
        let dateFormatter = ISO8601DateFormatter()
        let text = records.map { record in
            let flags = [record.current ? "current" : nil, record.prior ? "prior" : nil]
                .compactMap { $0 }
                .joined(separator: ",")
            let suffix = flags.isEmpty ? "" : " [\(flags)]"
            return "\(record.immutableCommit)\(suffix) \(dateFormatter.string(from: record.verifiedAt))"
        }.joined(separator: "\n") + "\n"
        return CommandResult(exitCode: 0, stdout: text)
    }

    private func verify(revision: String?, json: Bool) throws -> CommandResult {
        let installed = try dependencies.store.readInstalled()
        let revisions: [InstalledRevision]
        if let revision {
            guard let match = installed?.revisions.first(where: { $0.immutableCommit == revision }) else {
                throw ModelCommandError.revisionNotInstalled
            }
            revisions = [match]
        } else {
            revisions = (installed?.revisions ?? []).sorted { $0.immutableCommit < $1.immutableCommit }
        }

        var records: [ModelVerificationRecord] = []
        for item in revisions {
            do {
                try dependencies.verifier.verify(
                    manifest: dependencies.manifest,
                    at: dependencies.store.revisionURL(for: item.immutableCommit)
                )
                records.append(ModelVerificationRecord(error: nil, immutableCommit: item.immutableCommit, valid: true))
            } catch {
                records.append(ModelVerificationRecord(error: Self.safeVerifierDescription(error), immutableCommit: item.immutableCommit, valid: false))
            }
        }
        let output = ModelVerifyCommandResult(
            modelId: dependencies.manifest.modelId,
            revisions: records,
            valid: records.allSatisfy(\.valid),
            variantId: dependencies.manifest.variantId
        )
        if json {
            var result = encoded(output)
            result = CommandResult(exitCode: output.valid ? 0 : 1, stdout: result.stdout, stderr: result.stderr)
            return result
        }
        let text = records.map { record in
            if let error = record.error { return "\(record.immutableCommit): invalid (\(error))" }
            return "\(record.immutableCommit): verified"
        }.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
        return CommandResult(
            exitCode: output.valid ? 0 : 1,
            stdout: text,
            stderr: output.valid || json ? "" : "model verification failed\n"
        )
    }

    private func path(revision: String?, json: Bool) throws -> CommandResult {
        let installed = try dependencies.store.readInstalled()
        let selectedRevision: String
        if let revision {
            guard installed?.revisions.contains(where: { $0.immutableCommit == revision }) == true else {
                throw ModelCommandError.revisionNotInstalled
            }
            selectedRevision = revision
        } else {
            guard let selection = try dependencies.store.readSelection() else {
                throw ModelCommandError.selectionUnavailable
            }
            selectedRevision = selection.currentRevision
        }
        guard installed?.revisions.contains(where: { $0.immutableCommit == selectedRevision }) == true else {
            throw ModelCommandError.revisionNotInstalled
        }
        let repositoryURL = dependencies.store.revisionURL(for: selectedRevision)
        do {
            try dependencies.verifier.verify(manifest: dependencies.manifest, at: repositoryURL)
        } catch {
            throw ModelCommandError.revisionVerificationFailed
        }
        let output = ModelPathCommandResult(immutableCommit: selectedRevision, path: repositoryURL.path)
        if json { return encoded(output) }
        return CommandResult(exitCode: 0, stdout: repositoryURL.path + "\n")
    }

    private func activate(revision: String, json: Bool) async throws -> CommandResult {
        let lifecycle = try dependencies.factories.makeLifecycle()
        let selection = try await lifecycle.activate(
            immutableCommit: revision,
            verifiedAt: dependencies.now()
        )
        return selectionResult(selection, json: json)
    }

    private func rollback(json: Bool) async throws -> CommandResult {
        let lifecycle = try dependencies.factories.makeLifecycle()
        let selection = try await lifecycle.rollback(verifiedAt: dependencies.now())
        return selectionResult(selection, json: json)
    }

    private func garbageCollect(json: Bool) async throws -> CommandResult {
        let lifecycle = try dependencies.factories.makeLifecycle()
        let result = try await lifecycle.garbageCollect()
        let skipped = result.skipped.map { skip in
            switch skip {
            case let .busy(commit):
                return ModelGarbageCollectionCommandSkip(reason: "busy", immutableCommit: commit)
            case let .becameLive(commit):
                return ModelGarbageCollectionCommandSkip(reason: "became_live", immutableCommit: commit)
            case let .noLongerInstalled(commit):
                return ModelGarbageCollectionCommandSkip(reason: "no_longer_installed", immutableCommit: commit)
            case let .unsafe(commit):
                return ModelGarbageCollectionCommandSkip(reason: "unsafe", immutableCommit: commit)
            }
        }.sorted {
            if $0.immutableCommit == $1.immutableCommit { return $0.reason < $1.reason }
            return $0.immutableCommit < $1.immutableCommit
        }
        let output = ModelGarbageCollectionCommandResult(
            deleted: result.deleted.sorted(),
            skipped: skipped
        )
        if json { return encoded(output) }
        var text = output.deleted.map { "deleted: \($0)" }
        text += output.skipped.map { "skipped: \($0.immutableCommit) (\($0.reason))" }
        return CommandResult(exitCode: 0, stdout: text.joined(separator: "\n") + (text.isEmpty ? "" : "\n"))
    }

    private func selectionResult(_ selection: SelectionState, json: Bool) -> CommandResult {
        let output = ModelSelectionCommandResult(
            currentRevision: selection.currentRevision,
            priorRevision: selection.priorRevision
        )
        if json { return encoded(output) }
        let prior = selection.priorRevision ?? "none"
        return CommandResult(
            exitCode: 0,
            stdout: "current: \(selection.currentRevision)\nprior: \(prior)\n"
        )
    }

    private func encoded<T: Encodable>(_ value: T) -> CommandResult {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return CommandResult(exitCode: 0, stdout: String(decoding: try encoder.encode(value), as: UTF8.self) + "\n")
        } catch {
            return Self.failureResult(ModelCommandError.unexpectedInstallResult, json: true)
        }
    }

    static func failureResult(_ error: Error, json: Bool) -> CommandResult {
        let message = Self.safeDescription(error)
        if json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(ModelCommandJSONError(error: message))
                return CommandResult(exitCode: 1, stdout: String(decoding: data, as: UTF8.self) + "\n")
            } catch {
                return CommandResult(exitCode: 1, stderr: "model command failed\n")
            }
        }
        return CommandResult(exitCode: 1, stderr: message + "\n")
    }

    private static func loadEmbeddedManifest() throws -> ModelManifest {
        guard let url = Bundle.module.url(
            forResource: "parakeet-tdt-0.6b-v3-int8",
            withExtension: "json"
        ) else {
            throw ModelCommandError.embeddedManifestUnavailable
        }
        do {
            return try ModelManifest(data: Data(contentsOf: url))
        } catch {
            throw ModelCommandError.embeddedManifestInvalid
        }
    }

    private static let modelsUsage = "usage: syrinx models <install|list|verify|path|activate|rollback|gc> ...\n"

    private static func usageLine(for command: String) -> String {
        switch command {
        case "install": return "usage: syrinx models install [--activate] [--json]\n"
        case "list": return "usage: syrinx models list [--json]\n"
        case "verify": return "usage: syrinx models verify [--revision <40-lowercase-hex>] [--json]\n"
        case "path": return "usage: syrinx models path [--revision <40-lowercase-hex>] [--json]\n"
        case "activate": return "usage: syrinx models activate <40-lowercase-hex> [--json]\n"
        case "rollback": return "usage: syrinx models rollback [--json]\n"
        case "gc": return "usage: syrinx models gc [--json]\n"
        default: return modelsUsage
        }
    }

    private static func usage(for command: String) -> ModelCommandUsage {
        .line(usageLine(for: command))
    }

    private struct ParsedFlags {
        let flags: Set<String>
        let positionals: [String]

        func contains(_ flag: String) -> Bool { flags.contains(flag) }
    }

    private static func parseFlags(_ arguments: [String], allowed: Set<String>, usage: String) throws -> ParsedFlags {
        var flags = Set<String>()
        var positionals: [String] = []
        for argument in arguments {
            if argument.hasPrefix("-") {
                guard allowed.contains(argument), flags.insert(argument).inserted else {
                    throw ModelCommandUsage.line(usage)
                }
                continue
            }
            positionals.append(argument)
        }
        return ParsedFlags(flags: flags, positionals: positionals)
    }

    private static func parseRevisionFlags(_ arguments: [String], usage: String) throws -> (revision: String?, json: Bool, positionals: [String]) {
        var revision: String?
        var json = false
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                guard !json else { throw ModelCommandUsage.line(usage) }
                json = true
            case "--revision":
                guard revision == nil, index + 1 < arguments.count else { throw ModelCommandUsage.line(usage) }
                index += 1
                let value = arguments[index]
                guard ModelStore.isValidImmutableCommit(value) else { throw ModelCommandUsage.line(usage) }
                revision = value
            default:
                if argument.hasPrefix("-") { throw ModelCommandUsage.line(usage) }
                positionals.append(argument)
            }
            index += 1
        }
        return (revision, json, positionals)
    }

    private func bounded(_ value: String) -> String {
        String(value.prefix(512))
    }

    private static func safeVerifierDescription(_ error: Error) -> String {
        if let error = error as? ModelVerifierError { return error.description }
        if let error = error as? ModelManifestError { return error.description }
        return ModelCommandError.revisionVerificationFailed.description
    }

    private static func safeDescription(_ error: Error) -> String {
        if let error = error as? ModelCommandError { return error.description }
        if let error = error as? ModelInstallerError {
            return error == .cancelled ? ModelCommandError.cancelled.description : error.description
        }
        if let error = error as? ModelLifecycleError { return error.description }
        if let error = error as? ModelStoreError { return error.description }
        if let error = error as? ModelStoreLockError { return error.description }
        if let error = error as? ModelVerifierError { return error.description }
        if let error = error as? ModelManifestError { return error.description }
        if let error = error as? ModelDownloadClientError {
            switch error {
            case .invalidHTTPSURL:
                return "model download URL must use HTTPS"
            case .URLMismatch:
                return "model download URL does not match the validated manifest"
            case .transport:
                return "model download connection was lost"
            }
        }
        if error is CancellationError { return ModelCommandError.cancelled.description }
        return "model command failed"
    }
}
