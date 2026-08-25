import Foundation

public enum ServiceHealthState: String, Sendable {
    case ready
    case unhealthy
    case timedOut = "timed_out"
}

public struct ServiceHealthResult: Equatable, Sendable {
    public let state: ServiceHealthState
    public let detail: String

    public init(state: ServiceHealthState, detail: String = "") {
        self.state = state
        self.detail = detail
    }
}

public protocol ServiceHealthProbe: Sendable {
    func waitUntilReady(port: Int, timeout: Duration) async -> ServiceHealthResult
    func waitUntilReady(
        port: Int,
        authorization: String?,
        timeout: Duration
    ) async -> ServiceHealthResult
}

extension ServiceHealthProbe {
    public func waitUntilReady(
        port: Int,
        authorization: String?,
        timeout: Duration
    ) async -> ServiceHealthResult {
        await waitUntilReady(port: port, timeout: timeout)
    }
}

public struct URLServiceHealthProbe: ServiceHealthProbe {
    private let transport: @Sendable (URLRequest) async throws -> (Data, Int)

    public init() {
        transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, response.statusCode)
        }
    }

    init(
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, Int)
    ) {
        self.transport = transport
    }

    public func waitUntilReady(port: Int, timeout: Duration) async -> ServiceHealthResult {
        await waitUntilReady(port: port, authorization: nil, timeout: timeout)
    }

    public func waitUntilReady(
        port: Int,
        authorization: String?,
        timeout: Duration
    ) async -> ServiceHealthResult {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Task.isCancelled {
                return ServiceHealthResult(state: .timedOut, detail: "cancelled")
            }
            if await isReady(port: port, authorization: authorization) {
                return ServiceHealthResult(state: .ready, detail: "health check passed")
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return ServiceHealthResult(state: .timedOut, detail: "cancelled")
            }
        }
        return ServiceHealthResult(state: .timedOut, detail: "health check timed out")
    }

    private func isReady(port: Int, authorization: String?) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, statusCode) = try await transport(request)
            guard statusCode == 200 else {
                return false
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["status"] as? String == "ok"
        } catch {
            return false
        }
    }
}

struct ClosureServiceHealthProbe: ServiceHealthProbe {
    let closure: @Sendable (Int, Duration) async -> ServiceHealthResult

    func waitUntilReady(port: Int, timeout: Duration) async -> ServiceHealthResult {
        await closure(port, timeout)
    }
}
