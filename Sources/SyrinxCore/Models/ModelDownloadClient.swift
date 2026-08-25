import Foundation

public struct ModelDownloadRequest: Sendable, Equatable {
    public let url: String
    public let expectedURL: String
    public let rangeStart: Int64?
    public let timeout: TimeInterval

    public init(url: String, expectedURL: String, rangeStart: Int64?, timeout: TimeInterval) {
        self.url = url
        self.expectedURL = expectedURL
        self.rangeStart = rangeStart
        self.timeout = timeout
    }
}

public struct ModelDownloadBodyMetrics: Sendable, Equatable {
    public let queuedChunks: Int
    public let queuedBytes: Int
    public let maximumQueuedChunks: Int
    public let maximumQueuedBytes: Int
    public let producerFinished: Bool
    public let producerCancelled: Bool

    internal init(
        queuedChunks: Int,
        queuedBytes: Int,
        maximumQueuedChunks: Int,
        maximumQueuedBytes: Int,
        producerFinished: Bool,
        producerCancelled: Bool
    ) {
        self.queuedChunks = queuedChunks
        self.queuedBytes = queuedBytes
        self.maximumQueuedChunks = maximumQueuedChunks
        self.maximumQueuedBytes = maximumQueuedBytes
        self.producerFinished = producerFinished
        self.producerCancelled = producerCancelled
    }
}

private actor BoundedDownloadBodyState {
    private struct ProducerWaiter {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumQueuedChunks: Int
    private let maximumQueuedBytes: Int
    private var queue: [Data] = []
    private var queueBytes = 0
    private var producerWaiter: ProducerWaiter?
    private var finished = false
    private var cancelled = false
    private var failure: Error?
    private var maximumObservedChunks = 0
    private var maximumObservedBytes = 0
    private var producerFinished = false
    private var producerCancelled = false

    init(maximumQueuedChunks: Int, maximumQueuedBytes: Int) {
        self.maximumQueuedChunks = maximumQueuedChunks
        self.maximumQueuedBytes = maximumQueuedBytes
    }

    func next() async throws -> Data? {
        if !queue.isEmpty {
            let value = queue.removeFirst()
            queueBytes -= value.count
            drainProducerWaiters()
            return value
        }
        if let waiter = producerWaiter {
            producerWaiter = nil
            waiter.continuation.resume()
            return waiter.data
        }
        if let failure {
            throw failure
        }
        if finished || cancelled {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The body permits one consumer. The installer and URLSession use this
            // contract, which keeps ordering and back-pressure deterministic.
            consumerContinuation = continuation
        }
    }

    func push(_ value: Data) async throws {
        guard !value.isEmpty else { return }
        guard value.count <= maximumQueuedBytes else {
            throw ModelDownloadBodyError.chunkExceedsCapacity
        }
        try checkOpen()

        if let consumerContinuation {
            self.consumerContinuation = nil
            consumerContinuation.resume(returning: value)
            return
        }

        let queueCapacity = max(0, maximumQueuedChunks - 1)
        if queue.count < queueCapacity,
           queueBytes + value.count <= maximumQueuedBytes {
            queue.append(value)
            queueBytes += value.count
            recordMaximums()
            return
        }
        guard queueBytes + value.count <= maximumQueuedBytes else {
            throw ModelDownloadBodyError.chunkDoesNotFitAvailableCapacity
        }
        guard queue.count < maximumQueuedChunks else {
            throw ModelDownloadBodyError.chunkDoesNotFitAvailableCapacity
        }
        guard producerWaiter == nil else {
            throw ModelDownloadBodyError.multipleProducers
        }
        try await withCheckedThrowingContinuation { continuation in
            producerWaiter = ProducerWaiter(data: value, continuation: continuation)
            recordMaximums()
        }
        try checkOpen()
    }

    func finish(error: Error? = nil) {
        guard !cancelled else { return }
        finished = true
        failure = error
        if queue.isEmpty, let consumerContinuation {
            self.consumerContinuation = nil
            if let error {
                consumerContinuation.resume(throwing: error)
            } else {
                consumerContinuation.resume(returning: nil)
            }
        }
        if let waiter = producerWaiter {
            producerWaiter = nil
            waiter.continuation.resume(throwing: error ?? CancellationError())
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        queue.removeAll()
        queueBytes = 0
        if let waiter = producerWaiter {
            producerWaiter = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
        if let consumerContinuation {
            self.consumerContinuation = nil
            consumerContinuation.resume(throwing: CancellationError())
        }
    }

    func markProducerFinished(cancelled: Bool) {
        producerFinished = true
        producerCancelled = cancelled
    }

    func metrics() -> ModelDownloadBodyMetrics {
        ModelDownloadBodyMetrics(
            queuedChunks: queue.count + (producerWaiter == nil ? 0 : 1),
            queuedBytes: queueBytes + (producerWaiter?.data.count ?? 0),
            maximumQueuedChunks: maximumObservedChunks,
            maximumQueuedBytes: maximumObservedBytes,
            producerFinished: producerFinished,
            producerCancelled: producerCancelled
        )
    }

    private var consumerContinuation: CheckedContinuation<Data?, Error>?

    private func checkOpen() throws {
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
        if finished { throw CancellationError() }
    }

    private func drainProducerWaiters() {
        guard !cancelled, let waiter = producerWaiter else { return }
        guard queue.count < max(0, maximumQueuedChunks - 1) else { return }
        producerWaiter = nil
        queue.append(waiter.data)
        queueBytes += waiter.data.count
        recordMaximums()
        waiter.continuation.resume()
    }

    private func recordMaximums() {
        let chunks = queue.count + (producerWaiter == nil ? 0 : 1)
        let bytes = queueBytes + (producerWaiter?.data.count ?? 0)
        maximumObservedChunks = max(maximumObservedChunks, chunks)
        maximumObservedBytes = max(maximumObservedBytes, bytes)
    }
}

private enum ModelDownloadBodyError: Error {
    case chunkExceedsCapacity
    case chunkDoesNotFitAvailableCapacity
    case multipleProducers
}

public struct ModelDownloadBodySink: Sendable {
    private let state: BoundedDownloadBodyState

    fileprivate init(state: BoundedDownloadBodyState) {
        self.state = state
    }

    public func push(_ value: Data) async throws {
        try await state.push(value)
    }
}

public final class ModelDownloadBody: AsyncSequence, @unchecked Sendable {
    public typealias Element = Data

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let body: ModelDownloadBody
        private let terminationToken: TerminationToken

        fileprivate init(body: ModelDownloadBody) {
            self.body = body
            self.terminationToken = TerminationToken(body: body)
        }

        public mutating func next() async throws -> Data? {
            try await body.nextChunk()
        }
    }

    private final class TerminationToken {
        private let body: ModelDownloadBody

        init(body: ModelDownloadBody) {
            self.body = body
        }

        deinit {
            body.cancel()
        }
    }

    private let state: BoundedDownloadBodyState
    private var producerTask: Task<Void, Never>?

    internal init(
        maximumQueuedChunks: Int = 4,
        maximumQueuedBytes: Int = 256 * 1024,
        producer: @escaping @Sendable (ModelDownloadBodySink) async throws -> Void
    ) {
        precondition(maximumQueuedChunks > 0)
        precondition(maximumQueuedBytes > 0)
        let state = BoundedDownloadBodyState(
            maximumQueuedChunks: maximumQueuedChunks,
            maximumQueuedBytes: maximumQueuedBytes
        )
        self.state = state
        self.producerTask = nil
        let sink = ModelDownloadBodySink(state: state)
        self.producerTask = Task { [state] in
            var wasCancelled = false
            do {
                try await producer(sink)
                wasCancelled = Task.isCancelled
                await state.finish()
            } catch {
                wasCancelled = Task.isCancelled
                await state.finish(error: error)
            }
            await state.markProducerFinished(cancelled: wasCancelled)
        }
    }

    deinit {
        producerTask?.cancel()
        let state = state
        Task { await state.cancel() }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(body: self)
    }

    public func cancel() {
        producerTask?.cancel()
        let state = state
        Task { await state.cancel() }
    }

    private func nextChunk() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await state.next()
        } onCancel: {
            cancel()
        }
    }

    internal func metrics() async -> ModelDownloadBodyMetrics {
        await state.metrics()
    }

    internal func waitForProducerTermination() async {
        await producerTask?.value
    }
}

