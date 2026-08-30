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
        XCTAssertEqual(preferences.textOutputMode, .directTyping)
        XCTAssertNil(preferences.selectedModelID)
        XCTAssertFalse(preferences.spokenPunctuationEnabled)
        XCTAssertEqual(preferences.literalReplacements, [])

        let replacements = [
            LiteralReplacement(match: "syrinks", replacement: "Syrinx"),
            LiteralReplacement(match: "git hub", replacement: "GitHub"),
        ]
        preferences.addTrailingSpace = false
        preferences.hotkeyChoice = .rightOption
        preferences.textOutputMode = .clipboardPaste
        preferences.selectedModelID = "whisper-small.en"
        preferences.spokenPunctuationEnabled = true
        preferences.literalReplacements = replacements

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.addTrailingSpace)
        XCTAssertEqual(reloaded.hotkeyChoice, .rightOption)
        XCTAssertEqual(reloaded.textOutputMode, .clipboardPaste)
        XCTAssertEqual(reloaded.selectedModelID, "whisper-small.en")
        XCTAssertTrue(reloaded.spokenPunctuationEnabled)
        XCTAssertEqual(reloaded.literalReplacements, replacements)
    }

    func testUnknownPreferenceValuesFallBackToSafeDefaults() {
        defaults.set("unknown", forKey: AppPreferences.Keys.hotkeyChoice)
        defaults.set("unknown", forKey: AppPreferences.Keys.textOutputMode)

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.hotkeyChoice, .fnOrGlobe)
        XCTAssertEqual(preferences.textOutputMode, .directTyping)
    }

    func testTextOutputModesHaveExplicitUserFacingNames() {
        XCTAssertEqual(TextOutputMode.allCases.map(\.displayName), [
            "Direct typing",
            "Clipboard paste",
        ])
    }

    func testUtteranceAcceptancePolicyUsesExactMinimumSampleBoundary() {
        XCTAssertFalse(UtteranceAcceptancePolicy.accepts(sampleCount: 0))
        XCTAssertFalse(UtteranceAcceptancePolicy.accepts(sampleCount: 4_799))
        XCTAssertTrue(UtteranceAcceptancePolicy.accepts(sampleCount: 4_800))
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

    func testTextOutputPolicySuppressesPunctuationOnlySanitizedResults() {
        XCTAssertNil(TextOutputPolicy.output(for: "...!?", addTrailingSpace: false))
        XCTAssertNil(TextOutputPolicy.output(for: "[BLANK_AUDIO] — (silence)", addTrailingSpace: true))
        XCTAssertEqual(
            TextOutputPolicy.output(for: "Hello, world!", addTrailingSpace: false),
            "Hello, world!"
        )
    }

    func testLiteralReplacementsRunInConfiguredOrder() {
        let replacements = [
            LiteralReplacement(match: "Syrinx", replacement: "the app"),
            LiteralReplacement(match: "the app", replacement: "Syrinx for Mac"),
        ]

        XCTAssertEqual(
            TextOutputPolicy.output(
                for: "Use Syrinx",
                addTrailingSpace: false,
                literalReplacements: replacements
            ),
            "Use Syrinx for Mac"
        )
    }

    func testSpokenPunctuationCanBeEnabledWithoutReplacements() {
        XCTAssertEqual(
            TextOutputPolicy.output(
                for: "Hello comma world period",
                addTrailingSpace: false,
                spokenPunctuationEnabled: true
            ),
            "Hello, world."
        )
    }

    func testEmptyReplacementValueIsDeterministic() {
        XCTAssertEqual(
            TextOutputPolicy.output(
                for: "remove filler",
                addTrailingSpace: false,
                literalReplacements: [LiteralReplacement(match: " filler", replacement: "")]
            ),
            "remove"
        )
    }

    func testReplacementSettingsTextPreservesOrderAndEmptyReplacementValues() {
        let replacements = [
            LiteralReplacement(match: "syrinks", replacement: "Syrinx"),
            LiteralReplacement(match: "filler", replacement: ""),
        ]

        let encoded = LiteralReplacementSettingsText.encode(replacements)

        XCTAssertEqual(encoded, "syrinks => Syrinx\nfiller => ")
        XCTAssertEqual(LiteralReplacementSettingsText.decode(encoded), replacements)
    }

    func testReplacementSettingsTextRoundTripsLeadingAndTrailingWhitespace() {
        let replacements = [
            LiteralReplacement(match: " filler", replacement: ""),
            LiteralReplacement(match: "hello ", replacement: " hi"),
            LiteralReplacement(match: "lead", replacement: "trail "),
        ]

        let encoded = LiteralReplacementSettingsText.encode(replacements)

        XCTAssertEqual(
            encoded,
            " filler => \nhello  =>  hi\nlead => trail "
        )
        XCTAssertEqual(LiteralReplacementSettingsText.decode(encoded), replacements)
    }

    func testDecodedLeadingSpaceRemovalRuleAppliesWithAndWithoutTrailingSpace() {
        let replacements = LiteralReplacementSettingsText.decode(" filler => ")

        XCTAssertEqual(
            replacements,
            [LiteralReplacement(match: " filler", replacement: "")]
        )
        XCTAssertEqual(
            TextOutputPolicy.output(
                for: "remove filler",
                addTrailingSpace: false,
                literalReplacements: replacements
            ),
            "remove"
        )
        XCTAssertEqual(
            TextOutputPolicy.output(
                for: "remove filler",
                addTrailingSpace: true,
                literalReplacements: replacements
            ),
            "remove "
        )
    }

    func testEmptyMatchEditorLinesAreRejectedWithoutDisablingValidTransformations() {
        let replacements = LiteralReplacementSettingsText.decode("hello => hi\n => invalid")

        XCTAssertEqual(
            replacements,
            [LiteralReplacement(match: "hello", replacement: "hi")]
        )
        XCTAssertEqual(
            TextOutputPolicy.output(
                for: "hello comma world period",
                addTrailingSpace: false,
                literalReplacements: replacements,
                spokenPunctuationEnabled: true
            ),
            "hi, world."
        )
    }

    func testInvalidEmptyMatchFailsOpenToOriginalSanitizedTranscript() {
        XCTAssertEqual(
            TextOutputPolicy.output(
                for: " [MUSIC] Hello period ",
                addTrailingSpace: true,
                literalReplacements: [LiteralReplacement(match: "", replacement: "invalid")],
                spokenPunctuationEnabled: true
            ),
            "Hello period "
        )
    }

    func testDisabledTransformationsPreserveExistingOutputBehavior() {
        XCTAssertEqual(
            TextOutputPolicy.output(for: "Hello comma world period", addTrailingSpace: true),
            "Hello comma world period "
        )
        XCTAssertNil(TextOutputPolicy.output(for: "[BLANK_AUDIO]", addTrailingSpace: false))
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
