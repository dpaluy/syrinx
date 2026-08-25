@preconcurrency import AVFoundation
import Darwin
import Foundation

public struct PreparedAudio: Equatable, Sendable {
    public let fileURL: URL
    public let sampleCount: Int
    public let duration: Double

    init(fileURL: URL, sampleCount: Int, duration: Double) {
        self.fileURL = fileURL
        self.sampleCount = sampleCount
        self.duration = duration
    }
}

enum AudioNormalizerPhase: Sendable {
    case metadata
    case conversion
}

/// Normalizes with fixed-size AVFoundation buffers and a private disk-backed WAV.
/// AVFoundation conversion and active Core ML work are cooperatively cancellable,
/// so cancellation can be delayed while a synchronous operation is active.
public struct AudioNormalizer: Sendable {
    private let policy: AudioPreparationPolicy
    private let phaseBoundaryHook: (@Sendable () throws -> Void)?
    private let phaseHook: (@Sendable (AudioNormalizerPhase) throws -> Void)?

    public init(policy: AudioPreparationPolicy) {
        self.policy = policy
        self.phaseBoundaryHook = nil
        self.phaseHook = nil
    }

    init(
        policy: AudioPreparationPolicy,
        phaseBoundaryHook: (@Sendable () throws -> Void)?,
        phaseHook: (@Sendable (AudioNormalizerPhase) throws -> Void)? = nil
    ) {
        self.policy = policy
        self.phaseBoundaryHook = phaseBoundaryHook
        self.phaseHook = phaseHook
    }

    func validateConvertedSampleCount(_ sampleCount: Int) throws {
        try policy.validateTargetSampleCount(sampleCount)
    }

    public func withNormalizedAudio<Result: Sendable>(
        from inputURL: URL,
        operation: @escaping @Sendable (PreparedAudio) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let inputAccess = try AudioFileAccess.openReadOnlyRegular(fileURL: inputURL)
        return try await withNormalizedAudio(from: inputAccess, operation: operation)
    }

    func withNormalizedAudio<Result: Sendable>(
        from inputAccess: AudioFileAccess,
        phaseHook operationPhaseHook: (@Sendable (AudioNormalizerPhase) throws -> Void)? = nil,
        phaseBoundaryHook operationBoundaryHook: (@Sendable () throws -> Void)? = nil,
        operation: @escaping @Sendable (PreparedAudio) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        try (operationPhaseHook ?? phaseHook)?(.metadata)
        _ = try AVAudioMetadataPreflight(policy: policy).inspect(access: inputAccess)
        try Task.checkCancellation()
        try operationBoundaryHook?()
        try phaseBoundaryHook?()
        try Task.checkCancellation()

        let temporaryDirectory = try SecureAudioTemporary.makeDirectory()
        defer { SecureAudioTemporary.remove(directory: temporaryDirectory) }
        let outputURL = try SecureAudioTemporary.makeFile(in: temporaryDirectory, name: "normalized.wav")

        try (operationPhaseHook ?? phaseHook)?(.conversion)
        let prepared = try convert(inputAccess: inputAccess, outputURL: outputURL)
        try Task.checkCancellation()
        let result = try await operation(prepared)
        try Task.checkCancellation()
        return result
    }

    private func convert(inputAccess: AudioFileAccess, outputURL: URL) throws -> PreparedAudio {
        try Task.checkCancellation()
        let inputFile: AVAudioFile
        try inputAccess.seek(toOffset: 0)
        let duplicate = try inputAccess.duplicateDescriptorURL()
        defer { close(duplicate.descriptor) }
        do {
            inputFile = try AVAudioFile(forReading: duplicate.url)
        } catch {
            throw AudioPreparationError.conversionFailed
        }
        let inputFormat = inputFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(policy.targetSampleRate),
            channels: AVAudioChannelCount(policy.targetChannels),
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioPreparationError.conversionFailed
        }

