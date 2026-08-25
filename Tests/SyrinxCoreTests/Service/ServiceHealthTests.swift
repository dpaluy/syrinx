import Foundation
import XCTest
@testable import SyrinxCore

final class ServiceHealthTests: XCTestCase {
    func testProductionProbeSendsExactBearerHeaderAndRejectsMissingOrWrongValues() async throws {
        let seen = HeaderCapture()
        let probe = URLServiceHealthProbe { request in
            let value = request.value(forHTTPHeaderField: "Authorization")
            seen.append(value)
            let status = value == "Bearer correct-token" ? 200 : 401
            let body = Data("{\"status\":\"ok\"}".utf8)
            return (body, status)
        }

        let ready = await probe.waitUntilReady(
            port: 5092,
            authorization: "correct-token",
            timeout: .milliseconds(100)
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(seen.values.last ?? nil, "Bearer correct-token")

        let missing = await probe.waitUntilReady(
            port: 5092,
            authorization: nil,
            timeout: .milliseconds(20)
        )
        XCTAssertEqual(missing.state, .timedOut)

        let wrong = await probe.waitUntilReady(
            port: 5092,
            authorization: "wrong-token",
            timeout: .milliseconds(20)
        )
        XCTAssertEqual(wrong.state, .timedOut)
        XCTAssertEqual(seen.values.dropFirst().first ?? "unexpected", nil)
        XCTAssertEqual(seen.values.last ?? "unexpected", "Bearer wrong-token")
    }

    func testProductionProbeCancellationIsFiniteAndDoesNotExposeTokenInDetail() async throws {
        let probe = URLServiceHealthProbe { _ in
            try await Task.sleep(for: .seconds(5))
            return (Data("{\"status\":\"ok\"}".utf8), 200)
        }
        let task = Task {
            await probe.waitUntilReady(
                port: 5092,
                authorization: "secret-token",
                timeout: .seconds(5)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.state, .timedOut)
        XCTAssertFalse(result.detail.contains("secret-token"))
    }
}

private final class HeaderCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: String?) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}
