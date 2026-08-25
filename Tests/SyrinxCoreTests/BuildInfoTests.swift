import XCTest
@testable import SyrinxCore

final class BuildInfoTests: XCTestCase {
    func testBuildInfoHasStableDevelopmentDefaults() {
        let info = BuildInfo.from(environment: [:])

        XCTAssertEqual(info.projectVersion, "0.1.0-dev")
        XCTAssertEqual(info.commit, "unknown")
        XCTAssertEqual(info.buildTarget, "arm64-apple-macosx14.0")
        XCTAssertEqual(info.buildDate, "unknown")
        XCTAssertEqual(info.swiftVersion, "6.0")
        XCTAssertEqual(info.fluidAudio, "v0.15.5@19600a485baa4998812e4654b70d2bab8f2c9949")
        XCTAssertEqual(info.reproducibleBuildStatus, "not-configured")
    }

    func testBuildInfoAcceptsBuildEnvironmentValues() {
        let info = BuildInfo.from(environment: [
            "SYRINX_PROJECT_VERSION": "0.1.0-test",
            "SYRINX_COMMIT": "abc123",
            "SYRINX_BUILD_TARGET": "arm64-apple-macosx14.0",
            "SYRINX_BUILD_DATE": "2026-08-11T00:00:00Z",
            "SYRINX_SWIFT_VERSION": "6.0",
            "SYRINX_REPRODUCIBLE_BUILD_STATUS": "verified"
        ])

        XCTAssertEqual(info.projectVersion, "0.1.0-test")
        XCTAssertEqual(info.commit, "abc123")
        XCTAssertEqual(info.buildDate, "2026-08-11T00:00:00Z")
        XCTAssertEqual(info.reproducibleBuildStatus, "verified")
    }
}
