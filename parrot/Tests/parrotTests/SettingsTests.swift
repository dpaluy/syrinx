import XCTest
@testable import SyrinxClient

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyrinxSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        super.tearDown()
    }

    func testPreferencesUseSafeDefaultsAndPersistTypedValues() {
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.addTrailingSpace)
        XCTAssertEqual(preferences.hotkeyChoice, .fnOrGlobe)

        preferences.addTrailingSpace = false
        preferences.hotkeyChoice = .rightOption

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.addTrailingSpace)
        XCTAssertEqual(reloaded.hotkeyChoice, .rightOption)
    }

    func testUnknownHotkeyValueFallsBackToFnOrGlobe() {
        defaults.set("unknown", forKey: AppPreferences.Keys.hotkeyChoice)

        XCTAssertEqual(AppPreferences(defaults: defaults).hotkeyChoice, .fnOrGlobe)
    }

    func testTextOutputPolicySanitizesAndAddsOneAsciiSpaceOnlyWhenEnabled() {
        XCTAssertEqual(
            TextOutputPolicy.output(for: "  hello   world  ", addTrailingSpace: true),
            "hello world "
        )
        XCTAssertEqual(
            TextOutputPolicy.output(for: "hello.  ", addTrailingSpace: true),
            "hello. "
        )
        XCTAssertEqual(
            TextOutputPolicy.output(for: "[BLANK_AUDIO] (silence) hello", addTrailingSpace: false),
            "hello"
        )
        XCTAssertNil(TextOutputPolicy.output(for: " [MUSIC] ", addTrailingSpace: true))
    }

    func testHotkeyChoicesHaveStableNamesAndModifierPolicies() {
        XCTAssertEqual(HotkeyChoice.allCases.map(\.displayName), [
            "Fn or Globe",
            "Right Command",
            "Right Option",
        ])
        XCTAssertEqual(HotkeyChoice.fnOrGlobe.keyCode, 63)
        XCTAssertEqual(HotkeyChoice.rightCommand.keyCode, 54)
        XCTAssertEqual(HotkeyChoice.rightOption.keyCode, 61)
        XCTAssertTrue(HotkeyChoice.fnOrGlobe.requiredFlags.contains(.maskSecondaryFn))
        XCTAssertTrue(HotkeyChoice.rightCommand.requiredFlags.contains(.maskCommand))
        XCTAssertTrue(HotkeyChoice.rightOption.requiredFlags.contains(.maskAlternate))
    }

    func testVersionUsesDevelopmentFallbackWhenBundleDoesNotProvideOne() {
        XCTAssertEqual(AppVersion.version(from: [:]), "Development")
        XCTAssertEqual(
            AppVersion.version(from: ["CFBundleShortVersionString": "1.2.3"]),
            "1.2.3"
        )
    }

    func testModelStateDisplayIncludesProgressAndFailure() {
        XCTAssertEqual(ModelLifecycleState.checking.displayText, "Checking for model")
        XCTAssertEqual(
            ModelLifecycleState.downloading(progress: 0.42).displayText,
            "Downloading model (42%)"
        )
        XCTAssertEqual(ModelLifecycleState.downloaded.displayText, "Model downloaded")
        XCTAssertEqual(ModelLifecycleState.loading.displayText, "Loading model")
        XCTAssertEqual(ModelLifecycleState.ready.displayText, "Model ready")
        XCTAssertEqual(
            ModelLifecycleState.failed("network unavailable").displayText,
            "Model failed: network unavailable"
        )
    }
}
