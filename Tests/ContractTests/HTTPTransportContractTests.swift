import Foundation
import Darwin
import Hummingbird
import HummingbirdCore
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
import ServiceLifecycleTestKit
import XCTest
@testable import SyrinxCore

final class HTTPTransportContractTests: XCTestCase {
    func testLiveHealthModelsAndParrotCompatibleUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let fake = FakeHTTPHandler()
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(
                    port: Port(5093),
                    maxUploadBytes: ByteLimit(1024, key: "test"),
                    maxEnvelopeBytes: ByteLimit(4096, key: "test-envelope"),
                    maxJobs: JobLimit(1, key: "test-jobs"),
                    bearerSecret: "secret"
                ),
                temporaryRoot: root
            ),
            handler: fake,
            readiness: ReadinessSource { true }
        )
        let app = service.application()
        try await app.test(.live) { client in
            var apiHeaders = HTTPFields()
            apiHeaders[.authorization] = "Bearer secret"
            let health = try await client.execute(uri: "/health", method: .get, headers: apiHeaders)
            XCTAssertEqual(health.status, .ok)
            XCTAssertEqual(String(buffer: health.body), #"{"status":"ok"}"#)
            XCTAssertNil(health.headers[.location])
            XCTAssertEqual(health.headers[HTTPField.Name("Cache-Control")!], "no-store")
            XCTAssertNotNil(health.headers[HTTPField.Name("X-Request-ID")!])
            XCTAssertNil(health.headers[HTTPField.Name("Access-Control-Allow-Origin")!])

            let models = try await client.execute(uri: "/v1/models", method: .get, headers: apiHeaders)
            XCTAssertEqual(models.status, .ok)
            XCTAssertTrue(String(buffer: models.body).contains("parakeet-tdt-0.6b-v3"))
            XCTAssertTrue(String(buffer: models.body).contains("parakeet-tdt-0.6b"))

            let boundary = "Parrot-test"
            let body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nparakeet-tdt-0.6b\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n--\(boundary)--\r\n".utf8)
            var headers = HTTPFields()
            headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
            headers[.authorization] = "Bearer secret"
            let response = try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: ByteBuffer(bytes: body))
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(String(buffer: response.body), #"{"text":"fake transcript"}"#)
            let model = await fake.model()
            XCTAssertEqual(model, "parakeet-tdt-0.6b-v3")

            let activeCount = await service.admission.activeCount
            XCTAssertEqual(activeCount, 0)

        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 0)
    }

    func testCanonicalModelLiveUploadUsesSeparateServer() async throws {
        let service = SyrinxHTTPService(handler: FakeHTTPHandler())
        try await service.application().test(.live) { client in
            let boundary = "Parrot-canonical"
            let body = multipartData(
                boundary: boundary,
                fields: [("model", "parakeet-tdt-0.6b-v3"), ("response_format", "json")],
                file: Data("RIFF\r\n".utf8)
            )
            var headers = HTTPFields()
            headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
            let response = try await client.execute(
                uri: "/v1/audio/transcriptions",
                method: .post,
                headers: headers,
                body: ByteBuffer(bytes: body)
            )
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(String(buffer: response.body), #"{"text":"fake transcript"}"#)
        }
    }

    func testAuthRejectsBeforeBodyConsumptionAndReadinessIsTruthful() async throws {
        let bodyRead = BodyReadCounter()
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(
                    port: Port(5094),
                    bearerSecret: "secret"
                )
            ),
            handler: FakeHTTPHandler(),
            readiness: ReadinessSource { false }
        )
        let router = service.router()
        let responder = router.buildResponder()
        for token in [nil, "", "wrong", String(repeating: "x", count: 4096)] {
            var headers = HTTPFields()
            headers[.contentType] = "multipart/form-data; boundary=b"
            if let token {
                headers[.authorization] = token.isEmpty ? "Bearer " : "Bearer \(token)"
            }
            let head = HTTPRequest(method: .post, url: URL(string: "http://127.0.0.1/v1/audio/transcriptions")!, headerFields: headers)
            let request = Request(head: head, body: .init(asyncSequence: CountingSequence(counter: bodyRead)))
            let response = try await responder.respond(to: request, context: BasicRequestContext(source: .init(channel: EmbeddedChannel(), logger: Logger(label: "test"))))
            XCTAssertEqual(response.status, HTTPResponse.Status.unauthorized)
        }
        let reads = await bodyRead.snapshot()
        XCTAssertEqual(reads, 0)
        let health = try await router.buildResponder().respond(to: Request(head: .init(method: .get, scheme: nil, authority: nil, path: "/health", headerFields: [:]), body: .init(buffer: ByteBuffer())), context: BasicRequestContext(source: .init(channel: EmbeddedChannel(), logger: Logger(label: "test"))))
        XCTAssertEqual(health.status, HTTPResponse.Status.unauthorized)
    }

    func testAllAPIGetRoutesRequireBearerAuth() async throws {
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(port: Port(5097), bearerSecret: "secret")
            ),
            handler: FakeHTTPHandler()
        )
        try await service.application().test(.live) { client in
            for uri in ["/health", "/v1/models"] {
                for token in [nil, "Bearer ", "Bearer wrong", "Bearer \(String(repeating: "x", count: 4096))"] {
                    var headers = HTTPFields()
                    if let token {
                        headers[.authorization] = token
                    }
                    let response = try await client.execute(uri: uri, method: .get, headers: headers)
                    XCTAssertEqual(response.status, .unauthorized)
                }
                var correct = HTTPFields()
                correct[.authorization] = "Bearer secret"
                let response = try await client.execute(uri: uri, method: .get, headers: correct)
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testHealthIsNotReadyDuringDrain() async throws {
        let service = SyrinxHTTPService(handler: FakeHTTPHandler())
        await service.beginDrain()
        let request = Request(
            head: .init(method: .get, scheme: nil, authority: nil, path: "/health", headerFields: [:]),
            body: .init(buffer: ByteBuffer())
        )
        let response = try await service.router().buildResponder().respond(
            to: request,
            context: BasicRequestContext(source: .init(channel: EmbeddedChannel(), logger: Logger(label: "test")))
        )
        XCTAssertEqual(response.status, .serviceUnavailable)
    }

    func testHandlerReadsPinnedDescriptorAfterPathReplacement() async throws {
        let root = try temporaryDirectory(named: "syrinx-pinned")
        let outside = try temporaryDirectory(named: "syrinx-outside")
        let outsideFile = outside.appendingPathComponent("outside.wav")
        try Data("outside".utf8).write(to: outsideFile)
        let handler = ReplacingHTTPHandler(outsideFile: outsideFile)
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(temporaryRoot: root),
            handler: handler
        )
        let boundary = "replace"
        let body = multipartBody(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data("original".utf8))
        var headers = HTTPFields()
        headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
        let requestHeaders = headers
        try await service.application().test(.live) { client in
            let response = try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: requestHeaders, body: ByteBuffer(bytes: body))
            XCTAssertEqual(response.status, .ok)
        }
        let readBytes = await handler.readBytes()
        XCTAssertEqual(readBytes, Data("original".utf8))
        let handlerError = await handler.error()
        XCTAssertNil(handlerError)
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return directory
    }

    func testContentLengthAndAdmissionRejectionsDoNotReadBody() async throws {
        let counter = BodyReadCounter()
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(
                    port: Port(5095),
                    maxEnvelopeBytes: ByteLimit(10, key: "test-envelope"),
                    maxJobs: JobLimit(1, key: "test-jobs"),
                    bearerSecret: "secret"
                )
            ),
            handler: FakeHTTPHandler()
        )
        let responder = service.router().buildResponder()
        for length in ["11", "-1", "x", "1,2"] {
            var headers = HTTPFields()
            headers[.authorization] = "Bearer secret"
            headers[.contentLength] = length
            let head = HTTPRequest(method: .post, url: URL(string: "http://127.0.0.1/v1/audio/transcriptions")!, headerFields: headers)
            let request = Request(head: head, body: .init(asyncSequence: CountingSequence(counter: counter)))
            let response = try await responder.respond(to: request, context: BasicRequestContext(source: .init(channel: EmbeddedChannel(), logger: Logger(label: "test"))))
            XCTAssertTrue([HTTPResponse.Status.contentTooLarge, .badRequest].contains(response.status))
        }
        let firstReadCount = await counter.snapshot()
        XCTAssertEqual(firstReadCount, 0)

        _ = await service.admission.admit()
        var headers = HTTPFields()
        headers[.authorization] = "Bearer secret"
        let request = Request(
            head: HTTPRequest(method: .post, url: URL(string: "http://127.0.0.1/v1/audio/transcriptions")!, headerFields: headers),
            body: .init(asyncSequence: CountingSequence(counter: counter))
        )
        let response = try await responder.respond(to: request, context: BasicRequestContext(source: .init(channel: EmbeddedChannel(), logger: Logger(label: "test"))))
        XCTAssertEqual(response.status, HTTPResponse.Status.serviceUnavailable)
        let secondReadCount = await counter.snapshot()
        XCTAssertEqual(secondReadCount, 0)
    }

    func testUnsupportedUploadFieldsModelFormatAndDuplicatesAreStable() async throws {
        let cases: [(fields: [(String, String)], status: HTTPResponse.Status, code: String)] = [
                ([("model", "unknown")], .unprocessableContent, "unsupported_model"),
                ([("model", "parakeet-tdt-0.6b"), ("response_format", "text")], .unprocessableContent, "unsupported_format"),
                ([("model", "parakeet-tdt-0.6b"), ("model", "parakeet-tdt-0.6b")], .unprocessableContent, "unsupported_field"),
                ([("model", "parakeet-tdt-0.6b"), ("response_format", "json"), ("unknown", "value")], .unprocessableContent, "unsupported_field"),
                ([("model", "parakeet-tdt-0.6b"), ("response_format", "json"), ("translation", "true")], .unprocessableContent, "unsupported_field"),
                ([("model", "parakeet-tdt-0.6b"), ("response_format", "json"), ("stream", "true")], .unprocessableContent, "unsupported_field")
        ]
        for (index, testCase) in cases.enumerated() {
            let service = SyrinxHTTPService(handler: FakeHTTPHandler())
            try await service.application().test(.live) { client in
                let boundary = "stable-\(index)"
                let body = multipartData(boundary: boundary, fields: testCase.fields, file: Data([1]))
                var headers = HTTPFields()
                headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                let response = try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: ByteBuffer(bytes: body))
                XCTAssertEqual(response.status, testCase.status)
                XCTAssertEqual(String(buffer: response.body), "{\"error\":{\"code\":\"\(testCase.code)\"}}")
                let activeCount = await service.admission.activeCount
                XCTAssertEqual(activeCount, 0)
            }
        }
    }

    func testAdmissionDrainRejectsNewRequests() async {
        let admission = HTTPAdmission(maximum: 1)
        let firstAdmission = await admission.admit()
        XCTAssertTrue(firstAdmission)
        let secondAdmission = await admission.admit()
        XCTAssertFalse(secondAdmission)
        await admission.beginDrain()
        let draining = await admission.isDraining
        XCTAssertTrue(draining)
        await admission.release()
        let afterDrainAdmission = await admission.admit()
        XCTAssertFalse(afterDrainAdmission)
    }

    func testRequestDeadlineCancelsHandlerAndCleansUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(
                    port: Port(5096),
                    httpRequestTimeoutMilliseconds: DurationLimit(20, key: "test-request-timeout")
                ),
                temporaryRoot: root
            ),
            handler: SlowHTTPHandler()
        )
        let boundary = "deadline"
        var requestHeaders = HTTPFields()
        requestHeaders[.contentType] = "multipart/form-data; boundary=\(boundary)"
        let headers = requestHeaders
        let body = multipartBody(
            boundary: boundary,
            fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")],
            file: Data([1])
        )
        try await service.application().test(.live) { client in
            let response = try await client.execute(
                uri: "/v1/audio/transcriptions",
                method: .post,
                headers: headers,
                body: ByteBuffer(bytes: body)
            )
            XCTAssertEqual(response.status, .requestTimeout)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    func testRawSocketBoundaryExactAndOneByteOverUseSeparateServers() async throws {
        let exactBoundary = String(repeating: "b", count: 70)
        let exactService = SyrinxHTTPService(handler: FakeHTTPHandler())
        try await exactService.application().test(.live) { client in
            let body = multipartData(boundary: exactBoundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data([1]))
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: exactBoundary, body: body))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.header("content-type"), "application/json")
        }

        let overBoundary = String(repeating: "b", count: 71)
        let overService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
            service: try ServiceConfiguration(maxUploadBytes: ByteLimit(26 * 1024 * 1024, key: "test-file"), maxEnvelopeBytes: ByteLimit(26 * 1024 * 1024, key: "test-envelope"))
            ),
            handler: FakeHTTPHandler()
        )
        try await overService.application().test(.live) { client in
            let body = multipartData(boundary: overBoundary, fields: [], file: Data([1]))
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: overBoundary, body: body))
            XCTAssertEqual(response.status, 400)
            XCTAssertEqual(response.errorCode, "malformed_multipart")
        }
    }

    func testRawSocketHeaderFieldAndListExactAndOneByteOverUseSeparateServers() async throws {
        let exactFieldService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(httpHeaderFieldBytes: ByteLimit(256, key: "test-field"))
            ),
            handler: FakeHTTPHandler()
        )
        try await exactFieldService.application().test(.live) { client in
            let value = String(repeating: "x", count: 251)
            let request = Data("GET /health HTTP/1.1\r\nX-Pad: \(value)\r\nConnection: close\r\n\r\n".utf8)
            let response = try await rawHTTP(port: client.port!, request: request)
            XCTAssertEqual(response.status, 200)
        }

        let overFieldService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(httpHeaderFieldBytes: ByteLimit(256, key: "test-field"))
            ),
            handler: FakeHTTPHandler()
        )
        try await overFieldService.application().test(.live) { client in
            let value = String(repeating: "x", count: 300)
            let request = Data("GET /health HTTP/1.1\r\nX-Pad: \(value)\r\nConnection: close\r\n\r\n".utf8)
            let response = try await rawHTTP(port: client.port!, request: request)
            XCTAssertNotEqual(response.status, 200)
        }

        let exactListService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(httpHeaderListBytes: ByteLimit(300, key: "test-list"))
            ),
            handler: FakeHTTPHandler()
        )
        try await exactListService.application().test(.live) { client in
            let value = String(repeating: "x", count: 240)
            let request = Data("GET /health HTTP/1.1\r\nX-Pad: \(value)\r\nConnection: close\r\n\r\n".utf8)
            let response = try await rawHTTP(port: client.port!, request: request)
            XCTAssertEqual(response.status, 200)
        }

        let overListService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(httpHeaderListBytes: ByteLimit(300, key: "test-list"))
            ),
            handler: FakeHTTPHandler()
        )
        try await overListService.application().test(.live) { client in
            let value = String(repeating: "x", count: 290)
            let request = Data("GET /health HTTP/1.1\r\nX-Pad: \(value)\r\nConnection: close\r\n\r\n".utf8)
            let response = try await rawHTTP(port: client.port!, request: request)
            XCTAssertNotEqual(response.status, 200)
        }
    }

    func testRawSocketExactAndOverProductionEnvelopeUseSeparateServers() async throws {
        // The exact request is 26 MiB. Keep a finite 30-second deadline, which
        // allows the test host at least 1 MiB/s for the body plus response and
        // leaves a small protocol margin without changing the production limit.
        let productionEnvelopeTimeout: Duration = .seconds(30)
        let exactService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(maxUploadBytes: ByteLimit(26 * 1024 * 1024, key: "test-file"), maxEnvelopeBytes: ByteLimit(26 * 1024 * 1024, key: "test-envelope"))
            ),
            handler: FakeHTTPHandler()
        )
        try await exactService.application().test(.live) { client in
            let boundary = "envelope"
            let emptyBody = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data())
            let fileBytes = 26 * 1024 * 1024 - emptyBody.count
            let body = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data(repeating: 1, count: fileBytes))
            XCTAssertEqual(body.count, 26 * 1024 * 1024)
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body), timeout: productionEnvelopeTimeout)
            XCTAssertEqual(response.status, 200)
        }

        let overService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(
                    maxUploadBytes: ByteLimit(26 * 1024 * 1024, key: "test-file"),
                    maxEnvelopeBytes: ByteLimit(26 * 1024 * 1024, key: "test-envelope")
                )
            ),
            handler: FakeHTTPHandler()
        )
        try await overService.application().test(.live) { client in
            let boundary = "envelope"
            let emptyBody = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data())
            let fileBytes = 26 * 1024 * 1024 - emptyBody.count + 1
            let body = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data(repeating: 1, count: fileBytes))
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body), timeout: productionEnvelopeTimeout)
            XCTAssertEqual(response.status, 413)
            XCTAssertEqual(response.errorCode, "upload_too_large")
        }
    }

    func testRawSocketExactAndOverProductionFileUseSeparateServers() async throws {
        // The exact request carries a 25 MiB file. Keep a finite 30-second
        // deadline, which allows the test host at least 1 MiB/s for the body
        // plus response and leaves a small protocol margin.
        let productionFileTimeout: Duration = .seconds(30)
        let exactRoot = try temporaryDirectory(named: "syrinx-file-exact")
        let exactService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(temporaryRoot: exactRoot),
            handler: FakeHTTPHandler()
        )
        try await exactService.application().test(.live) { client in
            let boundary = "file-limit"
            let body = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data(repeating: 1, count: 25 * 1024 * 1024))
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body), timeout: productionFileTimeout)
            XCTAssertEqual(response.status, 200)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: exactRoot, includingPropertiesForKeys: nil).isEmpty)

        let overRoot = try temporaryDirectory(named: "syrinx-file-over")
        let overService = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(temporaryRoot: overRoot),
            handler: FakeHTTPHandler()
        )
        try await overService.application().test(.live) { client in
            let boundary = "file-limit"
            let body = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data(repeating: 1, count: 25 * 1024 * 1024 + 1))
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body), timeout: productionFileTimeout)
            XCTAssertEqual(response.status, 413)
            XCTAssertEqual(response.errorCode, "upload_too_large")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: overRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    func testRawSocketExactAndOverAggregateFieldsUseSeparateServers() async throws {
        let exactService = SyrinxHTTPService(handler: FakeHTTPHandler())
        try await exactService.application().test(.live) { client in
            let boundary = "fields"
            let body = multipartData(boundary: boundary, fields: [("other", String(repeating: "x", count: 64 * 1024))], file: Data([1]))
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body))
            XCTAssertEqual(response.status, 422)
            XCTAssertEqual(response.errorCode, "unsupported_field")
        }

        let overService = SyrinxHTTPService(handler: FakeHTTPHandler())
        try await overService.application().test(.live) { client in
            let boundary = "fields"
            let body = multipartData(boundary: boundary, fields: [("other", String(repeating: "x", count: 64 * 1024 + 1))], file: Data([1]))
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body))
            XCTAssertEqual(response.status, 413)
            XCTAssertEqual(response.errorCode, "upload_too_large")
        }
    }

    func testRawSocketMalformedAndTruncatedBodiesReturnStableErrors() async throws {
        let malformedService = SyrinxHTTPService(handler: FakeHTTPHandler())
        try await malformedService.application().test(.live) { client in
            let boundary = "malformed"
            var body = multipartData(boundary: boundary, fields: [], file: Data([1]))
            body[0] = 0x58
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body))
            XCTAssertEqual(response.status, 400)
            XCTAssertEqual(response.errorCode, "malformed_multipart")
        }

        let truncatedService = SyrinxHTTPService(handler: FakeHTTPHandler())
        try await truncatedService.application().test(.live) { client in
            let boundary = "truncated"
            let body = multipartData(boundary: boundary, fields: [], file: Data([1])).dropLast(2)
            let response = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: Data(body)))
            XCTAssertEqual(response.status, 400)
            XCTAssertEqual(response.errorCode, "truncated_multipart")
        }
    }

    func testRawSocketSlowReaderClosesAndCleansUpload() async throws {
        let root = try temporaryDirectory(named: "syrinx-slow")
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(httpIdleTimeoutMilliseconds: DurationLimit(100, key: "test-idle")),
                temporaryRoot: root
            ),
            handler: FakeHTTPHandler()
        )
        try await service.application().test(.live) { client in
            let boundary = "slow"
            let body = multipartData(boundary: boundary, fields: [], file: Data(repeating: 1, count: 100))
            let split = body.count / 2
            let socket = try RawSocket(port: client.port!)
            try socket.send(Data(postRequestPrefix(boundary: boundary, length: body.count).utf8))
            try socket.send(Data(body.prefix(split)))
            try await Task.sleep(for: .milliseconds(250))
            let response = try socket.receiveResponse()
            XCTAssertTrue(response.isEmpty)
            socket.close()
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    func testRawSocketDisconnectCancelsAndCleansUpload() async throws {
        let root = try temporaryDirectory(named: "syrinx-disconnect")
        let service = SyrinxHTTPService(configuration: HTTPServiceConfiguration(temporaryRoot: root), handler: FakeHTTPHandler())
        try await service.application().test(.live) { client in
            let boundary = "disconnect"
            let body = multipartData(boundary: boundary, fields: [], file: Data(repeating: 1, count: 100))
            let socket = try RawSocket(port: client.port!)
            try socket.send(Data(postRequestPrefix(boundary: boundary, length: body.count).utf8))
            try socket.send(Data(body.prefix(body.count / 2)))
            socket.close()
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    func testConcurrentRawRequestsRejectOverloadAndReleaseActiveCount() async throws {
        let handler = BlockingHTTPHandler(delayMilliseconds: 300)
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(service: try ServiceConfiguration(maxJobs: JobLimit(1, key: "test-jobs"))),
            handler: handler
        )
        try await service.application().test(.live) { client in
            let boundary = "overload"
            let body = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data([1]))
            let first = Task {
                try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body))
            }
            try await waitUntil(timeoutMilliseconds: 1_000) { await handler.started() }
            let second = try await rawHTTP(port: client.port!, request: postRequest(boundary: boundary, body: body))
            XCTAssertEqual(second.status, 503)
            XCTAssertEqual(second.errorCode, "overloaded")
            let firstResponse = try await withDeadline(.seconds(5)) { try await first.value }
            XCTAssertEqual(firstResponse.status, 200)
            let activeCount = await service.admission.activeCount
            XCTAssertEqual(activeCount, 0)
        }
    }

    func testActiveUploadDrainRejectsNewRequestAndWaitsForZero() async throws {
        let handler = BlockingHTTPHandler(delayMilliseconds: 250)
        let service = SyrinxHTTPService(handler: handler)
        try await service.application().test(.live) { client in
            let boundary = "drain-active"
            let body = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data([1]))
            let first = Task {
                try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: [.contentType: "multipart/form-data; boundary=\(boundary)"], body: ByteBuffer(bytes: body))
            }
            try await waitUntil(timeoutMilliseconds: 1_000) { await handler.started() }
            await service.beginDrain()
            let rejected = try await rawHTTP(port: client.port!, request: Data("GET /health HTTP/1.1\r\nConnection: close\r\n\r\n".utf8))
            XCTAssertEqual(rejected.status, 503)
            XCTAssertEqual(rejected.errorCode, "not_ready")
            let response = try await withDeadline(.seconds(5)) { try await first.value }
            XCTAssertEqual(response.status, .ok)
            let activeCount = await service.admission.activeCount
            XCTAssertEqual(activeCount, 0)
        }
    }

    func testRunObservesGracefulShutdownAfterActiveWorkDrains() async throws {
        let handler = BlockingHTTPHandler(delayMilliseconds: 250)
        let service = SyrinxHTTPService(
            configuration: HTTPServiceConfiguration(
                service: try ServiceConfiguration(
                    port: try Port(5098),
                    shutdownTimeoutSeconds: ShutdownTimeout(2, key: "test-shutdown")
                )
            ),
            handler: handler
        )
        try await testGracefulShutdown { trigger in
            let runTask = Task { try await service.run() }
            let healthRequest = Data("GET /health HTTP/1.1\r\nConnection: close\r\n\r\n".utf8)
            try await waitUntil(timeoutMilliseconds: 1_000) {
                guard let response = try? await rawHTTP(port: 5098, request: healthRequest, host: "127.0.0.1") else { return false }
                return response.status == 200
            }
            let boundary = "run-drain"
            let body = multipartData(boundary: boundary, fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")], file: Data([1]))
            let uploadTask = Task {
                try await rawHTTP(port: 5098, request: postRequest(boundary: boundary, body: body), host: "127.0.0.1")
            }
            try await waitUntil(timeoutMilliseconds: 1_000) { await handler.started() }
            let rejectedSocket = try RawSocket(port: 5098, host: "127.0.0.1")
            defer { rejectedSocket.close() }
            trigger.triggerGracefulShutdown()
            try await waitUntil(timeoutMilliseconds: 1_000) { await service.admission.isDraining }
            let admissionIsDraining = await service.admission.isDraining
            XCTAssertTrue(admissionIsDraining)
            do {
                try rejectedSocket.send(postRequest(boundary: boundary, body: body))
                let rejected = try parseRawHTTPResponse(rejectedSocket.receiveResponse())
                XCTAssertEqual(rejected.status, 503)
                XCTAssertEqual(rejected.errorCode, "draining")
            } catch let error as POSIXSocketError {
                let isExpectedShutdownClose: Bool
                switch error {
                case .connectionClosed:
                    isExpectedShutdownClose = true
                case .lastError("receive response"), .lastError("response separator"):
                    isExpectedShutdownClose = true
                default:
                    isExpectedShutdownClose = false
                }
                XCTAssertTrue(isExpectedShutdownClose, "unexpected pre-established socket shutdown error: \(error)")
                let stillDraining = await service.admission.isDraining
                XCTAssertTrue(stillDraining)
            }
            let uploadResponse = try await withDeadline(.seconds(3)) { try await uploadTask.value }
            XCTAssertEqual(uploadResponse.status, 200)
            try await waitUntil(timeoutMilliseconds: 1_000) { await service.admission.activeCount == 0 }
            _ = try await withDeadline(.seconds(3)) { try await runTask.value }
            let activeCount = await service.admission.activeCount
            XCTAssertEqual(activeCount, 0)
        }
    }

    func testHealthIs503WhenReadinessIsFalseAndDiagnosticFailuresAreStable() async throws {
        let notReadyService = SyrinxHTTPService(
            handler: FakeHTTPHandler(),
            readiness: ReadinessSource { false }
        )
        try await notReadyService.application().test(.live) { client in
            let health = try await client.execute(uri: "/health", method: .get)
            XCTAssertEqual(health.status, .serviceUnavailable)
            XCTAssertEqual(String(buffer: health.body), "{\"error\":{\"code\":\"not_ready\"}}")
        }

        let cases: [(TranscriptionDiagnostic, HTTPResponse.Status, String)] = [
            (TranscriptionDiagnostic(code: .inputRejected, message: "/private/input.wav"), .unprocessableContent, "input_rejected"),
            (TranscriptionDiagnostic(code: .cancelled, message: "cancelled"), .init(code: 499, reasonPhrase: "Client Closed Request"), "cancelled"),
            (TranscriptionDiagnostic(code: .deadlineExceeded, message: "deadline"), .requestTimeout, "deadline_exceeded"),
            (TranscriptionDiagnostic(code: .draining, message: "draining"), .serviceUnavailable, "draining"),
            (TranscriptionDiagnostic(code: .admissionLimitReached, message: "overloaded"), .serviceUnavailable, "overloaded"),
            (TranscriptionDiagnostic(code: .runtimeUnavailable, message: "Core ML /private/model"), .serviceUnavailable, "not_ready"),
            (TranscriptionDiagnostic(code: .transcriptionFailed, message: "Core ML private details"), .internalServerError, "inference_failed")
        ]

        for (index, testCase) in cases.enumerated() {
            let service = SyrinxHTTPService(handler: DiagnosticHTTPHandler(diagnostic: testCase.0))
            try await service.application().test(.live) { client in
                let boundary = "diagnostic-\(index)"
                let body = multipartData(
                    boundary: boundary,
                    fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")],
                    file: Data("RIFF".utf8)
                )
                var headers = HTTPFields()
                headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                let response = try await client.execute(
                    uri: "/v1/audio/transcriptions",
                    method: .post,
                    headers: headers,
                    body: ByteBuffer(bytes: body)
                )
                XCTAssertEqual(response.status, testCase.1)
                XCTAssertEqual(String(buffer: response.body), "{\"error\":{\"code\":\"\(testCase.2)\"}}")
                XCTAssertFalse(String(buffer: response.body).contains("private"))
            }
        }
    }

    func testRealLocalListenerWithFakeEngineUsesCanonicalModelAndPinnedDescriptor() async throws {
        let engine = FakeEngineSeam()
        await engine.start()
        let service = SyrinxHTTPService(
            handler: engine,
            readiness: ReadinessSource { await engine.isReady }
        )

        try await service.application().test(.live) { client in
            let health = try await client.execute(uri: "/health", method: .get)
            XCTAssertEqual(health.status, .ok)
            XCTAssertEqual(String(buffer: health.body), #"{"status":"ok"}"#)

            let boundary = "fake-engine"
            let body = multipartData(
                boundary: boundary,
                fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")],
                file: Data("RIFF-fake-engine".utf8)
            )
            var headers = HTTPFields()
            headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
            let response = try await client.execute(
                uri: "/v1/audio/transcriptions",
                method: .post,
                headers: headers,
                body: ByteBuffer(bytes: body)
            )
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(String(buffer: response.body), #"{"text":"fake engine"}"#)
        }

        let modelID = await engine.modelID
        let bytes = await engine.bytes
        XCTAssertEqual(modelID, ServiceConfiguration.defaultModelID)
        XCTAssertEqual(bytes, Data("RIFF-fake-engine".utf8))
    }

    func testCancellationErrorUsesUploadCancelledWhileTypedCancellationUsesCancelled() async throws {
        let service = SyrinxHTTPService(handler: CancellationHTTPHandler())
        try await service.application().test(.live) { client in
            let boundary = "cancelled-error"
            let body = multipartData(
                boundary: boundary,
                fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")],
                file: Data("RIFF".utf8)
            )
            var headers = HTTPFields()
            headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
            let response = try await client.execute(
                uri: "/v1/audio/transcriptions",
                method: .post,
                headers: headers,
                body: ByteBuffer(bytes: body)
            )
            XCTAssertEqual(response.status, .init(code: 499, reasonPhrase: "Client Closed Request"))
            XCTAssertEqual(String(buffer: response.body), "{\"error\":{\"code\":\"upload_cancelled\"}}")
        }
    }

    func testComposedServeUsesGracefulShutdownSignalAfterReadyHealthAndHTTPDrain() async throws {
        let events = EventRecorder()
        let engine = ComposedFakeEngine(events: events)
        let serviceBox = ServiceBox()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-composed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let command = ServeCommand(
            environment: [
                "SYRINX_PORT": "5101",
                "SYRINX_SHUTDOWN_TIMEOUT_SECONDS": "2"
            ],
            paths: StandardPaths(data: root, cache: root, logs: root),
            engineFactory: { _, _ in engine },
            serviceFactory: { configuration, handler, readiness in
                let service = SyrinxHTTPService(
                    configuration: configuration,
                    handler: handler,
                    readiness: readiness
                )
                serviceBox.set(service)
                events.append("service_constructed")
                return service
            }
        )

        try await testGracefulShutdown { trigger in
            let runTask = Task { await command.run(arguments: []) }
            defer {
                runTask.cancel()
                Task { await engine.releaseTranscription() }
            }

            let health = try await waitForReadyHealth(port: 5101)
            XCTAssertEqual(health.status, 200)
            XCTAssertEqual(health.body, Data(#"{"status":"ok"}"#.utf8))

            let boundary = "composed"
            let body = multipartData(
                boundary: boundary,
                fields: [("model", "parakeet-tdt-0.6b"), ("response_format", "json")],
                file: Data("RIFF-composed".utf8)
            )
            let uploadTask = Task {
                try await rawHTTP(
                    port: 5101,
                    request: postRequest(boundary: boundary, body: body),
                    host: "127.0.0.1"
                )
            }
            try await waitUntil(timeoutMilliseconds: 1_000) { await engine.transcriptionStarted }

            trigger.triggerGracefulShutdown()
            try await waitUntil(timeoutMilliseconds: 1_000) {
                guard let service = serviceBox.value else { return false }
                return await service.admission.isDraining
            }
            let drainCountBeforeRelease = await engine.drainCount
            XCTAssertEqual(drainCountBeforeRelease, 0)

            await engine.releaseTranscription()
            let upload = try await withDeadline(.seconds(3)) { try await uploadTask.value }
            XCTAssertEqual(upload.status, 200)
            let result = try await withDeadline(.seconds(3)) { await runTask.value }
            XCTAssertEqual(result, CommandResult(exitCode: 0))
        }

        let drainCount = await engine.drainCount
        XCTAssertEqual(drainCount, 1)
        XCTAssertEqual(events.values, [
            "engine_start", "service_constructed", "engine_handler_started", "engine_drain"
        ])
    }

    func testServeCommandComposesSecretFileAuthenticationWithoutPersistingSecret() async throws {
        let token = "composition-token"
        let root = try temporaryDirectory(named: "syrinx-serve-secret")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretURL = root.appendingPathComponent("secret")
        try ServiceFileSystem().writePrivateFileAtomically(Data(token.utf8), to: secretURL)
        chmod(secretURL.path, mode_t(0o600))
        let configuration = try ServiceConfiguration(
            port: Port(5102),
            bearerSecretFile: secretURL.path
        )
        let configurationData = try JSONEncoder().encode(ServiceConfigurationSnapshot(configuration: configuration))
        let configurationURL = root.appendingPathComponent("versioned.json")
        try ServiceFileSystem().writePrivateFileAtomically(configurationData, to: configurationURL)
        let configurationText = String(decoding: configurationData, as: UTF8.self)
        XCTAssertFalse(configurationText.contains(token))

        let engine = ComposedFakeEngine(events: EventRecorder())
        let serviceBox = ServiceBox()
        let command = ServeCommand(
            environment: ["SYRINX_CONFIG_PATH": configurationURL.path],
            paths: StandardPaths(data: root, cache: root, logs: root),
            engineFactory: { _, _ in engine },
            serviceFactory: { configuration, handler, readiness in
                let service = SyrinxHTTPService(
                    configuration: configuration,
                    handler: handler,
                    readiness: readiness
                )
                serviceBox.set(service)
                return service
            }
        )

        try await testGracefulShutdown { trigger in
            let runTask = Task { await command.run(arguments: []) }
            defer { runTask.cancel() }
            try await waitUntil(timeoutMilliseconds: 1_000) { serviceBox.value != nil }

            let unauthorized = try await withDeadline(.seconds(3)) {
                while true {
                    if let response = try? await rawHTTP(
                        port: 5102,
                        request: Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8),
                        host: "127.0.0.1"
                    ), response.status == 401 {
                        return response
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            XCTAssertEqual(unauthorized.status, 401)

            let authorizedRequest = Data(
                "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n\r\n".utf8
            )
            let authorized = try await rawHTTP(
                port: 5102,
                request: authorizedRequest,
                host: "127.0.0.1"
            )
            XCTAssertEqual(authorized.status, 200)
            XCTAssertEqual(authorized.body, Data(#"{"status":"ok"}"#.utf8))
            XCTAssertEqual(serviceBox.value?.configuration.service.bearerSecret, token)
            trigger.triggerGracefulShutdown()
            let result = try await withDeadline(.seconds(3)) { await runTask.value }
            XCTAssertEqual(result, CommandResult(exitCode: 0))
        }
    }

    func testRealCLIAndHTTPUseTheSameModelRevisionAndNormalizedText() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["SYRINX_REAL_MODEL_PATH"],
              let audioPath = ProcessInfo.processInfo.environment["SYRINX_REAL_AUDIO_PATH"],
              !modelPath.isEmpty,
              !audioPath.isEmpty
        else {
            throw XCTSkip("set SYRINX_REAL_MODEL_PATH=<root>/models/revisions/<40-lowercase-hex>/parakeet-tdt-0.6b-v3 and SYRINX_REAL_AUDIO_PATH=<wav>")
        }

        let setup = try realServeSetup(modelPath: modelPath, audioPath: audioPath)
        let executableCandidates = [
            setup.repositoryRoot.appendingPathComponent(".build/debug/syrinx"),
            setup.repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/syrinx")
        ]
        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("build the syrinx executable before running the real CLI and HTTP comparison")
        }

        let cliResult = try runRealCLI(
            executable: executable,
            homeDirectory: setup.homeDirectory,
            audioPath: setup.audioURL
        )
        XCTAssertFalse(cliResult.modelRevision.isEmpty)

        let engine = try NativeTranscriptionEngine(paths: setup.paths)
        do {
            try await engine.start()
            let directResult = try await engine.transcribe(
                TranscriptionRequest(audioFile: setup.audioURL, deadline: 3_600)
            )
            XCTAssertEqual(normalizedText(directResult.text), normalizedText(cliResult.text))
            XCTAssertEqual(directResult.modelRevision, cliResult.modelRevision)

            let uploadRoot = try temporaryDirectory(named: "syrinx-real-http")
            defer { try? FileManager.default.removeItem(at: uploadRoot) }
            let handler = RecordingNativeHandler(engine: engine)
            let service = SyrinxHTTPService(
                configuration: HTTPServiceConfiguration(
                    service: try ServiceConfiguration(
                        httpRequestTimeoutMilliseconds: DurationLimit(600_000, key: "test-http-timeout")
                    ),
                    temporaryRoot: uploadRoot
                ),
                handler: handler,
                readiness: ReadinessSource { await engine.isReady }
            )

            let audio = try Data(contentsOf: setup.audioURL)
            try await service.application().test(.live) { client in
                let boundary = "real-parrot"
                let body = multipartData(
                    boundary: boundary,
                    fields: [
                        ("model", "parakeet-tdt-0.6b-v3"),
                        ("response_format", "json")
                    ],
                    file: audio
                )
                var headers = HTTPFields()
                headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                let response = try await client.execute(
                    uri: "/v1/audio/transcriptions",
                    method: .post,
                    headers: headers,
                    body: ByteBuffer(bytes: body)
                )
                XCTAssertEqual(response.status, .ok)
                let decoded = try JSONDecoder().decode(TextResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(normalizedText(decoded.text), normalizedText(cliResult.text))
            }

            let httpResultValue = await handler.result()
            let httpResult = try XCTUnwrap(httpResultValue)
            XCTAssertEqual(httpResult.modelRevision, cliResult.modelRevision)
            XCTAssertEqual(httpResult.modelID, ServiceConfiguration.defaultModelID)
            let drain = await engine.drain(timeout: .seconds(30))
            XCTAssertEqual(drain, .completed)
        } catch {
            _ = await engine.drain(timeout: .seconds(30))
            throw error
        }
    }
}

private struct TextResponse: Decodable {
    let text: String
}

private actor RecordingNativeHandler: HTTPTranscriptionHandler {
    private let engine: NativeTranscriptionEngine
    private var lastResult: TranscriptionResult?

    init(engine: NativeTranscriptionEngine) {
        self.engine = engine
    }

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        let result = try await engine.transcribe(uploadedFile: uploadedFile, modelID: modelID)
        lastResult = result
        return result
    }

    func result() -> TranscriptionResult? {
        lastResult
    }
}

private struct RealServeSetup {
    let repositoryRoot: URL
    let homeDirectory: String
    let paths: StandardPaths
    let audioURL: URL
}

private func realServeSetup(modelPath: String, audioPath: String) throws -> RealServeSetup {
    let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true).standardizedFileURL
    let commitDirectory = modelDirectory.deletingLastPathComponent()
    let revisionsDirectory = commitDirectory.deletingLastPathComponent()
    let modelsDirectory = revisionsDirectory.deletingLastPathComponent()
    let storeRoot = modelsDirectory.deletingLastPathComponent()
    let commit = commitDirectory.lastPathComponent
    let audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL
    var isDirectory: ObjCBool = false

    guard modelDirectory.lastPathComponent == ModelManifest.supportedRepositoryFolder,
          revisionsDirectory.lastPathComponent == "revisions",
          modelsDirectory.lastPathComponent == "models",
          ModelStore.isValidImmutableCommit(commit),
          FileManager.default.fileExists(atPath: modelDirectory.path),
          FileManager.default.fileExists(atPath: audioURL.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
    else {
        throw XCTSkip("managed real-model setup required: SYRINX_REAL_MODEL_PATH=<root>/models/revisions/<40-lowercase-hex>/parakeet-tdt-0.6b-v3 SYRINX_REAL_AUDIO_PATH=<wav>")
    }

    let store = ModelStore(root: storeRoot)
    do {
        guard let installed = try store.readInstalled(),
              let selection = try store.readSelection(),
              installed.revisions.contains(where: { $0.immutableCommit == commit }),
              selection.currentRevision == commit,
              store.revisionURL(for: commit).standardizedFileURL.path == modelDirectory.path
        else {
            throw XCTSkip("managed real-model setup must select SYRINX_REAL_MODEL_PATH in installed.json and selection.json")
        }
    } catch let skip as XCTSkip {
        throw skip
    } catch {
        throw XCTSkip("managed real-model setup could not be read. Install and activate the verified revision before setting SYRINX_REAL_MODEL_PATH")
    }

    let homeURL = storeRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return RealServeSetup(
        repositoryRoot: repositoryRoot,
        homeDirectory: homeURL.path,
        paths: StandardPaths(data: storeRoot, cache: storeRoot, logs: storeRoot),
        audioURL: audioURL
    )
}

private enum RealCLIError: Error {
    case timeout
    case failed
    case invalidOutput
}

private func runRealCLI(executable: URL, homeDirectory: String, audioPath: URL) throws -> TranscriptionResult {
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["transcribe", "--json", audioPath.path]
    process.environment = ["HOME": homeDirectory]
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()

    let deadline = Date().addingTimeInterval(180)
    while process.isRunning {
        guard Date() < deadline else {
            process.terminate()
            process.waitUntilExit()
            throw RealCLIError.timeout
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    guard process.terminationStatus == 0 else {
        _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        throw RealCLIError.failed
    }
    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard let result = try? JSONDecoder().decode(TranscriptionResult.self, from: output) else {
        throw RealCLIError.invalidOutput
    }
    return result
}

private func normalizedText(_ text: String) -> String {
    text.split { $0.isWhitespace }.joined(separator: " ")
}

private actor FakeHTTPHandler: HTTPTranscriptionHandler {
    var lastModel: String?

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        lastModel = modelID
        XCTAssertTrue(uploadedFile.isClosedForHandoff)
        let bytes = try uploadedFile.withReadOnlyDescriptor { descriptor in
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
        XCTAssertFalse(bytes.isEmpty)
        return TranscriptionResult(text: "fake transcript", duration: 0, processingTime: 0, modelID: modelID)
    }

    func model() -> String? {
        lastModel
    }
}

private actor DiagnosticHTTPHandler: HTTPTranscriptionHandler {
    private let diagnostic: TranscriptionDiagnostic

    init(diagnostic: TranscriptionDiagnostic) {
        self.diagnostic = diagnostic
    }

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        throw diagnostic
    }
}

private struct CancellationHTTPHandler: HTTPTranscriptionHandler {
    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        throw CancellationError()
    }
}

private actor FakeEngineSeam: HTTPTranscriptionHandler {
    private(set) var isReady = false
    private(set) var modelID: String?
    private(set) var bytes = Data()

    func start() {
        isReady = true
    }

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        self.modelID = modelID
        bytes = try uploadedFile.withReadOnlyDescriptor { descriptor in
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 32)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            return result
        }
        return TranscriptionResult(text: "fake engine", duration: 0, processingTime: 0, modelID: modelID)
    }
}

private actor ComposedFakeEngine: ServeEngine {
    private let events: EventRecorder
    private var released = false
    private(set) var transcriptionStarted = false
    private(set) var drainCount = 0
    private(set) var isReady = false

    init(events: EventRecorder) {
        self.events = events
    }

    func start() {
        isReady = true
        events.append("engine_start")
    }

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        _ = try uploadedFile.withReadOnlyDescriptor { descriptor in
            var byte: UInt8 = 0
            _ = read(descriptor, &byte, 1)
        }
        transcriptionStarted = true
        events.append("engine_handler_started")
        while !released {
            try await Task.sleep(for: .milliseconds(5))
        }
        return TranscriptionResult(text: "composed", duration: 0, processingTime: 0, modelID: modelID)
    }

    func releaseTranscription() {
        released = true
    }

    func drain(timeout: Duration) async -> DrainResult {
        drainCount += 1
        isReady = false
        events.append("engine_drain")
        return .completed
    }
}

private final class ServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: SyrinxHTTPService?

    func set(_ service: SyrinxHTTPService) {
        lock.lock()
        storage = service
        lock.unlock()
    }

    var value: SyrinxHTTPService? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func waitForReadyHealth(port: Int) async throws -> RawHTTPResponse {
    try await withDeadline(.seconds(3)) {
        while true {
            if let response = try? await rawHTTP(
                port: port,
                request: Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8),
                host: "127.0.0.1"
            ), response.status == 200 {
                return response
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor BlockingHTTPHandler: HTTPTranscriptionHandler {
    private let delayMilliseconds: Int
    private var didStart = false

    init(delayMilliseconds: Int) {
        self.delayMilliseconds = delayMilliseconds
    }

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        didStart = true
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        return TranscriptionResult(text: "blocked", duration: 0, processingTime: 0, modelID: modelID)
    }

    func started() -> Bool {
        didStart
    }
}

private struct SlowHTTPHandler: HTTPTranscriptionHandler {
    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        try await Task.sleep(for: .milliseconds(200))
        return TranscriptionResult(text: "late", duration: 0, processingTime: 0, modelID: modelID)
    }
}

private actor ReplacingHTTPHandler: HTTPTranscriptionHandler {
    let outsideFile: URL
    var bytes = Data()
    var errorDescription: String?

    init(outsideFile: URL) {
        self.outsideFile = outsideFile
    }

    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult {
        do {
            try FileManager.default.removeItem(at: uploadedFile.url)
            try FileManager.default.createSymbolicLink(at: uploadedFile.url, withDestinationURL: outsideFile)
            bytes = try uploadedFile.withReadOnlyDescriptor { descriptor in
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 32)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count <= 0 { break }
                    result.append(buffer, count: count)
                }
                return result
            }
        } catch {
            errorDescription = String(describing: error)
            throw error
        }
        return TranscriptionResult(text: "pinned", duration: 0, processingTime: 0, modelID: modelID)
    }

    func readBytes() -> Data {
        bytes
    }

    func error() -> String? {
        errorDescription
    }
}

private actor BodyReadCounter {
    var count = 0

    func snapshot() -> Int {
        count
    }
}

private struct CountingSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let counter: BodyReadCounter

    struct AsyncIterator: AsyncIteratorProtocol {
        let counter: BodyReadCounter
        mutating func next() async throws -> ByteBuffer? {
            await counter.increment()
            return ByteBuffer(bytes: [0])
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(counter: counter)
    }
}

private func multipartBody(
    boundary: String,
    fields: [(String, String)],
    file: Data,
    fileFieldName: String = "file"
) -> [UInt8] {
    var body = Data()
    for (name, value) in fields {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(file)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return Array(body)
}

private extension BodyReadCounter {
    func increment() {
        count += 1
    }
}

private struct RawHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var errorCode: String? {
        guard let text = String(data: body, encoding: .utf8),
              let start = text.range(of: "\"code\":\"")
        else { return nil }
        let value = text[start.upperBound...]
        return String(value.prefix { $0 != "\"" })
    }
}

private final class RawSocket: @unchecked Sendable {
    private let descriptor: Int32
    private var isClosed = false

    init(port: Int, timeoutSeconds: Int = 5, host: String = "::1") throws {
        let isIPv4 = host.contains(".")
        descriptor = socket(isIPv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXSocketError.lastError("socket") }
        var timeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        else {
            Darwin.close(descriptor)
            throw POSIXSocketError.lastError("socket timeout")
        }
        let result: Int32
        if isIPv4 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                Darwin.close(descriptor)
                throw POSIXSocketError.lastError("address")
            }
            result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    Darwin.connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else {
                Darwin.close(descriptor)
                throw POSIXSocketError.lastError("address")
            }
            result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    Darwin.connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw POSIXSocketError.lastError("connect")
        }
    }

    func send(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let chunkLength = min(64 * 1024, data.count - offset)
            let result: (count: Int, error: Int32) = data.withUnsafeBytes { bytes in
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), chunkLength, 0)
                return (count, count < 0 ? errno : 0)
            }
            let sent = result.count
            if sent == 0 {
                throw POSIXSocketError.connectionClosed(bytesSent: offset, totalBytes: data.count)
            }
            guard sent > 0 else {
                if result.error == EPIPE || result.error == ECONNRESET {
                    throw POSIXSocketError.connectionClosed(bytesSent: offset, totalBytes: data.count)
                }
                throw POSIXSocketError.unexpectedSendFailure(errno: result.error, bytesSent: offset, totalBytes: data.count)
            }
            offset += sent
        }
    }

    func receiveAll() throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { return result }
            guard count > 0 else { throw POSIXSocketError.lastError("receive") }
            result.append(buffer, count: count)
        }
    }

    func receiveResponse() throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var contentLength: Int?
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { return result }
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw POSIXSocketError.lastError("receive response timeout") }
                throw POSIXSocketError.lastError("receive response")
            }
            result.append(buffer, count: count)
            if contentLength == nil,
               let separator = result.range(of: Data("\r\n\r\n".utf8)),
               let head = String(data: result[..<separator.lowerBound], encoding: .utf8)
            {
                contentLength = head.split(separator: "\r\n").dropFirst().first { $0.lowercased().hasPrefix("content-length:") }.flatMap {
                    Int($0.split(separator: ":", maxSplits: 1).dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? "")
                }
            }
            if let contentLength,
               let separator = result.range(of: Data("\r\n\r\n".utf8)),
               result.count >= separator.upperBound + contentLength
            {
                return result
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    func shutdownWrite() {
        _ = Darwin.shutdown(descriptor, SHUT_WR)
    }

    deinit { close() }
}

