import Foundation
import XCTest
@testable import SyrinxCore

final class ModelDownloadClientTests: XCTestCase {
    func testBoundedBodyDoesNotExceedDeclaredQueueCapacity() async throws {
        let body = ModelDownloadBody(maximumQueuedChunks: 2, maximumQueuedBytes: 8) { sink in
            for _ in 0..<20 {
                try await sink.push(Data(repeating: 1, count: 4))
            }
        }

        var consumed = 0
        for try await chunk in body {
            consumed += chunk.count
            try await Task.sleep(for: .milliseconds(2))
        }

        let metrics = await body.metrics()
        XCTAssertEqual(consumed, 80)
        XCTAssertLessThanOrEqual(metrics.maximumQueuedChunks, 2)
        XCTAssertLessThanOrEqual(metrics.maximumQueuedBytes, 8)
        XCTAssertTrue(metrics.producerFinished)
    }

    func testStoppingConsumerCancelsAndTerminatesProducer() async throws {
        let body = ModelDownloadBody(maximumQueuedChunks: 1, maximumQueuedBytes: 4) { sink in
            while true {
                try await sink.push(Data(repeating: 1, count: 4))
            }
        }

        var iterator = body.makeAsyncIterator()
        _ = try await iterator.next()
        body.cancel()

        for _ in 0..<100 {
            if (await body.metrics()).producerFinished { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let metrics = await body.metrics()
        XCTAssertTrue(metrics.producerFinished)
        XCTAssertTrue(metrics.producerCancelled)
    }

    func testUnevenChunksNeverExceedByteBoundAndFailWithoutDroppingEarlierChunks() async throws {
        let body = ModelDownloadBody(maximumQueuedChunks: 3, maximumQueuedBytes: 10) { sink in
            try await sink.push(Data(repeating: 1, count: 6))
            try await sink.push(Data(repeating: 2, count: 3))
            try await sink.push(Data(repeating: 3, count: 2))
        }
        try await Task.sleep(for: .milliseconds(10))

        var consumed = 0
        do {
            for try await chunk in body {
                consumed += chunk.count
            }
            XCTFail("expected the third chunk to exceed the retained byte capacity")
        } catch {
            XCTAssertEqual(consumed, 9)
        }

        let metrics = await body.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumQueuedChunks, 3)
        XCTAssertLessThanOrEqual(metrics.maximumQueuedBytes, 10)
        XCTAssertTrue(metrics.producerFinished)
    }

    func testDestroyingBackpressuredBodyTerminatesProducerWithoutPolling() async throws {
        let probe = TerminationProbe()
        var body: ModelDownloadBody? = ModelDownloadBody(maximumQueuedChunks: 1, maximumQueuedBytes: 4) { sink in
            do {
                while true {
                    try await sink.push(Data(repeating: 1, count: 4))
                }
            } catch {
                await probe.markTerminated()
                throw error
            }
        }

        do {
            var iterator = body!.makeAsyncIterator()
            _ = try await iterator.next()
        }
        body = nil

        await probe.waitForTermination()
    }

    func testProductionClientRejectsNonHTTPSAndURLMismatchBeforeRequest() async throws {
        let client = URLSessionModelDownloadClient()
        let request = ModelDownloadRequest(url: "http://example.invalid/file", expectedURL: "http://example.invalid/file", rangeStart: nil, timeout: 1)
        do {
            _ = try await client.response(for: request)
            XCTFail("expected HTTPS rejection")
        } catch let error as ModelDownloadClientError {
            XCTAssertEqual(error, .invalidHTTPSURL)
        }

        let mismatch = ModelDownloadRequest(url: "https://example.invalid/one", expectedURL: "https://example.invalid/two", rangeStart: nil, timeout: 1)
        do {
            _ = try await client.response(for: mismatch)
            XCTFail("expected URL mismatch")
        } catch let error as ModelDownloadClientError {
            XCTAssertEqual(error, .URLMismatch)
        }
    }
}

private actor TerminationProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private var terminated = false

    func markTerminated() {
        terminated = true
        continuation?.resume()
        continuation = nil
    }

    func waitForTermination() async {
        if terminated { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