public struct ModelDownloadResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: ModelDownloadBody

    public init(statusCode: Int, headers: [String: String], body: ModelDownloadBody) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol ModelDownloadClient: Sendable {
    func response(for request: ModelDownloadRequest) async throws -> ModelDownloadResponse
}

public enum ModelDownloadClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidHTTPSURL
    case URLMismatch
    case transport(String)

    public var description: String {
        switch self {
        case .invalidHTTPSURL:
            return "model download URL must use HTTPS"
        case .URLMismatch:
            return "model download URL does not match the validated manifest"
        case let .transport(detail):
            return "model download transport failed: \(detail)"
        }
    }
}

public struct URLSessionModelDownloadClient: ModelDownloadClient {
    private let session: URLSession
    private let allowHTTPForTesting: Bool

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.init(configuration: configuration, allowHTTPForTesting: false)
    }

    internal init(configuration: URLSessionConfiguration, allowHTTPForTesting: Bool) {
        let configuration = configuration
        configuration.timeoutIntervalForRequest = max(configuration.timeoutIntervalForRequest, 1)
        configuration.timeoutIntervalForResource = max(configuration.timeoutIntervalForResource, 1)
        session = URLSession(configuration: configuration)
        self.allowHTTPForTesting = allowHTTPForTesting
    }

    public func response(for request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        guard request.url == request.expectedURL else {
            throw ModelDownloadClientError.URLMismatch
        }
        guard let url = URL(string: request.url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (components.scheme?.lowercased() == "https" || (allowHTTPForTesting && components.scheme?.lowercased() == "http")),
              components.host != nil,
              url.absoluteString == request.url
        else {
            throw ModelDownloadClientError.invalidHTTPSURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = request.timeout
        if let rangeStart = request.rangeStart {
            urlRequest.setValue("bytes=\(rangeStart)-", forHTTPHeaderField: "Range")
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let body = ModelDownloadBody { sink in
            var chunk = Data()
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    try await sink.push(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                try await sink.push(chunk)
            }
        }
        return ModelDownloadResponse(
            statusCode: http.statusCode,
            headers: http.allHeaderFields.reduce(into: [String: String]()) { result, item in
                result[String(describing: item.key).lowercased()] = String(describing: item.value)
            },
            body: body
        )
    }
}
