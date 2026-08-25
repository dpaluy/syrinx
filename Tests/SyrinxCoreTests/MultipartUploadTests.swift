import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class MultipartUploadTests: XCTestCase {
    func testParsesParrotShapeWithOneByteChunksAndCleansSuccess() throws {
        let root = try temporaryDirectory()
        let body = multipartBody(boundary: "Parrot-boundary", fields: [
            ("model", "parakeet-tdt-0.6b"),
            ("response_format", "json")
        ], file: Data("RIFF-test".utf8))
        var parser = try MultipartUploadParser(boundary: "Parrot-boundary", temporaryRoot: root)
        for byte in body {
            try parser.consume([byte])
        }
        let upload = try parser.finish()
        XCTAssertEqual(upload.fields["model"], ["parakeet-tdt-0.6b"])
        XCTAssertEqual(try Data(contentsOf: upload.file.url), Data("RIFF-test".utf8))
        let filePath = upload.file.url
        upload.cleanup()
        upload.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 0)
    }

    func testExactAndOverFileLimitsAreCheckedBeforeAppend() throws {
        let root = try temporaryDirectory()
        let boundary = "b"
        let limits = MultipartLimits(envelopeBytes: 100_000, fileBytes: 4, fieldBytes: 64, parts: 8, fileParts: 1, textFields: 7, boundaryBytes: 70, partHeaderLineBytes: 128, partHeaderBytes: 256, bodyBufferBytes: 2, delimiterBytes: 74)
        let exact = multipartBody(boundary: boundary, fields: [], file: Data([1, 2, 3, 4]))
        var parser = try MultipartUploadParser(boundary: boundary, temporaryRoot: root, limits: limits)
        try parser.consume(exact)
        XCTAssertNoThrow(try parser.finish())
        parser.cleanup()

        var over = try MultipartUploadParser(boundary: boundary, temporaryRoot: root, limits: limits)
        XCTAssertThrowsError(try over.consume(multipartBody(boundary: boundary, fields: [], file: Data([1, 2, 3, 4, 5])))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 0)
    }

    func testEnvelopeAndPartHeaderLimitsRejectOneByteOver() throws {
        let root = try temporaryDirectory()
        let boundary = "b"
        let body = multipartBody(boundary: boundary, fields: [], file: Data([1]))
        let envelopeLimits = MultipartLimits(envelopeBytes: body.count - 1, fileBytes: 10, fieldBytes: 10, parts: 8, fileParts: 1, textFields: 7, boundaryBytes: 70, partHeaderLineBytes: 256, partHeaderBytes: 512, bodyBufferBytes: 64, delimiterBytes: 74)
        var envelopeParser = try MultipartUploadParser(boundary: boundary, temporaryRoot: root, limits: envelopeLimits)
        XCTAssertThrowsError(try envelopeParser.consume(body)) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }

        let headerLimits = MultipartLimits(envelopeBytes: 10_000, fileBytes: 10, fieldBytes: 10, parts: 8, fileParts: 1, textFields: 7, boundaryBytes: 70, partHeaderLineBytes: 10, partHeaderBytes: 100, bodyBufferBytes: 64, delimiterBytes: 74)
        var headerParser = try MultipartUploadParser(boundary: boundary, temporaryRoot: root, limits: headerLimits)
        XCTAssertThrowsError(try headerParser.consume(multipartBody(boundary: boundary, fields: [], file: Data([1]), extraFileHeader: String(repeating: "x", count: 5)))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
    }

    func testMalformedTruncatedNestedAndTrailingBodiesCleanUp() throws {
        let root = try temporaryDirectory()
        let boundary = "b"
        let body = multipartBody(boundary: boundary, fields: [], file: Data([1, 2]))

        var truncated = try MultipartUploadParser(boundary: boundary, temporaryRoot: root)
        try truncated.consume(body.dropLast(2))
        XCTAssertThrowsError(try truncated.finish()) { error in
            XCTAssertEqual(error as? MultipartUploadError, .truncatedMultipart)
        }

        var trailing = try MultipartUploadParser(boundary: boundary, temporaryRoot: root)
        XCTAssertThrowsError(try trailing.consume(body + [0x01])) { error in
            XCTAssertEqual(error as? MultipartUploadError, .malformedMultipart)
        }

        var nested = try MultipartUploadParser(boundary: boundary, temporaryRoot: root)
        let nestedBody = multipartBody(boundary: boundary, fields: [], file: Data([1]), fileContentType: "multipart/mixed")
        XCTAssertThrowsError(try nested.consume(nestedBody)) { error in
            XCTAssertEqual(error as? MultipartUploadError, .unsupportedMultipart)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 0)
    }

    func testBoundaryGrammarAndContentTypeAreBounded() {
        XCTAssertNoThrow(try parseMultipartBoundary("multipart/form-data; boundary=abc"))
        XCTAssertThrowsError(try parseMultipartBoundary("multipart/form-data; boundary=" + String(repeating: "a", count: 71))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .malformedMultipart)
        }
        XCTAssertThrowsError(try parseMultipartBoundary("application/octet-stream; boundary=abc")) { error in
            XCTAssertEqual(error as? MultipartUploadError, .unsupportedMultipart)
        }
    }

    func testModesAndExactFileFieldSemanticsAreEnforced() throws {
        let root = try temporaryDirectory()
        let boundary = "b"
        for body in [
            multipartBody(boundary: boundary, fields: [], file: Data([1]), fileFieldName: "audio"),
            multipartBody(boundary: boundary, fields: [("file", "text")], file: Data([1]))
        ] {
            var parser = try MultipartUploadParser(boundary: boundary, temporaryRoot: root)
            XCTAssertThrowsError(try parser.consume(body)) { error in
                XCTAssertEqual(error as? MultipartUploadError, .unsupportedMultipart)
            }
        }
        var values = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])
        XCTAssertTrue(values.isEmpty)

        var valid = try MultipartUploadParser(boundary: boundary, temporaryRoot: root)
        try valid.consume(multipartBody(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data([1])))
        let upload = try valid.finish()
        XCTAssertTrue(upload.file.isClosedForHandoff)
        let directory = upload.file.url.deletingLastPathComponent()
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: upload.file.url.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        values = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(values.count, 1)
        upload.cleanup()
    }

    func testFilenameAndFileFieldRulesRejectDeterministically() throws {
        let root = try temporaryDirectory()
        let invalidDispositions = [
            "form-data; name=\"audio\"; filename=\"client.wav\"",
            "form-data; name=\"file\"",
            "form-data; name=\"model\"; filename=\"client.wav\"",
            "form-data; name=\"response_format\"; filename=\"client.wav\""
        ]
        for disposition in invalidDispositions {
            var parser = try MultipartUploadParser(boundary: "rules", temporaryRoot: root)
            let body = Data("--rules\r\nContent-Disposition: \(disposition)\r\n\r\nvalue\r\n--rules--\r\n".utf8)
            XCTAssertThrowsError(try parser.consume(body)) { error in
                XCTAssertEqual(error as? MultipartUploadError, .unsupportedMultipart)
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
        }
    }

    func testDirectoryReplacementBetweenCreateAndOpenIsRejected() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()

        XCTAssertThrowsError(
            try MultipartUploadParser(
                boundary: "b",
                temporaryRoot: root,
                directoryOpenHook: { directory in
                    try FileManager.default.removeItem(at: directory)
                    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
                }
            )
        ) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadFailed)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil).isEmpty)
    }

    func testTemporaryRootReplacementAfterParentOpenCannotEscapeHeldRoot() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let body = multipartBody(boundary: "root", fields: [], file: Data([1, 2, 3]))
        var parser = try MultipartUploadParser(
            boundary: "root",
            temporaryRoot: root,
            parentOpenHook: { path in
                let heldRoot = path.deletingLastPathComponent().appendingPathComponent("held-\(UUID().uuidString)", isDirectory: true)
                guard rename(path.path, heldRoot.path) == 0 else { throw MultipartUploadError.uploadFailed }
                guard symlink(outside.path, path.path) == 0 else { throw MultipartUploadError.uploadFailed }
            }
        )
        try parser.consume(body)
        let upload = try parser.finish()
        let readBytes = try upload.file.withReadOnlyDescriptor { descriptor -> [UInt8] in
            var bytes = [UInt8](repeating: 0, count: 3)
            return read(descriptor, &bytes, bytes.count) == 3 ? bytes : []
        }
        XCTAssertEqual(readBytes, [1, 2, 3])
        upload.cleanup()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil).isEmpty)
    }

    func testPinnedDescriptorReadsAreRepeatableConcurrentAndCloseOnExec() async throws {
        let root = try temporaryDirectory()
        var parser = try MultipartUploadParser(boundary: "read", temporaryRoot: root)
        try parser.consume(multipartBody(boundary: "read", fields: [], file: Data("original-bytes".utf8)))
        let upload = try parser.finish()

        let expected = Data("original-bytes".utf8)
        for _ in 0..<10 {
            let readResult = try upload.file.withReadOnlyDescriptor { descriptor -> (Data, Bool) in
                let flags = fcntl(descriptor, F_GETFD)
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 32)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                return (data, (flags & FD_CLOEXEC) != 0)
            }
            XCTAssertEqual(readResult.0, expected)
            XCTAssertTrue(readResult.1)
        }

        let concurrentResults = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try upload.file.withReadOnlyDescriptor { descriptor -> Data in
                        var data = Data()
                        var buffer = [UInt8](repeating: 0, count: 32)
                        while true {
                            let count = read(descriptor, &buffer, buffer.count)
                            if count <= 0 { break }
                            data.append(buffer, count: count)
                        }
                        return data
                    }
                }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(concurrentResults, Array(repeating: expected, count: 8))
        upload.cleanup()
        XCTAssertThrowsError(try upload.file.openReadOnlyDescriptor())
    }

    func testFileReplacementAfterFinalWriteFailsClosedBeforeHandoff() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let outsideFile = outside.appendingPathComponent("replacement.wav")
        try Data("replacement".utf8).write(to: outsideFile)
        var parser = try MultipartUploadParser(
            boundary: "handoff",
            temporaryRoot: root,
            fileHandoffHook: { directory in
                let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outsideFile)
            }
        )
        try parser.consume(multipartBody(boundary: "handoff", fields: [], file: Data("original".utf8)))
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadFailed)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("replacement".utf8))
    }

    func testExactAndOverFieldPartAndHeaderLimits() throws {
        let boundary = "b"
        let exactFieldLimits = MultipartLimits(
            envelopeBytes: 100_000, fileBytes: 10, fieldBytes: 4, parts: 8, fileParts: 1,
            textFields: 7, boundaryBytes: 70, partHeaderLineBytes: 256, partHeaderBytes: 512,
            bodyBufferBytes: 64, delimiterBytes: 74
        )
        let exactFieldBody = multipartBody(boundary: boundary, fields: [("model", "abcd")], file: Data([1]))
        let exactRoot = try temporaryDirectory()
        var exactParser = try MultipartUploadParser(boundary: boundary, temporaryRoot: exactRoot, limits: exactFieldLimits)
        try exactParser.consume(exactFieldBody)
        let exactUpload = try exactParser.finish()
        exactUpload.cleanup()

        let overRoot = try temporaryDirectory()
        var overParser = try MultipartUploadParser(boundary: boundary, temporaryRoot: overRoot, limits: exactFieldLimits)
        XCTAssertThrowsError(try overParser.consume(multipartBody(boundary: boundary, fields: [("model", "abcde")], file: Data([1])))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: overRoot, includingPropertiesForKeys: nil).isEmpty)

        let countLimits = MultipartLimits(
            envelopeBytes: 100_000, fileBytes: 10, fieldBytes: 64, parts: 2, fileParts: 1,
            textFields: 1, boundaryBytes: 70, partHeaderLineBytes: 256, partHeaderBytes: 512,
            bodyBufferBytes: 64, delimiterBytes: 74
        )
        let countRoot = try temporaryDirectory()
        var countParser = try MultipartUploadParser(boundary: boundary, temporaryRoot: countRoot, limits: countLimits)
        XCTAssertThrowsError(try countParser.consume(multipartBody(boundary: boundary, fields: [("model", "one"), ("response_format", "json")], file: Data([1])))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: countRoot, includingPropertiesForKeys: nil).isEmpty)

        let textRoot = try temporaryDirectory()
        var textParser = try MultipartUploadParser(boundary: boundary, temporaryRoot: textRoot, limits: countLimits)
        XCTAssertThrowsError(try textParser.consume(multipartBody(boundary: boundary, fields: [("model", "one"), ("other", "two")], file: Data([1])))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: textRoot, includingPropertiesForKeys: nil).isEmpty)

        let headerRoot = try temporaryDirectory()
        let headerLimits = MultipartLimits(
            envelopeBytes: 100_000, fileBytes: 10, fieldBytes: 64, parts: 8, fileParts: 1,
            textFields: 7, boundaryBytes: 70, partHeaderLineBytes: 256, partHeaderBytes: 80,
            bodyBufferBytes: 64, delimiterBytes: 74
        )
        var headerParser = try MultipartUploadParser(boundary: boundary, temporaryRoot: headerRoot, limits: headerLimits)
        XCTAssertThrowsError(try headerParser.consume(multipartBody(boundary: boundary, fields: [], file: Data([1]), extraFileHeader: String(repeating: "x", count: 100)))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: headerRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    func testProductionPartHeaderLineExactAndOneByteOver() throws {
        let exactRoot = try temporaryDirectory()
        let exactExtraHeader = String(repeating: "x", count: 8_182)
        var exactParser = try MultipartUploadParser(boundary: "line", temporaryRoot: exactRoot)
        try exactParser.consume(multipartBody(boundary: "line", fields: [], file: Data([1]), extraFileHeader: exactExtraHeader))
        let exactUpload = try exactParser.finish()
        exactUpload.cleanup()

        let overRoot = try temporaryDirectory()
        let overExtraHeader = String(repeating: "x", count: 8_183)
        var overParser = try MultipartUploadParser(boundary: "line", temporaryRoot: overRoot)
        XCTAssertThrowsError(try overParser.consume(multipartBody(boundary: "line", fields: [], file: Data([1]), extraFileHeader: overExtraHeader))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: overRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    func testProductionAggregatePartHeadersExactAndOneByteOver() throws {
        let exactHeaders = aggregateHeaderBody(boundary: "aggregate-header", extraBytes: 0)
        XCTAssertEqual(headerBlockLength(exactHeaders, boundary: "aggregate-header"), 16 * 1024)
        let exactRoot = try temporaryDirectory()
        var exactParser = try MultipartUploadParser(boundary: "aggregate-header", temporaryRoot: exactRoot)
        for byte in exactHeaders {
            try exactParser.consume([byte])
        }
        let exactUpload = try exactParser.finish()
        exactUpload.cleanup()

        let overRoot = try temporaryDirectory()
        var overParser = try MultipartUploadParser(boundary: "aggregate-header", temporaryRoot: overRoot)
        let overHeaders = aggregateHeaderBody(boundary: "aggregate-header", extraBytes: 1)
        XCTAssertEqual(headerBlockLength(overHeaders, boundary: "aggregate-header"), 16 * 1024 + 1)
        XCTAssertThrowsError(try overParser.consume(overHeaders)) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: overRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    func testProductionPartAndFileCountsExactAndOneByteOver() throws {
        let limits = MultipartLimits(
            envelopeBytes: 100_000, fileBytes: 10, fieldBytes: 64,
            parts: 8, fileParts: 1, textFields: 7, boundaryBytes: 70,
            partHeaderLineBytes: 256, partHeaderBytes: 16 * 1024,
            bodyBufferBytes: 64, delimiterBytes: 74
        )
        let exactFields = (0..<7).map { ("field\($0)", "value") }
        let exactRoot = try temporaryDirectory()
        var exactParser = try MultipartUploadParser(boundary: "counts", temporaryRoot: exactRoot, limits: limits)
        try exactParser.consume(multipartBody(boundary: "counts", fields: exactFields, file: Data([1])))
        let exactUpload = try exactParser.finish()
        exactUpload.cleanup()

        let partsRoot = try temporaryDirectory()
        var partsParser = try MultipartUploadParser(boundary: "counts", temporaryRoot: partsRoot, limits: limits)
        let tooManyFields = exactFields + [("field7", "value")]
        XCTAssertThrowsError(try partsParser.consume(multipartBody(boundary: "counts", fields: tooManyFields, file: Data([1])))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: partsRoot, includingPropertiesForKeys: nil).isEmpty)

        let filePartsRoot = try temporaryDirectory()
        var filePartsParser = try MultipartUploadParser(boundary: "counts", temporaryRoot: filePartsRoot, limits: limits)
        XCTAssertThrowsError(try filePartsParser.consume(multipartBodyWithFiles(boundary: "counts", fields: [], files: [Data([1]), Data([2])]))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: filePartsRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    func testProductionAggregateFieldBoundaryIsExactAndOneByteOver() throws {
        let exactRoot = try temporaryDirectory()
        let exactValue = String(repeating: "x", count: 64 * 1024)
        var exactParser = try MultipartUploadParser(boundary: "aggregate", temporaryRoot: exactRoot)
        try exactParser.consume(multipartBody(boundary: "aggregate", fields: [("other", exactValue)], file: Data([1])))
        let exactUpload = try exactParser.finish()
        XCTAssertEqual(exactUpload.fields["other"]?.first?.utf8.count, 64 * 1024)
        exactUpload.cleanup()

        let overRoot = try temporaryDirectory()
        var overParser = try MultipartUploadParser(boundary: "aggregate", temporaryRoot: overRoot)
        XCTAssertThrowsError(try overParser.consume(multipartBody(boundary: "aggregate", fields: [("other", exactValue + "x")], file: Data([1])))) { error in
            XCTAssertEqual(error as? MultipartUploadError, .uploadTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: overRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return root
    }

    private func multipartBody(
        boundary: String,
        fields: [(String, String)],
        file: Data,
        extraFileHeader: String? = nil,
        fileContentType: String = "audio/wav",
        fileFieldName: String = "file"
    ) -> [UInt8] {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"client-name.wav\"\r\nContent-Type: \(fileContentType)\(extraFileHeader.map { "\r\nX-Test: \($0)" } ?? "")\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return Array(body)
    }

    private func multipartBodyWithFiles(boundary: String, fields: [(String, String)], files: [Data]) -> [UInt8] {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        for file in files {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"client-name.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(file)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return Array(body)
    }

    private func aggregateHeaderBody(boundary: String, extraBytes: Int) -> [UInt8] {
        let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"client-name.wav\"\r\n"
        let first = "X-First: " + String(repeating: "x", count: 8_179) + "\r\n"
        let secondLabel = "X-Second: "
        let secondValueCount = 16 * 1024 - disposition.utf8.count - first.utf8.count - secondLabel.utf8.count - 4 + extraBytes
        let second = secondLabel + String(repeating: "x", count: secondValueCount) + "\r\n"
        let headers = Data((disposition + first + second + "\r\n").utf8)
        return Array(Data("--\(boundary)\r\n".utf8) + headers + Data([1]) + Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private func headerBlockLength(_ body: [UInt8], boundary: String) -> Int {
        let prefix = Array(Data("--\(boundary)\r\n".utf8)).count
        let suffix = Array(Data("\r\n--\(boundary)--\r\n".utf8)).count
        return body.count - prefix - 1 - suffix
    }
}