private enum POSIXSocketError: Error {
    case lastError(String)
    case connectionClosed(bytesSent: Int, totalBytes: Int)
    case unexpectedSendFailure(errno: Int32, bytesSent: Int, totalBytes: Int)
}

private enum RawHTTPEvent: Sendable {
    case sendFinished(Result<Void, Error>)
    case response(Result<Data, Error>)
    case deadline
}

private func rawHTTP(port: Int, request: Data, timeout: Duration = .seconds(5), host: String = "::1") async throws -> RawHTTPResponse {
    let seconds = max(1, Int(timeout.components.seconds) + 1)
    let socket = try RawSocket(port: port, timeoutSeconds: seconds, host: host)
    defer { socket.close() }
    var sendResult: Result<Void, Error>?
    var responseBytes: Data?
    var responseError: Error?
    try await withThrowingTaskGroup(of: RawHTTPEvent.self) { group in
        group.addTask {
            do {
                try socket.send(request)
                return .sendFinished(.success(()))
            } catch {
                return .sendFinished(.failure(error))
            }
        }
        group.addTask {
            do {
                return .response(.success(try socket.receiveResponse()))
            } catch {
                return .response(.failure(error))
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return .deadline
        }
        while let event = try await group.next() {
            switch event {
            case .sendFinished(let result): sendResult = result
            case .response(let result):
                switch result {
                case .success(let bytes):
                    responseBytes = bytes
                    if let response = try? parseRawHTTPResponse(bytes),
                       response.status == 413,
                       response.errorCode == "upload_too_large"
                    {
                        socket.shutdownWrite()
                    }
                case .failure(let error): responseError = error
            }
            case .deadline:
                socket.close()
                group.cancelAll()
                throw POSIXSocketError.lastError("deadline")
            }
            if sendResult != nil && (responseBytes != nil || responseError != nil) {
                group.cancelAll()
                break
            }
        }
    }
    guard let bytes = responseBytes, !bytes.isEmpty else {
        if let responseError { throw responseError }
        throw POSIXSocketError.lastError("no response")
    }
    let response = try parseRawHTTPResponse(bytes)
    if let sendResult {
        do {
            try sendResult.get()
        } catch let error as POSIXSocketError {
            guard case .connectionClosed = error,
                  response.status == 413,
                  response.errorCode == "upload_too_large"
            else { throw error }
        }
    }
    return response
}

private func parseRawHTTPResponse(_ bytes: Data) throws -> RawHTTPResponse {
    guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
        throw POSIXSocketError.lastError("response separator")
    }
    let head = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
    let body = Data(bytes[separator.upperBound...])
    let lines = head.split(separator: "\r\n")
    guard let status = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
        throw POSIXSocketError.lastError("status line")
    }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    if let contentLength = headers["content-length"].flatMap(Int.init) {
        guard body.count >= contentLength else {
            throw POSIXSocketError.lastError("incomplete response body")
        }
    }
    return RawHTTPResponse(status: status, headers: headers, body: body)
}

private func postRequest(boundary: String, body: Data) -> Data {
    Data(postRequestPrefix(boundary: boundary, length: body.count).utf8) + body
}

private func postRequestPrefix(boundary: String, length: Int) -> String {
    "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: multipart/form-data; boundary=\(boundary)\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
}

private func multipartData(boundary: String, fields: [(String, String)], file: Data) -> Data {
    Data(multipartBody(boundary: boundary, fields: fields, file: file))
}

private func waitUntil(timeoutMilliseconds: Int, condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while true {
        if await condition() { return }
        guard ContinuousClock.now < deadline else { throw POSIXSocketError.lastError("wait") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func withDeadline<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw POSIXSocketError.lastError("deadline")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
