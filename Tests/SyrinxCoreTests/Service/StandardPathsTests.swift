import Darwin
import Foundation
import XCTest
@testable import SyrinxCore

final class StandardPathsTests: XCTestCase {
    func testTrustedCurrentUserHomeUsesPasswdHomeAndRejectsUnsafeFixtures() throws {
        let uid = getuid()
        guard let passwd = getpwuid(uid), let rawHome = passwd.pointee.pw_dir else {
            XCTFail("the current account must have a passwd home")
            return
        }
        let passwdHome = URL(fileURLWithPath: String(cString: rawHome), isDirectory: true)
            .standardizedFileURL
        XCTAssertEqual(try StandardPaths.trustedCurrentUserHome(), passwdHome)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-trusted-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let valid = root.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(
            at: valid,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(try StandardPaths.validateTrustedHome(valid, uid: uid), valid)

        let symlink = root.appendingPathComponent("symlink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)
        XCTAssertThrowsError(try StandardPaths.validateTrustedHome(symlink, uid: uid))

        let groupWritable = root.appendingPathComponent("group-writable", isDirectory: true)
        try FileManager.default.createDirectory(at: groupWritable, withIntermediateDirectories: false)
        chmod(groupWritable.path, mode_t(0o770))
        XCTAssertThrowsError(try StandardPaths.validateTrustedHome(groupWritable, uid: uid))

        let wrongOwner = root.appendingPathComponent("wrong-owner", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongOwner, withIntermediateDirectories: false)
        XCTAssertThrowsError(try StandardPaths.validateTrustedHome(wrongOwner, uid: uid_t.max))

        let regularFile = root.appendingPathComponent("regular-file")
        try Data("not a directory".utf8).write(to: regularFile)
        chmod(regularFile.path, mode_t(0o600))
        XCTAssertThrowsError(try StandardPaths.validateTrustedHome(regularFile, uid: uid))

        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacement,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(try StandardPaths.validateTrustedHome(replacement, uid: uid), replacement)
        try FileManager.default.removeItem(at: replacement)
        try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: valid)
        XCTAssertThrowsError(try StandardPaths.validateTrustedHome(replacement, uid: uid))
    }
}
