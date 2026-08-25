@preconcurrency import AVFoundation
import Foundation

public struct AVAudioMetadata: Equatable, Sendable {
    public let fileByteCount: UInt64
    public let sampleRate: Double
    public let channelCount: Int
    public let frameLength: Int64
    public let duration: Double
    public let estimatedTargetSamples: Int
}

public struct AVAudioMetadataPreflight: Sendable {
    private let policy: AudioPreparationPolicy

    public init(policy: AudioPreparationPolicy) {
        self.policy = policy
    }

    public func inspect(fileURL: URL) throws -> AVAudioMetadata {
        let access = try AudioFileAccess.openReadOnlyRegular(fileURL: fileURL)
        return try inspect(access: access)
    }

    func inspect(access: AudioFileAccess) throws -> AVAudioMetadata {
        try policy.validateFileByteCount(access.byteCount)
        guard access.byteCount > 0 else { throw AudioPreparationError.emptyInput }

        let audioFile: AVAudioFile
        try access.seek(toOffset: 0)
        let duplicate = try access.duplicateDescriptorURL()
        defer { close(duplicate.descriptor) }
        do {
            audioFile = try AVAudioFile(forReading: duplicate.url)
        } catch {
            throw AudioPreparationError.invalidAudioMetadata
        }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioPreparationError.invalidAudioMetadata
        }
        guard (1...2).contains(Int(format.channelCount)) else {
            throw AudioPreparationError.invalidAudioMetadata
        }
        guard audioFile.length > 0 else { throw AudioPreparationError.emptyInput }
        let frameLength = audioFile.length
        let rate = try AudioRationalRate(sampleRate: sampleRate)
        let frameCount = UInt64(frameLength)
        guard try rate.isWithinDuration(frameCount: frameCount, maxDurationSeconds: policy.maxDurationSeconds) else {
            throw AudioPreparationError.durationLimitExceeded
        }
        guard let estimate = try rate
            .targetSampleEstimate(frameCount: frameCount, targetRate: UInt64(policy.targetSampleRate))
            .asInt
        else {
            throw AudioPreparationError.arithmeticOverflow
        }
        try policy.validateTargetSampleCount(estimate)

        return AVAudioMetadata(
            fileByteCount: access.byteCount,
            sampleRate: sampleRate,
            channelCount: Int(format.channelCount),
            frameLength: frameLength,
            duration: Double(frameLength) / sampleRate,
            estimatedTargetSamples: estimate
        )
    }
}
