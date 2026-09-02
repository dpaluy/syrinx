import AVFoundation
import XCTest
@testable import SyrinxClient

final class AudioCaptureTests: XCTestCase {
    func testConverterRefreshesWhenCallbackSourceFormatChanges() throws {
        let converter = AudioCaptureConverter()
        let firstBuffer = try makeBuffer(
            sampleRate: 48_000,
            channels: 2,
            frameLength: 4_800,
            value: 0.25
        )
        let secondBuffer = try makeBuffer(
            sampleRate: 24_000,
            channels: 1,
            frameLength: 2_400,
            value: 0.5
        )

        let firstSamples = try XCTUnwrap(converter.convert(buffer: firstBuffer))
        let secondSamples = try XCTUnwrap(converter.convert(buffer: secondBuffer))

        XCTAssertEqual(converter.targetFormat.sampleRate, 16_000)
        XCTAssertEqual(converter.targetFormat.channelCount, 1)
        XCTAssertEqual(converter.targetFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(converter.targetFormat.isInterleaved)
        // A live converter can hold a short resampling tail between callbacks.
        XCTAssertEqual(Double(firstSamples.count), 1_600, accuracy: 400)
        XCTAssertEqual(Double(secondSamples.count), 1_600, accuracy: 400)
        XCTAssertTrue(firstSamples.allSatisfy { $0.isFinite })
        XCTAssertTrue(secondSamples.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(computeRMS(firstSamples), 0)
        XCTAssertGreaterThan(computeRMS(secondSamples), 0)
    }

    private func makeBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameLength: AVAudioFrameCount,
        value: Float
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw TestError.couldNotCreateBuffer
        }

        buffer.frameLength = frameLength
        guard let channelData = buffer.floatChannelData else {
            throw TestError.couldNotAccessBuffer
        }
        for channel in 0..<Int(channels) {
            channelData[channel].initialize(repeating: value, count: Int(frameLength))
        }
        return buffer
    }

    private enum TestError: Error {
        case couldNotCreateBuffer
        case couldNotAccessBuffer
    }
}
