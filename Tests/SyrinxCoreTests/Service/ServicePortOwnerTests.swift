import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class ServicePortOwnerTests: XCTestCase {
    func testPortOwnerParserRejectsWrongPIDWrongPortSubstringMalformedAndExtraBlocks() async {
        let cases: [(String, String?)] = [
            ("p123\nn127.0.0.1:5092\n", "pid:123"),
            ("p124\nn127.0.0.1:5092\n", nil),
            ("p123\nn127.0.0.1:15092\n", nil),
            ("p123\nn127.0.0.1:50920\n", nil),
            ("p123\nn*:5092\n", nil),
            ("p123\nn[::]:5092\n", nil),
            ("p123\nn[::1]:5092\n", nil),
            ("p123\nn0.0.0.0:5092\n", nil),
            ("p123\nn10.0.0.1:5092\n", nil),
            ("p123\nn127.0.0.15092\n", nil),
            ("p123\nn127.0.0.1:5092->127.0.0.1:6000\n", nil),
            ("p123\nx127.0.0.1:5092\n", nil),
            ("p124\nn127.0.0.1:5092\np123\n", nil),
            ("p123\n", nil)
        ]

        for (output, expected) in cases {
            let runner = FixedOutputProcessRunner(output: output)
            let owner = await verifiedPortOwner(
                processRunner: runner,
                port: 5092,
                processID: 123
            )
            XCTAssertEqual(owner, expected, output)
        }
    }

    func testPortOwnerUsesRealLocalListenerWhenLsofIsAvailable() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else {
            XCTFail("/usr/sbin/lsof is required for the local owner probe")
            return
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(descriptor, 1), 0)

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var boundAddress = sockaddr_in()
        let received = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        XCTAssertEqual(received, 0)
        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        let owner = await verifiedPortOwner(
            processRunner: SystemServiceProcessRunner(),
            port: port,
            processID: getpid()
        )
        XCTAssertEqual(owner, "pid:\(getpid())")
    }
}

private final class FixedOutputProcessRunner: ServiceProcessRunner, @unchecked Sendable {
    let output: String

    init(output: String) {
        self.output = output
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> ServiceProcessResult {
        ServiceProcessResult(exitCode: 0, stdout: output)
    }
}
