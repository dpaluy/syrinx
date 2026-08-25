import Foundation

public struct RIFFWAVFormat: Equatable, Sendable {
    public enum Encoding: String, Equatable, Sendable {
        case pcmInteger
        case pcmFloat
    }

    public let encoding: Encoding
    public let channelCount: Int
    public let sampleRate: UInt32
    public let bitsPerSample: Int
    public let blockAlignment: Int
    public let byteRate: UInt64
}

public struct RIFFWAVInspection: Equatable, Sendable {
    public let fileByteCount: UInt64
    public let format: RIFFWAVFormat
    public let dataByteCount: UInt64
    public let frameCount: UInt64
    public let duration: Double
    public let estimatedTargetSamples: Int
}

public struct RIFFWAVInspector: Sendable {
    private let policy: AudioPreparationPolicy

    public init(policy: AudioPreparationPolicy) {
        self.policy = policy
    }

    public func inspect(fileURL: URL) throws -> RIFFWAVInspection {
        let access = try AudioFileAccess.openReadOnlyRegular(fileURL: fileURL)
        return try inspect(access: access)
    }

    func inspect(access: AudioFileAccess) throws -> RIFFWAVInspection {
        try policy.validateFileByteCount(access.byteCount)
        guard access.byteCount > 0 else { throw AudioPreparationError.emptyInput }
        guard access.byteCount >= 12 else { throw AudioPreparationError.truncatedInput }

        let header = try access.readExactly(12)
        guard header[0..<4] == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) else {
            throw AudioPreparationError.invalidWAV
        }

        let riffSize = try readUInt32(header, at: 4)
        guard riffSize >= 4 else { throw AudioPreparationError.invalidWAV }
        guard let declaredFileSize = checkedAdd(UInt64(riffSize), 8) else {
            throw AudioPreparationError.arithmeticOverflow
        }
        guard declaredFileSize == access.byteCount else {
            throw AudioPreparationError.truncatedInput
        }

        var format: RIFFWAVFormat?
        var dataByteCount: UInt64?
        var dataOffset: UInt64?
        var offset: UInt64 = 12

        while offset < declaredFileSize {
            guard declaredFileSize - offset >= 8 else { throw AudioPreparationError.truncatedInput }
            try access.seek(toOffset: offset)
            let chunkHeader = try access.readExactly(8)
            let chunkSize = UInt64(try readUInt32(chunkHeader, at: 4))
            let padding = chunkSize % 2
            guard let bodyStart = checkedAdd(offset, 8),
                  let bodyEnd = checkedAdd(bodyStart, chunkSize),
                  let nextOffset = checkedAdd(bodyEnd, padding)
            else {
                throw AudioPreparationError.arithmeticOverflow
            }
            guard nextOffset <= declaredFileSize else { throw AudioPreparationError.truncatedInput }

            let identifier = Data(chunkHeader[0..<4])
            if identifier == Data("fmt ".utf8) {
                guard format == nil else { throw AudioPreparationError.duplicateChunk }
                format = try inspectFormat(access: access, bodyStart: bodyStart, chunkSize: chunkSize)
            } else if identifier == Data("data".utf8) {
                guard dataByteCount == nil else { throw AudioPreparationError.duplicateChunk }
                guard chunkSize > 0 else { throw AudioPreparationError.emptyInput }
                dataByteCount = chunkSize
                dataOffset = bodyStart
            }

            try access.seek(toOffset: nextOffset)
            offset = nextOffset
        }

        guard offset == declaredFileSize, let format, let dataByteCount, let dataOffset else {
            throw AudioPreparationError.invalidWAV
        }
        let blockAlignment = UInt64(format.blockAlignment)
        guard dataByteCount % blockAlignment == 0 else {
            throw AudioPreparationError.invalidWAV
        }
        let frameCount = dataByteCount / blockAlignment
        guard frameCount > 0 else { throw AudioPreparationError.emptyInput }
        guard let targetEstimate = try AudioRationalRate(sampleRate: Double(format.sampleRate))
            .targetSampleEstimate(frameCount: frameCount, targetRate: UInt64(policy.targetSampleRate))
            .asInt,
            targetEstimate >= 0
        else {
            throw AudioPreparationError.arithmeticOverflow
        }
        try validateDuration(
            frameCount: frameCount,
            sampleRate: Double(format.sampleRate),
            policy: policy
        )
        try policy.validateTargetSampleCount(targetEstimate)

