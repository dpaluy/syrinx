import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ModelInstallerIntegrationTests: XCTestCase {
    func testLoopbackServerStreamsFreshAndResumeResponses() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LoopbackFixtureServer(payload: Data("abcdef".utf8))
        defer { server.stop() }
        let client = URLSessionModelDownloadClient(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            return configuration
        }(), allowHTTPForTesting: true)
        let manifest = ModelManifest(testFiles: [("Preprocessor.mlmodelc/metadata.json", Data("abcdef".utf8))], baseURL: server.baseURL.absoluteString, immutableCommit: fixture.commit)
        let installer = ModelInstaller(unvalidatedManifestForTesting: manifest, store: fixture.store, downloadClient: client, enforceHTTPS: false)

        _ = try await installer.install()
        XCTAssertEqual(try Data(contentsOf: fixture.store.revisionURL(for: fixture.commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")), Data("abcdef".utf8))
        XCTAssertTrue(server.observedRangeHeaders.isEmpty)
    }

    func testLoopbackServerConnectionLossLeavesPartialForResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LoopbackFixtureServer(payload: Data("abcdef".utf8), disconnectAfterBytes: 3)
        defer { server.stop() }
        let client = URLSessionModelDownloadClient(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            return configuration
        }(), allowHTTPForTesting: true)
        let manifest = ModelManifest(testFiles: [("Preprocessor.mlmodelc/metadata.json", Data("abcdef".utf8))], baseURL: server.baseURL.absoluteString, immutableCommit: fixture.commit)
        let installer = ModelInstaller(unvalidatedManifestForTesting: manifest, store: fixture.store, downloadClient: client, enforceHTTPS: false)

        do {
            _ = try await installer.install()
            XCTFail("expected connection loss")
        } catch let error as ModelInstallerError {
            XCTAssertTrue([.connectionLost, .truncatedResponse].contains(error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.downloadsDirectory.appendingPathComponent("\(fixture.commit).partial").path))
    }

    func testLoopbackServerRetryResumesAndCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LoopbackFixtureServer(payload: Data("abcdef".utf8), disconnectAfterBytes: 3, disconnectOnce: true)
        defer { server.stop() }
        let client = URLSessionModelDownloadClient(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            return configuration
        }(), allowHTTPForTesting: true)
        let manifest = ModelManifest(testFiles: [("Preprocessor.mlmodelc/metadata.json", Data("abcdef".utf8))], baseURL: server.baseURL.absoluteString, immutableCommit: fixture.commit)
        let installer = ModelInstaller(unvalidatedManifestForTesting: manifest, store: fixture.store, downloadClient: client, enforceHTTPS: false)

        do {
            _ = try await installer.install()
            XCTFail("expected first connection loss")
        } catch let error as ModelInstallerError {
            XCTAssertTrue([.connectionLost, .truncatedResponse].contains(error))
        }
        _ = try await installer.install()

        XCTAssertEqual(try Data(contentsOf: fixture.store.revisionURL(for: fixture.commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")), Data("abcdef".utf8))
        XCTAssertTrue(server.observedRangeHeaders.contains(where: { $0.contains("bytes=3-") }))
    }

    private struct Fixture {
        let root: URL
        let store: ModelStore
        let commit = String(repeating: "c", count: 40)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-integration-\(UUID().uuidString)")
            store = ModelStore(root: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class LoopbackFixtureServer: @unchecked Sendable {
    let baseURL: URL
    private let listener: Int32
    private let payload: Data
    private let disconnectAfterBytes: Int?
    private var disconnectOnce: Bool
    private var disconnectPending: Bool
    private let behaviorLock = NSLock()
    private let queue = DispatchQueue(label: "syrinx.loopback-fixture", attributes: .concurrent)
    private var running = true
    private(set) var observedRangeHeaders: [String] = []

    init(payload: Data, disconnectAfterBytes: Int? = nil, disconnectOnce: Bool = false) throws {
        self.payload = payload
        self.disconnectAfterBytes = disconnectAfterBytes
        self.disconnectOnce = disconnectOnce
        self.disconnectPending = disconnectOnce
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let socketDescriptor = listener
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &bound, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &length)
            }
        }) == 0 else {
            close(listener)
            throw POSIXError(.EIO)
        }
        baseURL = URL(string: "http://127.0.0.1:\(Int(UInt16(bigEndian: bound.sin_port)))/model")!
        queue.async { [self] in acceptLoop() }
    }

    func stop() {
        running = false
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func acceptLoop() {
        while running {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            queue.async { [self] in handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(Data("\r\n\r\n".utf8)) {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
        }
        let requestText = String(decoding: request, as: UTF8.self)
        let range = requestText.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") })
        if let range { observedRangeHeaders.append(String(range)) }
        let start: Int
        let status: String
        if let range, let value = range.split(separator: "=", maxSplits: 1).last?.split(separator: "-", maxSplits: 1).first, let parsed = Int(value) {
            start = parsed
            status = "206 Partial Content"
        } else {
            start = 0
            status = "200 OK"
        }
        let body = Data(payload.dropFirst(start))
        let headers = "HTTP/1.1 \(status)\r\nTransfer-Encoding: chunked\r\n\(start > 0 ? "Content-Range: bytes \(start)-\(payload.count - 1)/\(payload.count)\r\n" : "")Connection: close\r\n\r\n"
        _ = headers.withCString { Darwin.write(client, $0, strlen($0)) }
        if let disconnectAfterBytes = takeDisconnectAfterBytes() {
            let limited = body.prefix(disconnectAfterBytes)
            let chunkHeader = "\(String(limited.count, radix: 16))\r\n"
            _ = chunkHeader.withCString { Darwin.write(client, $0, strlen($0)) }
            _ = limited.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            _ = "\r\n".withCString { Darwin.write(client, $0, strlen($0)) }
            shutdown(client, SHUT_RDWR)
        } else {
            let chunkHeader = "\(String(body.count, radix: 16))\r\n"
            _ = chunkHeader.withCString { Darwin.write(client, $0, strlen($0)) }
            _ = body.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            _ = "\r\n0\r\n\r\n".withCString { Darwin.write(client, $0, strlen($0)) }
        }
    }

    private func takeDisconnectAfterBytes() -> Int? {
        behaviorLock.lock()
        defer { behaviorLock.unlock() }
        guard let disconnectAfterBytes else { return nil }
        if disconnectOnce {
            guard disconnectPending else { return nil }
            disconnectPending = false
        }
        return disconnectAfterBytes
    }
}
