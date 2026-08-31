import AppKit
import XCTest
@testable import SyrinxClient

@MainActor
final class RecordingOverlayTests: XCTestCase {
    func testRecordingIndicatorContainsThreeAnimatedDots() {
        XCTAssertEqual(OverlayModel.indicatorCount, 3)
    }

    func testShowingAgainCancelsPendingHide() async {
        _ = NSApplication.shared
        let overlay = RecordingOverlay()

        overlay.show(.recording)
        overlay.hide()
        overlay.show(.recording)

        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(overlay.isVisibleForTesting)

        overlay.hideImmediatelyForTesting()
    }
}
