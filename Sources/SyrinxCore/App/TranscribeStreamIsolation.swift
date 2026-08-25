import Darwin
import Foundation

protocol TranscribeStreamOperations {
    func flush()
    func duplicate(_ descriptor: Int32) -> Int32
    func openNullDevice() -> Int32
    func replace(_ descriptor: Int32, with source: Int32) -> Int32
    func close(_ descriptor: Int32)
    func write(_ data: Data, to descriptor: Int32) -> Int
}

private struct PosixTranscribeStreamOperations: TranscribeStreamOperations {
    func flush() {
        fflush(stdout)
        fflush(stderr)
    }

    func duplicate(_ descriptor: Int32) -> Int32 {
        dup(descriptor)
    }

    func openNullDevice() -> Int32 {
        open("/dev/null", O_WRONLY)
    }

    func replace(_ descriptor: Int32, with source: Int32) -> Int32 {
        dup2(source, descriptor)
    }

    func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    func write(_ data: Data, to descriptor: Int32) -> Int {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, baseAddress, bytes.count)
        }
    }
}

public final class TranscribeStreamIsolation {
    private let operations: any TranscribeStreamOperations
    private let savedOutput: Int32
    private let savedError: Int32
    private let nullDevice: Int32
    private var isActive = true

    public convenience init() throws {
        try self.init(operations: PosixTranscribeStreamOperations())
    }

    init(operations: any TranscribeStreamOperations) throws {
        self.operations = operations
        operations.flush()

        let output = operations.duplicate(STDOUT_FILENO)
        guard output >= 0 else { throw TranscribeStreamIsolationError.unavailable }

        let error = operations.duplicate(STDERR_FILENO)
        guard error >= 0 else {
            operations.close(output)
            throw TranscribeStreamIsolationError.unavailable
        }

        let null = operations.openNullDevice()
        guard null >= 0 else {
            operations.close(output)
            operations.close(error)
            throw TranscribeStreamIsolationError.unavailable
        }

        guard operations.replace(STDOUT_FILENO, with: null) >= 0 else {
            operations.close(output)
            operations.close(error)
            operations.close(null)
            throw TranscribeStreamIsolationError.unavailable
        }

        guard operations.replace(STDERR_FILENO, with: null) >= 0 else {
            _ = operations.replace(STDOUT_FILENO, with: output)
            operations.close(output)
            operations.close(error)
            operations.close(null)
            throw TranscribeStreamIsolationError.unavailable
        }

        savedOutput = output
        savedError = error
        nullDevice = null
    }

    public func write(_ result: CommandResult) {
        write(Data(result.stdout.utf8), to: savedOutput)
        write(Data(result.stderr.utf8), to: savedError)
    }

    deinit {
        restore()
    }

    private func restore() {
        guard isActive else { return }
        operations.flush()
        _ = operations.replace(STDOUT_FILENO, with: savedOutput)
        _ = operations.replace(STDERR_FILENO, with: savedError)
        operations.close(savedOutput)
        operations.close(savedError)
        operations.close(nullDevice)
        isActive = false
    }

    private func write(_ data: Data, to descriptor: Int32) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return operations.write(
                    Data(bytes: baseAddress.advanced(by: offset), count: data.count - offset),
                    to: descriptor
                )
            }
            guard written > 0 else { return }
            offset += written
        }
    }
}

enum TranscribeStreamIsolationError: Error {
    case unavailable
}
