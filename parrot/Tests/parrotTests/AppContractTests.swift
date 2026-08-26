import XCTest
@testable import SyrinxClient

final class AppContractTests: XCTestCase {
    func testSyrinxIdentityAndRuntimeRequirementsAreStable() {
        XCTAssertEqual(SyrinxAppInfo.productName, "Syrinx")
        XCTAssertEqual(SyrinxAppInfo.executableName, "syrinx")
        XCTAssertEqual(SyrinxAppInfo.bundleIdentifier, "com.dpaluy.syrinx")
        XCTAssertEqual(SyrinxAppInfo.minimumMacOSVersion, "14.0")
    }

    func testFirstRunGuidanceNamesRequiredAccessAndFnSetting() {
        let guidance = SyrinxAppInfo.firstRunGuidance

        XCTAssertTrue(guidance.contains("Microphone"))
        XCTAssertTrue(guidance.contains("Accessibility"))
        XCTAssertTrue(guidance.contains("Fn or Globe"))
        XCTAssertTrue(guidance.contains("Do Nothing"))
        XCTAssertTrue(guidance.contains("stay on this Mac"))
    }

    func testUsageDescriptionsMatchLocalOnlyRuntime() {
        XCTAssertTrue(SyrinxAppInfo.microphoneUsageDescription.contains("only while you hold"))
        XCTAssertTrue(SyrinxAppInfo.microphoneUsageDescription.contains("this Mac"))
        XCTAssertTrue(SyrinxAppInfo.accessibilityUsageDescription.contains("active cursor"))
    }
}
