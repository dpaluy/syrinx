import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CommandRunner {
    private let environment: [String: String]
    private let paths: StandardPaths
    private let doctor: Doctor
    private let injectedModelCommands: ModelCommands?
    private let executableURL: URL

    public init(environment: [String: String]) {
        self.environment = environment
        paths = StandardPaths()
        doctor = Doctor()
        injectedModelCommands = nil
        executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
    }

    public init(
        environment: [String: String],
        paths: StandardPaths,
        doctor: Doctor = .init(),
        executableURL: URL? = nil
    ) {
        self.environment = environment
        self.paths = paths
        self.doctor = doctor
        injectedModelCommands = nil
        self.executableURL = executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
    }

    init(
        environment: [String: String],
        paths: StandardPaths,
        doctor: Doctor = .init(),
        modelCommands: ModelCommands,
        executableURL: URL? = nil
    ) {
        self.environment = environment
        self.paths = paths
        self.doctor = doctor
        injectedModelCommands = modelCommands
        self.executableURL = executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
    }

    public func run(arguments: [String]) -> CommandResult {
        guard let command = arguments.first else {
            return CommandResult(exitCode: 2, stderr: usage)
        }

        switch command {
        case "--help", "help":
            return CommandResult(exitCode: 0, stdout: usage)
        case "version":
            return runVersion(options: Array(arguments.dropFirst()))
        case "doctor":
            return runDoctor(options: Array(arguments.dropFirst()))
        case "models":
            return CommandResult(
                exitCode: 2,
                stderr: "model commands require async execution\n"
            )
        case "service":
            return CommandResult(
                exitCode: 2,
                stderr: "service commands require async execution\n"
            )
        case "serve":
            return CommandResult(
                exitCode: 2,
                stderr: "unsupported command: serve\n"
            )
        case "transcribe":
            return CommandResult(
                exitCode: 2,
                stderr: TranscribeCommand.usage
            )
        default:
            return CommandResult(exitCode: 2, stderr: "unsupported command: \(command)\n")
        }
    }

    public func runAsync(arguments: [String]) async -> CommandResult {
        guard let command = arguments.first else {
            return CommandResult(exitCode: 2, stderr: usage)
        }

        if command == "transcribe" {
            return await TranscribeCommand(environment: environment, paths: paths).run(arguments: Array(arguments.dropFirst()))
        }

        if command == "serve" {
            return await ServeCommand(environment: environment, paths: paths).run(arguments: Array(arguments.dropFirst()))
        }

        if command == "service" {
            return await ServiceCommands(
                environment: environment,
                paths: paths,
                executableURL: executableURL
            ).run(arguments: Array(arguments.dropFirst()))
        }

        if command == "models" {
            let modelArguments = Array(arguments.dropFirst())
            do {
                _ = try ModelCommands.parse(arguments: modelArguments)
            } catch let ModelCommandUsage.line(line) {
                return CommandResult(exitCode: 2, stderr: line)
            } catch {
                return CommandResult(exitCode: 2, stderr: "usage: syrinx models <install|list|verify|path|activate|rollback|gc> ...\n")
            }

            do {
                let commands = try injectedModelCommands ?? ModelCommands(paths: paths)
                return await commands.run(arguments: modelArguments)
            } catch {
                return ModelCommands.failureResult(
                    error,
                    json: modelArguments.contains("--json")
                )
            }
        }

        return run(arguments: arguments)
    }

    private func runVersion(options: [String]) -> CommandResult {
        guard options.isEmpty || options == ["--json"] else {
            return CommandResult(exitCode: 2, stderr: "usage: syrinx version [--json]\n")
        }
        let info = BuildInfo.from(environment: environment)
        if options == ["--json"] {
            return encodedResult(info)
        }
        return CommandResult(
            exitCode: 0,
            stdout: "Syrinx \(info.projectVersion)\ncommit: \(info.commit)\ntarget: \(info.buildTarget)\n"
        )
    }

    private func runDoctor(options: [String]) -> CommandResult {
        guard options.isEmpty || options == ["--json"] else {
            return CommandResult(exitCode: 2, stderr: "usage: syrinx doctor [--json]\n")
        }
        do {
            let configuration = try ServiceConfiguration.load(environment: environment)
            let report = doctor.run(configuration: configuration, paths: paths)
            if options == ["--json"] {
                return encodedResult(report)
            }
            return CommandResult(exitCode: 0, stdout: humanDoctorReport(report))
        } catch {
            return CommandResult(exitCode: 2, stderr: "configuration error: \(error)\n")
        }
    }

    private func encodedResult<T: Encodable>(_ value: T) -> CommandResult {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            return CommandResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self) + "\n")
        } catch {
            return CommandResult(exitCode: 1, stderr: "could not encode command result: \(error)\n")
        }
    }

    private func humanDoctorReport(_ report: DoctorReport) -> String {
        let writable = report.writablePaths.map { "\($0.path)=\($0.writable ? "writable" : "not writable")" }.joined(separator: ", ")
        return "platform: \(report.platform)\narchitecture: \(report.architecture)\nhost: \(report.host)\nport: \(report.port)\nport available: \(report.portAvailable)\npaths: \(writable)\nmodel status: \(report.modelStatus)\n"
    }

    private var usage: String {
        """
        usage: syrinx <command> [options]

        commands:
          version      Show build and version information.
          doctor       Check configuration, paths, port, and model state.
          models       Install, verify, select, and manage model revisions.
          transcribe   Transcribe a local WAV file.
          serve        Run the loopback HTTP service in the foreground.
          service      Install and manage the per-user background service.

        Run `syrinx <command>` without arguments to see command-specific usage.
        """ + "\n"
    }
}