        let outputCapacity: AVAudioFrameCount = 32_768
        let inputCapacity = max(
            AVAudioFrameCount(1),
            min(
                AVAudioFrameCount(1_024),
                AVAudioFrameCount(
                    max(
                        1,
                        Int((Double(outputCapacity) * inputFormat.sampleRate / targetFormat.sampleRate).rounded(.down))
                    )
            )
        )
        )
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity)
        else {
            throw AudioPreparationError.conversionFailed
        }

        let inputState = ConverterInputState()
        var outputSampleCount = 0
        try writeConvertedAudio(
            inputFile: inputFile,
            outputURL: outputURL,
            targetFormat: targetFormat,
            converter: converter,
            inputBuffer: inputBuffer,
            outputBuffer: outputBuffer,
            inputCapacity: inputCapacity,
            inputState: inputState,
            outputSampleCount: &outputSampleCount
        )

        guard outputSampleCount > 0 else { throw AudioPreparationError.emptyInput }
        try validateConvertedSampleCount(outputSampleCount)
        try verifyOutput(fileURL: outputURL, expectedSampleCount: outputSampleCount, targetFormat: targetFormat)
        return PreparedAudio(
            fileURL: outputURL,
            sampleCount: outputSampleCount,
            duration: Double(outputSampleCount) / Double(policy.targetSampleRate)
        )
    }

    private func writeConvertedAudio(
        inputFile: AVAudioFile,
        outputURL: URL,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        inputBuffer: AVAudioPCMBuffer,
        outputBuffer: AVAudioPCMBuffer,
        inputCapacity: AVAudioFrameCount,
        inputState: ConverterInputState,
        outputSampleCount: inout Int
    ) throws {
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings)
        } catch {
            throw AudioPreparationError.conversionFailed
        }

        var stalledCalls = 0
        while true {
            try Task.checkCancellation()
            outputBuffer.frameLength = 0
            inputState.error = nil
            var conversionError: NSError?
            let inputPositionBefore = inputFile.framePosition
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
                if inputState.inputFinished {
                    status.pointee = .endOfStream
                    return nil
                }

                let remaining = inputFile.length - inputFile.framePosition
                guard remaining > 0 else {
                    inputState.inputFinished = true
                    status.pointee = .endOfStream
                    return nil
                }
                let frameCount = min(inputCapacity, AVAudioFrameCount(remaining))
                inputBuffer.frameLength = 0
                do {
                    try inputFile.read(into: inputBuffer, frameCount: frameCount)
                    if inputBuffer.frameLength == 0 {
                        inputState.inputFinished = true
                        status.pointee = .endOfStream
                        return nil
                    }
                    status.pointee = .haveData
                    return inputBuffer
                } catch {
                    inputState.error = error as NSError
                    inputState.inputFinished = true
                    status.pointee = .endOfStream
                    return nil
                }
            }

            if inputState.error != nil || conversionError != nil { throw AudioPreparationError.conversionFailed }
            if status == .error { throw AudioPreparationError.conversionFailed }

            if outputBuffer.frameLength > 0 {
                guard outputSampleCount <= Int.max - Int(outputBuffer.frameLength) else {
                    throw AudioPreparationError.arithmeticOverflow
                }
                outputSampleCount += Int(outputBuffer.frameLength)
                try validateConvertedSampleCount(outputSampleCount)
                try Task.checkCancellation()
                do {
                    try outputFile.write(from: outputBuffer)
                } catch {
                    throw AudioPreparationError.conversionFailed
                }
            } else if status == .haveData {
                throw AudioPreparationError.conversionFailed
            }

            if status == .endOfStream { break }

            let inputAdvanced = inputFile.framePosition > inputPositionBefore
            if outputBuffer.frameLength == 0 && !inputAdvanced {
                stalledCalls += 1
                guard stalledCalls < 3 else {
                    throw AudioPreparationError.conversionFailed
                }
            } else {
                stalledCalls = 0
            }
        }

    }

    private func verifyOutput(
        fileURL: URL,
        expectedSampleCount: Int,
        targetFormat: AVAudioFormat
    ) throws {
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AudioPreparationError.conversionFailed
        }
        let format = outputFile.processingFormat
        guard format.sampleRate == targetFormat.sampleRate,
              format.channelCount == targetFormat.channelCount,
              format.commonFormat == targetFormat.commonFormat,
              !format.isInterleaved,
              outputFile.length == Int64(expectedSampleCount)
        else {
            throw AudioPreparationError.conversionFailed
        }
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var inputFinished = false
    var error: NSError?
}

private enum SecureAudioTemporary {
    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-audio-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            guard chmod(directory.path, mode_t(0o700)) == 0 else { throw AudioPreparationError.conversionFailed }
            try ensureDirectory(directory)
            return directory
        } catch let error as AudioPreparationError {
            remove(directory: directory)
            throw error
        } catch {
            remove(directory: directory)
            throw AudioPreparationError.conversionFailed
        }
    }

    static func makeFile(in directory: URL, name: String) throws -> URL {
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        let descriptor = fileURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw AudioPreparationError.conversionFailed }
        guard close(descriptor) == 0 else {
            remove(file: fileURL)
            throw AudioPreparationError.conversionFailed
        }
        guard chmod(fileURL.path, mode_t(0o600)) == 0 else {
            remove(file: fileURL)
            throw AudioPreparationError.conversionFailed
        }
        do {
            var status = stat()
            guard fileURL.path.withCString({ lstat($0, &status) }) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG
            else {
                throw AudioPreparationError.conversionFailed
            }
        } catch let error as AudioPreparationError {
            remove(file: fileURL)
            throw error
        }
        return fileURL
    }

    static func remove(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func remove(file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    private static func ensureDirectory(_ directory: URL) throws {
        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & 0o777) == 0o700
        else {
            throw AudioPreparationError.conversionFailed
        }
    }
}
