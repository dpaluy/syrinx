import Foundation

protocol ForegroundTranscriptionEngine: Transcriber {
    func start() async throws
    func drain(timeout: Duration) async -> DrainResult
}

extension NativeTranscriptionEngine: ForegroundTranscriptionEngine {}

public struct TranscribeCommand: Sendable {
    public static let usage = "usage: syrinx transcribe [--json] [--deadline-seconds <positive bounded integer>] <wav-file>\n"

    private let environment: [String: String]
    private let paths: StandardPaths
    private let engineFactory: @Sendable (ServiceConfiguration, StandardPaths) throws -> any ForegroundTranscriptionEngine

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        paths: StandardPaths = .init()
    ) {
        self.environment = environment
        self.paths = paths
        self.engineFactory = { configuration, paths in
            try NativeTranscriptionEngine(configuration: configuration, paths: paths)
        }
    }

    init(
        environment: [String: String],
        paths: StandardPaths,
        engineFactory: @escaping @Sendable (ServiceConfiguration, StandardPaths) throws -> any ForegroundTranscriptionEngine
    ) {
        self.environment = environment
        self.paths = paths
        self.engineFactory = engineFactory
    }

    public func run(arguments: [String]) async -> CommandResult {
        do {
            let options = try Options(arguments: arguments)
            return try await execute(options: options)
        } catch let error as UsageError {
            return CommandResult(exitCode: 2, stderr: error.description + "\n")
        } catch let diagnostic as TranscriptionDiagnostic {
            return CommandResult(exitCode: 1, stderr: diagnostic.description + "\n")
        } catch {
            return CommandResult(
                exitCode: 1,
                stderr: TranscriptionDiagnostic(
                    code: .transcriptionFailed,
                    message: "transcription failed"
                ).description + "\n"
            )
        }
    }

    private func execute(options: Options) async throws -> CommandResult {
        let configuration: ServiceConfiguration
        do {
            configuration = try ServiceConfiguration.load(environment: environment)
        } catch {
            throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "service configuration is unavailable")
        }

        let engine: any ForegroundTranscriptionEngine
        do {
            engine = try engineFactory(configuration, paths)
        } catch {
            throw TranscriptionDiagnostic(code: .runtimeUnavailable, message: "runtime is unavailable")
        }

        do {
            try await engine.start()
            let result = try await engine.transcribe(
                TranscriptionRequest(
                    audioFile: URL(fileURLWithPath: options.audioPath),
                    deadline: options.deadlineSeconds.map(TimeInterval.init)
                )
            )
            guard await engine.drain(timeout: .seconds(30)) == .completed else {
                throw TranscriptionDiagnostic(code: .drainTimeout, message: "runtime shutdown timed out")
            }
            return options.json ? encodedJSON(result) : humanResult(result)
        } catch let diagnostic as TranscriptionDiagnostic {
            _ = await engine.drain(timeout: .seconds(30))
            throw diagnostic
        } catch {
            _ = await engine.drain(timeout: .seconds(30))
            throw TranscriptionDiagnostic(code: .transcriptionFailed, message: "transcription failed")
        }
    }

    private func encodedJSON(_ result: TranscriptionResult) -> CommandResult {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return CommandResult(
                exitCode: 0,
                stdout: String(decoding: try encoder.encode(result), as: UTF8.self) + "\n"
            )
        } catch {
            return CommandResult(exitCode: 1, stderr: "transcription_failed: could not encode result\n")
        }
    }

    private func humanResult(_ result: TranscriptionResult) -> CommandResult {
        CommandResult(
            exitCode: 0,
            stdout: "text: \(result.text)\nduration: \(result.duration)\nprocessing time: \(result.processingTime)\nmodel: \(result.modelID)\nmodel revision: \(result.modelRevision)\n"
        )
    }

    private struct Options: Sendable {
        let audioPath: String
        let json: Bool
        let deadlineSeconds: Int?

        init(arguments: [String]) throws {
            var audioPath: String?
            var json = false
            var deadlineSeconds: Int?
            var index = 0

            while index < arguments.count {
                switch arguments[index] {
                case "--deadline-seconds":
                    guard deadlineSeconds == nil, index + 1 < arguments.count,
                          let value = Int(arguments[index + 1]), value > 0, value <= 3_600
                    else { throw UsageError.invalidArguments }
                    deadlineSeconds = Int(arguments[index + 1])
                    index += 2
                case "--json":
                    guard !json else { throw UsageError.invalidArguments }
                    json = true
                    index += 1
                default:
                    guard !arguments[index].hasPrefix("-"), audioPath == nil else {
                        throw UsageError.invalidArguments
                    }
                    audioPath = arguments[index]
                    index += 1
                }
            }

            guard let audioPath else { throw UsageError.invalidArguments }
            self.audioPath = audioPath
            self.json = json
            self.deadlineSeconds = deadlineSeconds
        }
    }

    private enum UsageError: Error, CustomStringConvertible {
        case invalidArguments

        var description: String { TranscribeCommand.usage.trimmingCharacters(in: .newlines) }
    }
}
