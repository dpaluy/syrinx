import Darwin
import Foundation
import SyrinxCore

@main
struct SyrinxMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let runner = CommandRunner(environment: ProcessInfo.processInfo.environment)

        if arguments.first == "transcribe" {
            do {
                let streams = try TranscribeStreamIsolation()
                let result = await runner.runAsync(arguments: arguments)
                streams.write(result)
                withExtendedLifetime(streams) {
                    Darwin.exit(Int32(result.exitCode))
                }
            } catch {
                let result = CommandResult(
                    exitCode: 1,
                    stderr: "transcription_failed: could not isolate runtime logs\n"
                )
                FileHandle.standardOutput.write(Data(result.stdout.utf8))
                FileHandle.standardError.write(Data(result.stderr.utf8))
                Darwin.exit(Int32(result.exitCode))
            }
        }

        let result = await runner.runAsync(arguments: arguments)
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        Darwin.exit(Int32(result.exitCode))
    }
}
