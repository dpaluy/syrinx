import XCTest
@testable import SyrinxClient

final class AppContractTests: XCTestCase {
    func testPermissionStateNamesMissingAccessAndRequiredRecovery() {
        let state = SyrinxPermissionState(
            microphone: .denied,
            accessibility: .granted
        )

        XCTAssertFalse(state.allGranted)
        XCTAssertEqual(state.recordingUnavailableReason, "Microphone permission required")
        XCTAssertEqual(state.microphone.displayText, "Not allowed")
        XCTAssertEqual(
            state.recoveryTitle(for: .microphone),
            "Open Microphone Settings"
        )
        XCTAssertNil(state.recoveryTitle(for: .accessibility))
    }

    func testPermissionStateReportsBothMissingPermissions() {
        let state = SyrinxPermissionState(
            microphone: .notDetermined,
            accessibility: .denied
        )

        XCTAssertEqual(
            state.recordingUnavailableReason,
            "Microphone and Accessibility permissions required"
        )
        XCTAssertEqual(
            state.recoveryTitle(for: .microphone),
            "Request Microphone Access"
        )
        XCTAssertEqual(
            state.recoveryTitle(for: .accessibility),
            "Open Accessibility Settings"
        )
    }

    func testSyrinxIdentityAndRuntimeRequirementsAreStable() {
        XCTAssertEqual(SyrinxAppInfo.productName, "Syrinx")
        XCTAssertEqual(SyrinxAppInfo.executableName, "syrinx")
        XCTAssertEqual(SyrinxAppInfo.bundleIdentifier, "com.dpaluy.syrinx")
        XCTAssertEqual(SyrinxAppInfo.minimumMacOSVersion, "14.0")
        XCTAssertEqual(SyrinxAppInfo.iconFileName, "AppIcon.icns")
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

    func testPermissionFlowRequestsAccessibilityBeforeSettingsCanOpen() {
        XCTAssertEqual(
            SyrinxPermissionFlow.next(
                microphoneGranted: false,
                accessibilityGranted: false,
                accessibilityRequested: false,
                microphoneRequested: false
            ),
            .requestAccessibility
        )
        XCTAssertEqual(
            SyrinxPermissionFlow.next(
                microphoneGranted: false,
                accessibilityGranted: false,
                accessibilityRequested: true,
                microphoneRequested: false
            ),
            .requestMicrophone
        )
    }

    func testPermissionFlowRechecksAfterSettingsAndStartsAfterApproval() {
        let missing = SyrinxPermissionFlow.next(
            microphoneGranted: false,
            accessibilityGranted: false,
            accessibilityRequested: true,
            microphoneRequested: true
        )
        XCTAssertEqual(missing, .showSettings(.accessibility))

        XCTAssertEqual(
            SyrinxPermissionFlow.next(
                microphoneGranted: false,
                accessibilityGranted: false,
                accessibilityRequested: true,
                microphoneRequested: true,
                userAction: .openSettings
            ),
            .openSettings(.accessibility)
        )
        XCTAssertEqual(
            SyrinxPermissionFlow.next(
                microphoneGranted: false,
                accessibilityGranted: false,
                accessibilityRequested: true,
                microphoneRequested: true,
                userAction: .checkAgain
            ),
            .recheck
        )
        XCTAssertEqual(
            SyrinxPermissionFlow.next(
                microphoneGranted: true,
                accessibilityGranted: true,
                accessibilityRequested: true,
                microphoneRequested: true
            ),
            .start
        )
    }

    func testPermissionFlowCancelStopsBeforePermissionRequests() {
        XCTAssertEqual(
            SyrinxPermissionFlow.next(
                microphoneGranted: false,
                accessibilityGranted: false,
                accessibilityRequested: false,
                microphoneRequested: false,
                userAction: .cancel
            ),
            .cancel
        )
    }

    func testPermissionGrantWaiterPollsUntilAccessIsGranted() async {
        var checks = 0
        var waits = 0

        let granted = await SyrinxPermissionGrantWaiter.waitUntilGranted {
            checks += 1
            return checks == 3
        } waitForNextCheck: {
            waits += 1
            return true
        }

        XCTAssertTrue(granted)
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(waits, 2)
    }

    func testPermissionGrantWaiterStopsWhenPollingIsCancelled() async {
        let granted = await SyrinxPermissionGrantWaiter.waitUntilGranted {
            false
        } waitForNextCheck: {
            false
        }

        XCTAssertFalse(granted)
    }
}
