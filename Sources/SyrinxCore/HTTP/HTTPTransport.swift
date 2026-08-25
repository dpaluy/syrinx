import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import NIOCore
import NIOHTTPTypes
import ServiceLifecycle

public protocol HTTPTranscriptionHandler: Sendable {
    func transcribe(uploadedFile: UploadedFile, modelID: String) async throws -> TranscriptionResult
}

public struct ReadinessSource: Sendable {
    private let check: @Sendable () async -> Bool

    public init(check: @escaping @Sendable () async -> Bool) {
        self.check = check
    }

    public func isReady() async -> Bool {
        await check()
    }
}

public actor HTTPAdmission {
    private let maximum: Int
    private var active = 0
    private var draining = false

    public init(maximum: Int) {
        self.maximum = max(1, maximum)
    }

    public func admit() -> Bool {
        guard !draining, active < maximum else { return false }
        active += 1
        return true
    }

    public func release() {
        active = max(0, active - 1)
    }

    public func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T? {
        guard !draining, active < maximum else { return nil }
        active += 1
        defer { active = max(0, active - 1) }
        return try await operation()
    }

    public func beginDrain() {
        draining = true
    }

    public var isDraining: Bool {
        draining
    }

    public var activeCount: Int {
        active
    }

    public func waitForZero(timeoutMilliseconds: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while active > 0 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return active == 0
    }
}

private final class HTTPDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var draining = false

    func begin() {
        lock.lock()
        draining = true
        lock.unlock()
    }

    var isDraining: Bool {
        lock.lock()
        defer { lock.unlock() }
        return draining
    }
}

private enum HTTPShutdownSignal: Sendable, Equatable {
    case requested
    case applicationEnded
}