        if format.encoding == .pcmFloat {
            try validateFiniteFloatData(
                access: access,
                offset: dataOffset,
                byteCount: dataByteCount
            )
        }

        return RIFFWAVInspection(
            fileByteCount: access.byteCount,
            format: format,
            dataByteCount: dataByteCount,
            frameCount: frameCount,
            duration: Double(frameCount) / Double(format.sampleRate),
            estimatedTargetSamples: targetEstimate
        )
    }

    private func inspectFormat(access: AudioFileAccess, bodyStart: UInt64, chunkSize: UInt64) throws -> RIFFWAVFormat {
        guard chunkSize >= 16, chunkSize <= UInt64(Int.max) else {
            throw AudioPreparationError.invalidWAV
        }
        try access.seek(toOffset: bodyStart)
        let fields = try access.readExactly(16)
        let formatTag = try readUInt16(fields, at: 0)
        let channels = try readUInt16(fields, at: 2)
        let sampleRate = try readUInt32(fields, at: 4)
        let byteRate = UInt64(try readUInt32(fields, at: 8))
        let blockAlignment = try readUInt16(fields, at: 12)
        let bitsPerSample = try readUInt16(fields, at: 14)

        guard channels > 0, channels <= 2, sampleRate > 0, blockAlignment > 0, bitsPerSample > 0 else {
            throw AudioPreparationError.invalidWAV
        }
        let bytesPerSample = (UInt64(bitsPerSample) + 7) / 8
        guard bytesPerSample > 0,
              let expectedBlockAlignment = checkedMultiply(UInt64(channels), bytesPerSample),
              expectedBlockAlignment == UInt64(blockAlignment),
              let expectedByteRate = checkedMultiply(UInt64(sampleRate), expectedBlockAlignment),
              expectedByteRate == byteRate
        else {
            throw AudioPreparationError.invalidWAV
        }

        let encoding: RIFFWAVFormat.Encoding
        switch formatTag {
        case 1 where [8, 16, 24, 32].contains(bitsPerSample):
            encoding = .pcmInteger
        case 3 where bitsPerSample == 32:
            encoding = .pcmFloat
        case 1, 3:
            throw AudioPreparationError.unsupportedWAV
        default:
            throw AudioPreparationError.unsupportedWAV
        }

        return RIFFWAVFormat(
            encoding: encoding,
            channelCount: Int(channels),
            sampleRate: sampleRate,
            bitsPerSample: Int(bitsPerSample),
            blockAlignment: Int(blockAlignment),
            byteRate: byteRate
        )
    }

    private func validateFiniteFloatData(access: AudioFileAccess, offset: UInt64, byteCount: UInt64) throws {
        try access.seek(toOffset: offset)
        let chunkBytes = 16 * 1024
        var remaining = byteCount
        while remaining > 0 {
            let count = Int(min(remaining, UInt64(chunkBytes)))
            let data = try access.readExactly(count)
            guard data.count % 4 == 0 else { throw AudioPreparationError.invalidWAV }
            for index in stride(from: 0, to: data.count, by: 4) {
                let bits = try readUInt32(data, at: index)
                guard Float(bitPattern: bits).isFinite else {
                    throw AudioPreparationError.invalidWAV
                }
            }
            remaining -= UInt64(count)
        }
    }

    private func validateDuration(frameCount: UInt64, sampleRate: Double, policy: AudioPreparationPolicy) throws {
        let rate = try AudioRationalRate(sampleRate: sampleRate)
        guard try rate.isWithinDuration(frameCount: frameCount, maxDurationSeconds: policy.maxDurationSeconds) else {
            throw AudioPreparationError.durationLimitExceeded
        }
    }
}

private func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
    guard offset >= 0, offset <= data.count - 2 else { throw AudioPreparationError.truncatedInput }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset <= data.count - 4 else { throw AudioPreparationError.truncatedInput }
    return UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
}

private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? nil : result.partialValue
}
