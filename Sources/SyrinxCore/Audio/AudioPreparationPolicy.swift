import Foundation

public enum AudioSampleFormat: String, Codable, Equatable, Sendable {
    case float32
}

public enum AudioPreparationError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case configurationArithmeticOverflow
    case inputNotRegularFile
    case inputUnreadable
    case emptyInput
    case uploadLimitExceeded
    case invalidWAV
    case unsupportedWAV
    case truncatedInput
    case duplicateChunk
    case arithmeticOverflow
    case invalidAudioMetadata
    case durationLimitExceeded
    case sampleLimitExceeded
    case conversionFailed

    public var code: String {
        switch self {
        case .invalidConfiguration: return "invalid_configuration"
        case .configurationArithmeticOverflow: return "configuration_arithmetic_overflow"
        case .inputNotRegularFile: return "input_not_regular_file"
        case .inputUnreadable: return "input_unreadable"
        case .emptyInput: return "empty_input"
        case .uploadLimitExceeded: return "upload_limit_exceeded"
        case .invalidWAV: return "invalid_wav"
        case .unsupportedWAV: return "unsupported_wav"
        case .truncatedInput: return "truncated_input"
        case .duplicateChunk: return "duplicate_chunk"
        case .arithmeticOverflow: return "arithmetic_overflow"
        case .invalidAudioMetadata: return "invalid_audio_metadata"
        case .durationLimitExceeded: return "duration_limit_exceeded"
        case .sampleLimitExceeded: return "sample_limit_exceeded"
        case .conversionFailed: return "conversion_failed"
        }
    }

    public var description: String { code }
}

public struct AudioPreparationPolicy: Equatable, Sendable {
    public static let targetSampleRate = 16_000
    public static let targetChannels = 1
    public static let targetSampleFormat: AudioSampleFormat = .float32

    public let maxUploadBytes: Int
    public let maxDurationSeconds: Int
    public let targetSampleRate: Int
    public let targetChannels: Int
    public let targetSampleFormat: AudioSampleFormat
    public let maxTargetSamples: Int

    public init(configuration: ServiceConfiguration) throws {
        try self.init(
            maxUploadBytes: configuration.maxUploadBytes.value,
            maxDurationSeconds: configuration.maxDurationSeconds.value
        )
    }

    public init(maxUploadBytes: Int, maxDurationSeconds: Int) throws {
        guard maxUploadBytes > 0, maxDurationSeconds > 0 else {
            throw AudioPreparationError.invalidConfiguration
        }
        guard let maxTargetSamples = Self.checkedProduct(maxDurationSeconds, Self.targetSampleRate) else {
            throw AudioPreparationError.configurationArithmeticOverflow
        }

        self.maxUploadBytes = maxUploadBytes
        self.maxDurationSeconds = maxDurationSeconds
        self.targetSampleRate = Self.targetSampleRate
        self.targetChannels = Self.targetChannels
        self.targetSampleFormat = Self.targetSampleFormat
        self.maxTargetSamples = maxTargetSamples
    }

    public func validateFileByteCount(_ byteCount: UInt64) throws {
        guard byteCount <= UInt64(maxUploadBytes) else {
            throw AudioPreparationError.uploadLimitExceeded
        }
    }

    public func validateTargetSampleCount(_ sampleCount: Int) throws {
        guard sampleCount >= 0 else { throw AudioPreparationError.arithmeticOverflow }
        guard sampleCount <= maxTargetSamples else {
            throw AudioPreparationError.sampleLimitExceeded
        }
    }

    static func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }
}

struct AudioRationalRate: Equatable, Sendable {
    let numerator: UInt64
    let denominator: UInt64

    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 768_000 else {
            throw AudioPreparationError.invalidAudioMetadata
        }

        let scale = 1_000_000.0
        let scaled = sampleRate * scale
        guard scaled.isFinite, scaled >= 1, scaled <= Double(UInt64.max) else {
            throw AudioPreparationError.arithmeticOverflow
        }
        let rounded = scaled.rounded()
        guard abs(rounded - scaled) <= 0.5 else {
            throw AudioPreparationError.invalidAudioMetadata
        }

        let rawNumerator = UInt64(rounded)
        let divisor = Self.greatestCommonDivisor(rawNumerator, UInt64(scale))
        numerator = rawNumerator / divisor
        denominator = UInt64(scale) / divisor
    }

    var doubleValue: Double {
        Double(numerator) / Double(denominator)
    }

    func targetSampleEstimate(frameCount: UInt64, targetRate: UInt64) throws -> UInt64 {
        guard let first = checkedMultiply(frameCount, targetRate),
              let product = checkedMultiply(first, denominator)
        else {
            throw AudioPreparationError.arithmeticOverflow
        }
        let quotient = product / numerator
        guard product % numerator == 0 else {
            guard quotient < UInt64.max else { throw AudioPreparationError.arithmeticOverflow }
            return quotient + 1
        }
        return quotient
    }

    func isWithinDuration(frameCount: UInt64, maxDurationSeconds: Int) throws -> Bool {
        guard let lhs = checkedMultiply(frameCount, denominator),
              let rhs = checkedMultiply(UInt64(maxDurationSeconds), numerator)
        else {
            throw AudioPreparationError.arithmeticOverflow
        }
        return lhs <= rhs
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }
}

func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    return result.overflow ? nil : result.partialValue
}

extension UInt64 {
    var asInt: Int? {
        self <= UInt64(Int.max) ? Int(self) : nil
    }
}
