import Foundation
import XCTest
@testable import SyrinxCore

final class RIFFWAVInspectorTests: XCTestCase {
    func testPCMAndFloatWAVsAcceptUnknownChunksAndOddPadding() throws {
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 3_600)
        let inspector = RIFFWAVInspector(policy: policy)

        let pcm = try temporaryFile(data: makeWAV(
            formatTag: 1,
            channels: 1,
            sampleRate: 16_000,
            bitsPerSample: 16,
            data: [0, 0, 255, 127],
            extraChunks: [("JUNK", [1])]
        ))
        let float = try temporaryFile(data: makeWAV(
            formatTag: 3,
            channels: 1,
            sampleRate: 16_000,
            bitsPerSample: 32,
            data: [0, 0, 128, 63]
        ))
        defer { remove(pcm); remove(float) }

        let pcmResult = try inspector.inspect(fileURL: pcm)
        let floatResult = try inspector.inspect(fileURL: float)

        XCTAssertEqual(pcmResult.format.encoding, .pcmInteger)
        XCTAssertEqual(floatResult.format.encoding, .pcmFloat)
        XCTAssertEqual(pcmResult.frameCount, 2)
        XCTAssertEqual(floatResult.frameCount, 1)
        XCTAssertEqual(pcmResult.estimatedTargetSamples, 2)
    }

    func testExactUploadLimitIsAcceptedAndOneOverIsRejected() throws {
        let data = makeWAV(data: [0, 0])
        let url = try temporaryFile(data: data)
        defer { remove(url) }

        let exact = try AudioPreparationPolicy(maxUploadBytes: data.count, maxDurationSeconds: 3_600)
        XCTAssertEqual(try RIFFWAVInspector(policy: exact).inspect(fileURL: url).fileByteCount, UInt64(data.count))

        let over = try AudioPreparationPolicy(maxUploadBytes: data.count - 1, maxDurationSeconds: 3_600)
        XCTAssertThrowsError(try RIFFWAVInspector(policy: over).inspect(fileURL: url)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .uploadLimitExceeded)
        }
    }

    func testExactDurationIsAcceptedAndOneOverIsRejected() throws {
        let exactURL = try temporaryFile(data: makeWAV(sampleRate: 1_000, bitsPerSample: 16, data: Array(repeating: 0, count: 2_000)))
        let overURL = try temporaryFile(data: makeWAV(sampleRate: 1_000, bitsPerSample: 16, data: Array(repeating: 0, count: 2_002)))
        defer { remove(exactURL); remove(overURL) }
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 1)
        let inspector = RIFFWAVInspector(policy: policy)

        XCTAssertEqual(try inspector.inspect(fileURL: exactURL).duration, 1.0, accuracy: 0.000_001)
        XCTAssertThrowsError(try inspector.inspect(fileURL: overURL)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .durationLimitExceeded)
        }
    }

    func testExactTargetSampleLimitIsAcceptedAndOneOverIsRejected() throws {
        let exactURL = try temporaryFile(data: makeWAV(
            sampleRate: 16_000,
            bitsPerSample: 16,
            data: Array(repeating: 0, count: 32_000)
        ))
        let overURL = try temporaryFile(data: makeWAV(
            sampleRate: 16_000,
            bitsPerSample: 16,
            data: Array(repeating: 0, count: 32_002)
        ))
        defer { remove(exactURL); remove(overURL) }
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 1)
        let inspector = RIFFWAVInspector(policy: policy)

        XCTAssertEqual(try inspector.inspect(fileURL: exactURL).estimatedTargetSamples, 16_000)
        XCTAssertThrowsError(try inspector.inspect(fileURL: overURL)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .durationLimitExceeded)
        }
    }

    func testRejectsMalformedIdentifiersTruncationAndTrailingStructure() throws {
        let valid = makeWAV(data: [0, 0])
        let cases: [Data] = [
            Data("NOPE".utf8) + valid.dropFirst(4),
            valid.prefix(11),
            valid + Data([0]),
            makeWAV(data: [0, 0], riffSizeOverride: 4),
            makeWAV(data: [0, 0], truncateLastByte: true)
        ]
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 3_600)

        for data in cases {
            let url = try temporaryFile(data: data)
            defer { remove(url) }
            XCTAssertThrowsError(try RIFFWAVInspector(policy: policy).inspect(fileURL: url))
        }
    }

    func testRejectsDuplicateChunksAndInvalidFormatFields() throws {
        let fmt = makeFMT(formatTag: 1, channels: 1, sampleRate: 16_000, bitsPerSample: 16)
        let dataChunk = makeChunk("data", [0, 0])
        let cases: [Data] = [
            makeContainer(chunks: [fmt, fmt, dataChunk]),
            makeContainer(chunks: [makeFMT(formatTag: 1, channels: 0, sampleRate: 16_000, bitsPerSample: 16), dataChunk]),
            makeContainer(chunks: [makeFMT(formatTag: 1, channels: 1, sampleRate: 0, bitsPerSample: 16), dataChunk]),
            makeContainer(chunks: [makeFMT(formatTag: 1, channels: 1, sampleRate: 16_000, bitsPerSample: 20), dataChunk]),
            makeContainer(chunks: [makeFMT(formatTag: 1, channels: 1, sampleRate: 16_000, bitsPerSample: 16, blockAlign: 1), dataChunk]),
            makeContainer(chunks: [makeFMT(formatTag: 1, channels: 1, sampleRate: 16_000, bitsPerSample: 16, byteRate: 1), dataChunk]),
            makeContainer(chunks: [makeFMT(formatTag: 1, channels: 1, sampleRate: UInt32.max, bitsPerSample: 16, byteRate: UInt32.max), dataChunk]),
            makeContainer(chunks: [fmt, makeChunk("data", [])]),
            makeContainer(chunks: [fmt, makeChunk("data", [0])])
        ]
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 3_600)

        for data in cases {
            let url = try temporaryFile(data: data)
            defer { remove(url) }
            XCTAssertThrowsError(try RIFFWAVInspector(policy: policy).inspect(fileURL: url))
        }
    }

    func testRejectsUnsupportedEncodingOverflowAndSpecialFiles() throws {
        let unsupported = makeContainer(chunks: [
            makeFMT(formatTag: 0xFFFE, channels: 1, sampleRate: 16_000, bitsPerSample: 16),
            makeChunk("data", [0, 0])
        ])
        let overflowChunk = makeContainer(chunks: [
            makeFMT(formatTag: 1, channels: 1, sampleRate: 16_000, bitsPerSample: 16),
            makeChunk("data", [0, 0], declaredSize: UInt32.max)
        ])
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 3_600)

        for data in [unsupported, overflowChunk] {
            let url = try temporaryFile(data: data)
            defer { remove(url) }
            XCTAssertThrowsError(try RIFFWAVInspector(policy: policy).inspect(fileURL: url))
        }

        let link = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syrinx-audio-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        defer { remove(link) }
        XCTAssertThrowsError(try RIFFWAVInspector(policy: policy).inspect(fileURL: link)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .inputNotRegularFile)
        }
        XCTAssertThrowsError(try RIFFWAVInspector(policy: policy).inspect(fileURL: URL(fileURLWithPath: "/dev/null"))) { error in
            XCTAssertEqual(error as? AudioPreparationError, .inputNotRegularFile)
        }
    }

    func testRejectsNonFiniteFloatSamples() throws {
        let nonFinite = makeContainer(chunks: [
            makeFMT(formatTag: 3, channels: 1, sampleRate: 16_000, bitsPerSample: 32),
            makeChunk("data", [0, 0, 192, 127])
        ])
        let url = try temporaryFile(data: nonFinite)
        defer { remove(url) }
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 3_600)

        XCTAssertThrowsError(try RIFFWAVInspector(policy: policy).inspect(fileURL: url)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .invalidWAV)
        }
    }

    func testChunkSizeBoundaryTableRejectsInconsistentArithmetic() throws {
        let policy = try AudioPreparationPolicy(maxUploadBytes: 25 * 1024 * 1024, maxDurationSeconds: 3_600)
        let sizes: [UInt32] = [0, 1, 2, 3, 4, 7, 8, 65_535, UInt32.max]

        for size in sizes {
            let payloadCount = size <= 8 ? Int(size) : 0
            let unknown = makeChunk("JUNK", Array(repeating: 0, count: payloadCount), declaredSize: size)
            let data = makeContainer(chunks: [unknown, makeFMT(formatTag: 1, channels: 1, sampleRate: 16_000, bitsPerSample: 16), makeChunk("data", [0, 0])])
            let url = try temporaryFile(data: data)
            defer { remove(url) }

            if size <= 8 {
                XCTAssertNoThrow(try RIFFWAVInspector(policy: policy).inspect(fileURL: url), "size=\(size)")
            } else {
                XCTAssertThrowsError(try RIFFWAVInspector(policy: policy).inspect(fileURL: url), "size=\(size)")
            }
        }
    }

    private func makeWAV(
        formatTag: UInt16 = 1,
        channels: UInt16 = 1,
        sampleRate: UInt32 = 16_000,
        bitsPerSample: UInt16 = 16,
        data: [UInt8],
        extraChunks: [(String, [UInt8])] = [],
        riffSizeOverride: UInt32? = nil,
        truncateLastByte: Bool = false
    ) -> Data {
        var chunks = extraChunks.map { makeChunk($0.0, $0.1) }
        chunks.append(makeFMT(formatTag: formatTag, channels: channels, sampleRate: sampleRate, bitsPerSample: bitsPerSample))
        chunks.append(makeChunk("data", data))
        var result = makeContainer(chunks: chunks, riffSizeOverride: riffSizeOverride)
        if truncateLastByte { result.removeLast() }
        return result
    }

    private func makeContainer(chunks: [Data], riffSizeOverride: UInt32? = nil) -> Data {
        var body = Data("WAVE".utf8)
        for chunk in chunks { body.append(chunk) }
        var result = Data("RIFF".utf8)
        appendLE(riffSizeOverride ?? UInt32(body.count), to: &result)
        result.append(body)
        return result
    }

    private func makeFMT(
        formatTag: UInt16,
        channels: UInt16,
        sampleRate: UInt32,
        bitsPerSample: UInt16,
        byteRate: UInt32? = nil,
        blockAlign: UInt16? = nil
    ) -> Data {
        let computedBlockAlign = blockAlign ?? max(1, channels) * max(1, (bitsPerSample + 7) / 8)
        var payload = Data()
        appendLE(formatTag, to: &payload)
        appendLE(channels, to: &payload)
        appendLE(sampleRate, to: &payload)
        appendLE(byteRate ?? sampleRate * UInt32(computedBlockAlign), to: &payload)
        appendLE(computedBlockAlign, to: &payload)
        appendLE(bitsPerSample, to: &payload)
        return makeChunk("fmt ", Array(payload))
    }

    private func makeChunk(_ identifier: String, _ payload: [UInt8], declaredSize: UInt32? = nil) -> Data {
        var result = Data(identifier.utf8.prefix(4))
        appendLE(declaredSize ?? UInt32(payload.count), to: &result)
        result.append(contentsOf: payload)
        if payload.count % 2 == 1 { result.append(0) }
        return result
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func temporaryFile(data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syrinx-audio-test-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data))
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
