import XCTest
@testable import SyrinxCore

final class PathsTests: XCTestCase {
    func testStandardPathsUseTheExpectedMacOSDirectories() {
        let paths = StandardPaths(homeDirectory: "/Users/example")

        XCTAssertEqual(paths.data.path, "/Users/example/Library/Application Support/Syrinx")
        XCTAssertEqual(paths.cache.path, "/Users/example/Library/Caches/Syrinx")
        XCTAssertEqual(paths.logs.path, "/Users/example/Library/Logs/Syrinx")
    }

    func testWritablePathStatusChecksTheNearestExistingParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-path-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = StandardPaths(
            data: root.appendingPathComponent("data"),
            cache: root.appendingPathComponent("cache"),
            logs: root.appendingPathComponent("logs")
        )

        let statuses = paths.writableStatuses(fileManager: .default)

        XCTAssertEqual(statuses.count, 3)
        XCTAssertTrue(statuses.allSatisfy(\.writable))
    }

    func testValidateAcceptsMissingWritableDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-path-validate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try StandardPaths(
            data: root.appendingPathComponent("data"),
            cache: root.appendingPathComponent("cache"),
            logs: root.appendingPathComponent("logs")
        ).validate()
    }

    func testValidateRejectsAFilePath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-path-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("file".utf8).write(to: file)

        XCTAssertThrowsError(
            try StandardPaths(data: file, cache: file, logs: file).validate()
        ) { error in
            XCTAssertEqual(error as? StandardPathsError, .unavailable)
        }
    }
}
