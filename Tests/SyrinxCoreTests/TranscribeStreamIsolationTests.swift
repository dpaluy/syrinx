import Foundation
import XCTest
@testable import SyrinxCore

final class TranscribeStreamIsolationTests: XCTestCase {
    func testFailedSecondRedirectRestoresTheFirstRedirectBeforeThrowing() {
        let operations = FakeTranscribeStreamOperations(failReplaceCall: 2)

        XCTAssertThrowsError(try TranscribeStreamIsolation(operations: operations))
        XCTAssertEqual(
            operations.replaceCalls.map(FakeTranscribeStreamOperations.Replacement.init),
            [
                FakeTranscribeStreamOperations.Replacement(descriptor: STDOUT_FILENO, source: operations.nullDescriptor),
                FakeTranscribeStreamOperations.Replacement(descriptor: STDERR_FILENO, source: operations.nullDescriptor),
                FakeTranscribeStreamOperations.Replacement(descriptor: STDOUT_FILENO, source: operations.outputDescriptor)
            ]
        )
        XCTAssertEqual(
            Set(operations.closedDescriptors),
            [operations.outputDescriptor, operations.errorDescriptor, operations.nullDescriptor]
        )
    }

    func testSuccessfulIsolationWritesToSavedDescriptorsUntilDestroyed() throws {
        let operations = FakeTranscribeStreamOperations()
        var isolation: TranscribeStreamIsolation? = try TranscribeStreamIsolation(operations: operations)

        isolation?.write(CommandResult(exitCode: 0, stdout: "human\n", stderr: "error\n"))
        XCTAssertEqual(operations.writes.map(\.descriptor), [operations.outputDescriptor, operations.errorDescriptor])
        XCTAssertEqual(operations.writes.map(\.text), ["human\n", "error\n"])
        XCTAssertEqual(operations.replaceCalls.count, 2)

        isolation = nil
        XCTAssertEqual(
            operations.replaceCalls.suffix(2).map(FakeTranscribeStreamOperations.Replacement.init),
            [
                FakeTranscribeStreamOperations.Replacement(descriptor: STDOUT_FILENO, source: operations.outputDescriptor),
                FakeTranscribeStreamOperations.Replacement(descriptor: STDERR_FILENO, source: operations.errorDescriptor)
            ]
        )
    }
}

private final class FakeTranscribeStreamOperations: TranscribeStreamOperations {
    struct Replacement: Equatable {
        let descriptor: Int32
        let source: Int32

        init(_ call: (Int32, Int32)) {
            descriptor = call.0
            source = call.1
        }

        init(descriptor: Int32, source: Int32) {
            self.descriptor = descriptor
            self.source = source
        }
    }

    struct Write: Equatable {
        let descriptor: Int32
        let text: String
    }

    let outputDescriptor: Int32 = 40
    let errorDescriptor: Int32 = 41
    let nullDescriptor: Int32 = 42
    let failReplaceCall: Int
    private(set) var replaceCalls: [(Int32, Int32)] = []
    private(set) var closedDescriptors: [Int32] = []
    private(set) var writes: [Write] = []

    init(failReplaceCall: Int = 0) {
        self.failReplaceCall = failReplaceCall
    }

    func flush() {}

    func duplicate(_ descriptor: Int32) -> Int32 {
        descriptor == STDOUT_FILENO ? outputDescriptor : errorDescriptor
    }

    func openNullDevice() -> Int32 {
        nullDescriptor
    }

    func replace(_ descriptor: Int32, with source: Int32) -> Int32 {
        replaceCalls.append((descriptor, source))
        return replaceCalls.count == failReplaceCall ? -1 : descriptor
    }

    func close(_ descriptor: Int32) {
        closedDescriptors.append(descriptor)
    }

    func write(_ data: Data, to descriptor: Int32) -> Int {
        writes.append(Write(descriptor: descriptor, text: String(decoding: data, as: UTF8.self)))
        return data.count
    }
}