private final class HTTPShutdownCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var signal: HTTPShutdownSignal?
    private var waiter: CheckedContinuation<HTTPShutdownSignal, Never>?

    func signal(_ value: HTTPShutdownSignal) {
        lock.lock()
        guard signal == nil || signal == .applicationEnded else {
            lock.unlock()
            return
        }
        signal = value
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func wait() async -> HTTPShutdownSignal {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let signal {
                lock.unlock()
                continuation.resume(returning: signal)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

public struct HTTPServiceConfiguration: Sendable {
    public let service: ServiceConfiguration
    public let temporaryRoot: URL
    public let multipartLimits: MultipartLimits

    public init(
        service: ServiceConfiguration = .init(),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        multipartLimits: MultipartLimits? = nil
    ) {
        self.service = service
        self.temporaryRoot = temporaryRoot
        self.multipartLimits = multipartLimits ?? MultipartLimits(
            envelopeBytes: service.maxEnvelopeBytes.value,
            fileBytes: service.maxUploadBytes.value
        )
    }
}

public struct SyrinxHTTPService: Sendable {
    public let configuration: HTTPServiceConfiguration
    public let handler: any HTTPTranscriptionHandler
    public let readiness: ReadinessSource
    public let admission: HTTPAdmission
    private let drainGate: HTTPDrainGate

    public init(
        configuration: HTTPServiceConfiguration = .init(),
        handler: any HTTPTranscriptionHandler,
        readiness: ReadinessSource = .init { true }
    ) {
        self.configuration = configuration
        self.handler = handler
        self.readiness = readiness
        self.admission = HTTPAdmission(maximum: configuration.service.maxJobs.value)
        self.drainGate = HTTPDrainGate()
    }

    public func router() -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        router.get("/health") { [self] request, _ in
            await healthResponse(request)
        }
        router.get("/v1/models") { [self] request, _ in
            modelsResponse(request)
        }
        router.post("/v1/audio/transcriptions") { [self] request, _ in
            await transcriptionResponse(request)
        }
        return router
    }

    public func application() -> Application<RouterResponder<BasicRequestContext>> {
        var http1 = HTTP1Channel.Configuration(
            idleTimeout: .milliseconds(Int64(configuration.service.httpIdleTimeoutMilliseconds.value)),
            httpDecoderConfiguration: .init(
                maxHeaderFieldSize: configuration.service.httpHeaderFieldBytes.value,
                maxHeaderListSize: configuration.service.httpHeaderListBytes.value,
                maxHeaderFieldCount: configuration.service.httpHeaderFieldCount.value
            )
        )
        // Hummingbird exposes HTTP/1 decoder limits and idle timeout as the
        // public slow-reader controls for this release.
        http1.httpDecoder.maxHeaderFieldSize = configuration.service.httpHeaderFieldBytes.value
        return Application(
            router: router(),
            server: .http1(configuration: http1),
            configuration: .init(
                address: .hostname(configuration.service.host.value, port: configuration.service.port.value),
                serverName: nil,
                backlog: 64,
                reuseAddress: true
            )
        )
    }

    public func run() async throws {
        let app = application()
        let admission = admission
        let drainGate = drainGate
        let coordinator = HTTPShutdownCoordinator()
        try await withThrowingTaskGroup(of: LifecycleResult.self) { group in
            group.addTask {
                try await withGracefulShutdownHandler {
                    try await app.runService()
                } onGracefulShutdown: {
                    drainGate.begin()
                    coordinator.signal(.requested)
                }
                coordinator.signal(.applicationEnded)
                return .applicationEnded
            }
            group.addTask {
                guard await coordinator.wait() == .requested else {
                    return .drained
                }
                await admission.beginDrain()
                guard await admission.waitForZero(
                    timeoutMilliseconds: configuration.service.shutdownTimeoutSeconds.value * 1_000
                ) else {
                    throw HTTPTransportError.shutdownTimeout
                }
                return .drained
            }

            var applicationEnded = false
            var drained = false
            while !applicationEnded || !drained {
                guard let result = try await group.next() else { break }
                switch result {
                case .applicationEnded:
                    applicationEnded = true
                case .drained:
                    drained = true
                }
            }
        }
    }

    public func beginDrain() async {
        drainGate.begin()
        await admission.beginDrain()
    }

    public func waitForHTTPDrain() async -> Bool {
        await admission.waitForZero(
            timeoutMilliseconds: configuration.service.shutdownTimeoutSeconds.value * 1_000
        )
    }

    private enum LifecycleResult: Sendable {
        case applicationEnded
        case drained
    }

    private func healthResponse(_ request: Request) async -> Response {
        guard authenticate(request.headers[.authorization]) else {
            return errorResponse(.unauthorized)
        }
        let admissionIsDraining = await admission.isDraining
        if drainGate.isDraining || admissionIsDraining {
            return errorResponse(.notReady)
        }
        if await readiness.isReady() {
            return jsonResponse(status: .ok, data: Data(#"{"status":"ok"}"#.utf8))
        }
        return errorResponse(.notReady)
    }

    private func modelsResponse(_ request: Request) -> Response {
        guard authenticate(request.headers[.authorization]) else {
            return errorResponse(.unauthorized)
        }
        let data = Data(#"{"data":[{"id":"parakeet-tdt-0.6b-v3","object":"model","owned_by":"Syrinx"},{"id":"parakeet-tdt-0.6b","object":"model","owned_by":"Syrinx"}],"object":"list"}"#.utf8)
        return jsonResponse(status: .ok, data: data)
    }

    private func transcriptionResponse(_ request: Request) async -> Response {
        guard request.method == .post else {
            return errorResponse(.unsupportedField)
        }
        guard authenticate(request.headers[.authorization]) else {
            return errorResponse(.unauthorized)
        }
        guard !drainGate.isDraining, !(await admission.isDraining) else {
            return errorResponse(.draining)
        }
        do {
            try validateContentLength(request.headers[values: .contentLength])
        } catch let error as HTTPTransportError {
            return errorResponse(error.code)
        } catch {
            return errorResponse(.malformedRequest)
        }
        guard !drainGate.isDraining else {
            return errorResponse(.draining)
        }
        let response: Response
        do {
            guard let result = try await admission.withPermit({ [self] in
                try await self.transcribeWithDeadline(request)
            }) else {
                return errorResponse((await admission.isDraining) ? .draining : .overloaded)
            }
            let encoder = JSONEncoder()
            let data = try encoder.encode(["text": result.text])
            response = jsonResponse(status: .ok, data: data)
        } catch let error as HTTPTransportError {
            response = errorResponse(error.code)
        } catch is CancellationError {
            response = errorResponse(.uploadCancelled)
        } catch let diagnostic as TranscriptionDiagnostic {
            response = errorResponse(diagnostic.errorCode)
        } catch let error as MultipartUploadError {
            response = errorResponse(error.errorCode)
        } catch {
            response = errorResponse(.uploadFailed)
        }
        return response
    }

    private func parseAndTranscribe(request: Request, body: RequestBody) async throws -> TranscriptionResult {
        guard let contentType = request.headers[.contentType] else {
            throw MultipartUploadError.unsupportedMultipart
        }
        let boundary = try parseMultipartBoundary(contentType, maximum: MultipartLimits.default.boundaryBytes)
        var parser = try MultipartUploadParser(
            boundary: boundary,
            temporaryRoot: configuration.temporaryRoot,
            limits: configuration.multipartLimits
        )
        do {
            for try await buffer in body {
                try parser.consume(buffer.readableBytesView)
            }
            let upload = try parser.finish()
            do {
                let model = try validateFields(upload.fields)
                defer { upload.cleanup() }
                return try await handler.transcribe(uploadedFile: upload.file, modelID: model)
            } catch {
                upload.cleanup()
                throw error
            }
        } catch {
            parser.cleanup()
            throw error
        }
    }

    private func transcribeWithDeadline(_ request: Request) async throws -> TranscriptionResult {
        try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            group.addTask { [self] in
                try await request.body.consumeWithCancellationOnInboundClose { body in
                    try await parseAndTranscribe(request: request, body: body)
                }
            }
            group.addTask {
                try await Task.sleep(
                    for: .milliseconds(Int64(configuration.service.httpRequestTimeoutMilliseconds.value))
                )
                throw HTTPTransportError.requestTimeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HTTPTransportError.requestTimeout
            }
            return result
        }
    }

    private func validateContentLength(_ values: [String]) throws {
        guard values.count <= 1 else {
            throw HTTPTransportError.malformedRequest
        }
        guard let value = values.first else { return }
        guard !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            throw HTTPTransportError.malformedRequest
        }
        guard let length = Int64(value), length >= 0 else {
            throw HTTPTransportError.malformedRequest
        }
        if length > Int64(configuration.multipartLimits.envelopeBytes) {
            throw HTTPTransportError.uploadTooLarge
        }
    }

    private func validateFields(_ fields: [String: [String]]) throws -> String {
        let allowed = Set(["model", "response_format"])
        guard fields.keys.allSatisfy({ allowed.contains($0) }) else {
            throw HTTPTransportError.unsupportedField
        }
        for values in fields.values where values.count != 1 {
            throw HTTPTransportError.unsupportedField
        }
        guard let model = fields["model"]?.first else {
            throw HTTPTransportError.unsupportedModel
        }
        let canonical: String
        switch model {
        case "parakeet-tdt-0.6b", configuration.service.modelID.value:
            canonical = configuration.service.modelID.value
        default:
            throw HTTPTransportError.unsupportedModel
        }
        guard fields["response_format"]?.first == "json" else {
            throw HTTPTransportError.unsupportedFormat
        }
        return canonical
    }

    private func authenticate(_ header: String?) -> Bool {
        guard let secret = configuration.service.bearerSecret else { return true }
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let candidate = String(header.dropFirst(7))
        guard !candidate.isEmpty else { return false }
        let left = Array(candidate.utf8)
        let right = Array(secret.utf8)
        var difference = UInt64(left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            difference |= UInt64(lhs ^ rhs)
        }
        return difference == 0
    }

    private func jsonResponse(status: HTTPResponse.Status, data: Data) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("Cache-Control")!] = "no-store"
        headers[HTTPField.Name("X-Request-ID")!] = String(UUID().uuidString.prefix(64))
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func errorResponse(_ error: HTTPTransportError.Code) -> Response {
        let status = error.status
        let data = Data("{\"error\":{\"code\":\"\(error.rawValue)\"}}".utf8)
        return jsonResponse(status: status, data: data)
    }
}

public enum HTTPTransportError: Error, Sendable {
    case uploadTooLarge
    case malformedRequest
    case unsupportedField
    case unsupportedModel
    case unsupportedFormat
    case requestTimeout
    case shutdownTimeout

    public enum Code: String, Sendable {
        case malformedMultipart = "malformed_multipart"
        case truncatedMultipart = "truncated_multipart"
        case unsupportedMultipart = "unsupported_multipart"
        case uploadTooLarge = "upload_too_large"
        case unauthorized
        case uploadCancelled = "upload_cancelled"
        case cancelled
        case inputRejected = "input_rejected"
        case deadlineExceeded = "deadline_exceeded"
        case draining
        case overloaded
        case uploadFailed = "upload_failed"
        case inferenceFailed = "inference_failed"
        case unsupportedField = "unsupported_field"
        case unsupportedModel = "unsupported_model"
        case unsupportedFormat = "unsupported_format"
        case notReady = "not_ready"
        case requestTimeout = "request_timeout"
        case malformedRequest = "malformed_request"

        var status: HTTPResponse.Status {
            switch self {
            case .malformedMultipart, .truncatedMultipart: return .badRequest
            case .unsupportedMultipart, .unsupportedField, .unsupportedModel, .unsupportedFormat: return .unprocessableContent
            case .uploadTooLarge: return .contentTooLarge
            case .unauthorized: return .unauthorized
            case .uploadCancelled, .cancelled: return .init(code: 499, reasonPhrase: "Client Closed Request")
            case .inputRejected: return .unprocessableContent
            case .deadlineExceeded: return .requestTimeout
            case .draining, .notReady: return .serviceUnavailable
            case .overloaded: return .serviceUnavailable
            case .requestTimeout: return .requestTimeout
            case .malformedRequest: return .badRequest
            case .uploadFailed, .inferenceFailed: return .internalServerError
            }
        }
    }

    var code: Code {
        switch self {
        case .unsupportedField: return .unsupportedField
        case .unsupportedModel: return .unsupportedModel
        case .unsupportedFormat: return .unsupportedFormat
        case .requestTimeout: return .requestTimeout
        case .shutdownTimeout: return .uploadFailed
        case .malformedRequest: return .malformedRequest
        case .uploadTooLarge: return .uploadTooLarge
        }
    }
}

private extension MultipartUploadError {
    var errorCode: HTTPTransportError.Code {
        switch self {
        case .malformedMultipart: return .malformedMultipart
        case .truncatedMultipart: return .truncatedMultipart
        case .unsupportedMultipart: return .unsupportedMultipart
        case .uploadTooLarge: return .uploadTooLarge
        case .uploadFailed: return .uploadFailed
        }
    }
}

private extension TranscriptionDiagnostic {
    var errorCode: HTTPTransportError.Code {
        switch code {
        case .inputRejected:
            return .inputRejected
        case .cancelled:
            return .cancelled
        case .deadlineExceeded:
            return .deadlineExceeded
        case .draining:
            return .draining
        case .admissionLimitReached:
            return .overloaded
        case .runtimeUnavailable, .modelLoadFailed, .modelMissing, .readinessProbeFailed,
             .configurationConflict, .drainTimeout:
            return .notReady
        case .transcriptionFailed:
            return .inferenceFailed
        case .invalidDeadline:
            return .malformedRequest
        }
    }
}
