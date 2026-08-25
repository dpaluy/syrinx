import Foundation
import XCTest
@testable import SyrinxCore

final class AtomicStateWriterTests: XCTestCase {
    func testFailuresBeforeRenamePreserveOldBytesAndCleanTemporaryFile() throws {
        let operations: [AtomicStateWriterOperation] = [.open, .write, .fsyncFile, .rename]
        for operation in operations {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-atomic-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent("state.json")
            let old = Data("old-bytes".utf8)
            try old.write(to: destination)
            let writer = AtomicStateWriter(failureInjector: { $0 == operation })

            XCTAssertThrowsError(try writer.write(Data("new-bytes".utf8), to: destination), "operation: \(operation)")
            XCTAssertEqual(try Data(contentsOf: destination), old, "operation: \(operation)")
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertEqual(names, ["state.json"], "operation: \(operation)")
        }
    }

    func testSuccessfulWriteUsesPrivateModeAndReplacesBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-atomic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("state.json")
        try AtomicStateWriter().write(Data("new-bytes".utf8), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new-bytes".utf8))
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testDirectorySyncFailureOccursAfterTheNewBytesAreCommitted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-atomic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("state.json")
        try Data("old-bytes".utf8).write(to: destination)
        let writer = AtomicStateWriter(failureInjector: { $0 == .fsyncDirectory })

        XCTAssertThrowsError(try writer.write(Data("new-bytes".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new-bytes".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["state.json"])
    }
}
