import AVFoundation
import Foundation
import XCTest
@testable import SyrinxCore

final class AudioMetadataAndNormalizerTests: XCTestCase {
    func testMetadataPreflightRejectsEmptyInputBeforeConversion() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syrinx-empty-\(UUID().uuidString).wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: url) }

        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 3_600)
        XCTAssertThrowsError(try AVAudioMetadataPreflight(policy: policy).inspect(fileURL: url)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .emptyInput)
        }
    }

    func testMetadataPreflightRejectsSymlinkAndChecksExpansion() throws {
        let source = try makePCMFile(sampleRate: 8_000, frameCount: 8_000)
        defer { remove(source) }
        let link = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syrinx-metadata-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        defer { remove(link) }

        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 1)
        XCTAssertThrowsError(try AVAudioMetadataPreflight(policy: policy).inspect(fileURL: link)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .inputNotRegularFile)
        }

        let metadata = try AVAudioMetadataPreflight(policy: policy).inspect(fileURL: source)
        XCTAssertEqual(metadata.sampleRate, 8_000, accuracy: 0.001)
        XCTAssertEqual(metadata.channelCount, 1)
        XCTAssertEqual(metadata.frameLength, 8_000)
        XCTAssertEqual(metadata.estimatedTargetSamples, 16_000)
    }

    func testNormalizerWritesExactMonoFloat32AndCleansOnSuccessErrorAndCancellation() async throws {
        let source = try makePCMFile(sampleRate: 8_000, frameCount: 8_000)
        defer { remove(source) }
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 1)
        let normalizer = AudioNormalizer(policy: policy)
        let prefix = "syrinx-audio-"
        let before = temporaryEntries(prefix: prefix)

        let preparedURL = try await normalizer.withNormalizedAudio(from: source) { prepared in
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
            XCTAssertEqual(prepared.sampleCount, 16_000)
            XCTAssertEqual(prepared.duration, 1.0, accuracy: 0.001)
            let normalized = try AVAudioFile(forReading: prepared.fileURL)
            XCTAssertEqual(normalized.processingFormat.sampleRate, 16_000, accuracy: 0.001)
            XCTAssertEqual(normalized.processingFormat.channelCount, 1)
            XCTAssertEqual(normalized.processingFormat.commonFormat, .pcmFormatFloat32)
            XCTAssertFalse(normalized.processingFormat.isInterleaved)
            let attributes = try FileManager.default.attributesOfItem(atPath: prepared.fileURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let parentAttributes = try FileManager.default.attributesOfItem(atPath: prepared.fileURL.deletingLastPathComponent().path)
            XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            return prepared.fileURL
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path))
        XCTAssertEqual(temporaryEntries(prefix: prefix), before)

        do {
            _ = try await normalizer.withNormalizedAudio(from: source) { prepared in
                XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
                throw TestError.expected
            }
            XCTFail("expected operation error")
        } catch TestError.expected {
            XCTAssertEqual(temporaryEntries(prefix: prefix), before)
        }

        do {
            _ = try await normalizer.withNormalizedAudio(from: source) { _ in
                throw CancellationError()
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(temporaryEntries(prefix: prefix), before)
        }
    }

    func testPhaseBoundaryReplacementCannotBypassTheOpenedSourceAdmission() async throws {
        let source = try makePCMFile(sampleRate: 8_000, frameCount: 8_000)
        let replacement = try makePCMFile(sampleRate: 16_000, frameCount: 16_001)
        defer { remove(source); remove(replacement) }
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 1)
        XCTAssertThrowsError(try AVAudioMetadataPreflight(policy: policy).inspect(fileURL: replacement)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .durationLimitExceeded)
        }

        let normalizer = AudioNormalizer(policy: policy, phaseBoundaryHook: {
            try? FileManager.default.removeItem(at: source)
            try FileManager.default.moveItem(at: replacement, to: source)
        })

        let sampleCount = try await normalizer.withNormalizedAudio(from: source) { prepared in
            prepared.sampleCount
        }
        XCTAssertEqual(sampleCount, 16_000)
    }

    func testNormalizerBoundsOutputForCommonRatesAndResamplingTail() async throws {
        let cases: [(rate: Int, frames: Int)] = [
            (8_000, 8_000),
            (44_100, 44_101),
            (48_000, 48_001)
        ]

        for audioCase in cases {
            let source = try makePCMFile(sampleRate: audioCase.rate, frameCount: audioCase.frames)
            defer { remove(source) }
            let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 2)
            let normalizer = AudioNormalizer(policy: policy)
            let result = try await normalizer.withNormalizedAudio(from: source) { prepared in
                let normalized = try AVAudioFile(forReading: prepared.fileURL)
                return (prepared, normalized.length)
            }

            let expectedTargetSamples = Double(audioCase.frames) * 16_000.0 / Double(audioCase.rate)
            // AVAudioConverter may round the final drained frame by one target sample.
            // Check both bounds so a dropped output tail cannot pass.
            let avFoundationRoundingTolerance = 1.0
            let actualTargetSamples = Double(result.0.sampleCount)
            XCTAssertGreaterThanOrEqual(
                actualTargetSamples,
                expectedTargetSamples - avFoundationRoundingTolerance,
                "rate=\(audioCase.rate)"
            )
            XCTAssertLessThanOrEqual(
                actualTargetSamples,
                expectedTargetSamples + avFoundationRoundingTolerance,
                "rate=\(audioCase.rate)"
            )
            XCTAssertEqual(result.0.sampleCount, Int(result.1), "rate=\(audioCase.rate)")
            XCTAssertEqual(
                result.0.duration,
                Double(result.0.sampleCount) / 16_000.0,
                accuracy: 0.000_000_1
            )
        }
    }

    func testNormalizerRejectsSampleLimitBeforeLargeConversion() async throws {
        let source = try makePCMFile(sampleRate: 16_000, frameCount: 16_001)
        defer { remove(source) }
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 1)

        do {
            _ = try await AudioNormalizer(policy: policy).withNormalizedAudio(from: source) { _ in
                XCTFail("conversion must not start")
                return ()
            }
            XCTFail("expected sample limit")
        } catch let error as AudioPreparationError {
            XCTAssertEqual(error, .durationLimitExceeded)
        }
    }

    func testPostConversionSampleCeilingIsChecked() throws {
        let policy = try AudioPreparationPolicy(maxUploadBytes: 1, maxDurationSeconds: 1)
        let normalizer = AudioNormalizer(policy: policy)

        XCTAssertNoThrow(try normalizer.validateConvertedSampleCount(16_000))
        XCTAssertThrowsError(try normalizer.validateConvertedSampleCount(16_001)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .sampleLimitExceeded)
        }
    }

    func testCancellationBeforeOpenIsReturnedAsCancellation() async throws {
        let source = try makePCMFile(sampleRate: 8_000, frameCount: 8_000)
        defer { remove(source) }
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 1)
        let task = Task {
            try await AudioNormalizer(policy: policy).withNormalizedAudio(from: source) { _ in () }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        }
    }

    private enum TestError: Error { case expected }

    private func makePCMFile(sampleRate: Int, frameCount: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syrinx-pcm-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(frameCount, 4_096)))!
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        var remaining = frameCount
        while remaining > 0 {
            let count = min(remaining, Int(buffer.frameCapacity))
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            remaining -= count
        }
        return url
    }

    private func temporaryEntries(prefix: String) -> Set<String> {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
