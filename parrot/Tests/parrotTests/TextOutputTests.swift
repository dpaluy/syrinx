import AppKit
import XCTest
@testable import SyrinxClient

@MainActor
final class TextOutputTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyrinxTextOutputTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSessionUsesInjectedOutputAndKeepsLastDictationOnlyInMemory() async throws {
        let output = RecordingTextOutput()
        let copied = StringRecorder()
        let capture = FakeAudioCapture(samples: [Float](repeating: 0.25, count: 4_800))
        let monitor = FakeSessionHotkeyMonitor()
        let preferences = AppPreferences(defaults: defaults)
        let delivered = expectation(description: "text delivered")
        output.onOutput = { delivered.fulfill() }
        let session = makeSession(
            transcriber: ImmediateTranscriber(text: "  hello   world  "),
            monitor: monitor,
            capture: capture,
            preferences: preferences,
            textOutput: output,
            copyText: { copied.values.append($0) }
        )

        try await session.prepare()
        try session.start()
        monitor.send(.pressed)
        monitor.send(.released)
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(output.values, ["hello world"])
        XCTAssertEqual(session.lastDictation, "hello world")
        XCTAssertTrue(session.copyLastDictation())
        XCTAssertEqual(copied.values, ["hello world"])
    }

    func testSessionAppliesConfiguredTransformationsBeforeSelectedOutput() async throws {
        let output = RecordingTextOutput()
        let capture = FakeAudioCapture(samples: [Float](repeating: 0.25, count: 4_800))
        let monitor = FakeSessionHotkeyMonitor()
        let preferences = AppPreferences(defaults: defaults)
        preferences.literalReplacements = [
            LiteralReplacement(match: "syrinks", replacement: "Syrinx")
        ]
        preferences.spokenPunctuationEnabled = true
        let delivered = expectation(description: "transformed text delivered")
        output.onOutput = { delivered.fulfill() }
        let session = makeSession(
            transcriber: ImmediateTranscriber(text: "Use syrinks comma world period"),
            monitor: monitor,
            capture: capture,
            preferences: preferences,
            textOutput: output,
            copyText: { _ in }
        )

        try await session.prepare()
        try session.start()
        monitor.send(.pressed)
        monitor.send(.released)
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(output.values, ["Use Syrinx, world."])
    }

    func testConfiguredOutputNeverUsesClipboardWhenDirectTypingIsSelected() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.textOutputMode = .directTyping
        let direct = RecordingTextOutput()
        let paste = RecordingTextOutput()
        let output = ConfiguredTextOutput(
            preferences: preferences,
            direct: direct,
            paste: paste
        )

        output.output("private text")

        XCTAssertEqual(direct.values, ["private text"])
        XCTAssertTrue(paste.values.isEmpty)
    }

    func testAutomaticSpacingSeparatesConsecutiveSentencesForDirectTyping() {
        let direct = RecordingTextOutput()
        let paste = RecordingTextOutput()
        let output = makeAutomaticOutput(direct: direct, paste: paste)

        output.output("First sentence.")
        output.output("Second sentence.")

        XCTAssertEqual(direct.values, ["First sentence.", " Second sentence."])
        XCTAssertTrue(paste.values.isEmpty)
    }

    func testAutomaticSpacingSeparatesConsecutiveSentencesForClipboardPaste() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.textOutputMode = .clipboardPaste
        let direct = RecordingTextOutput()
        let paste = RecordingTextOutput()
        let output = AutomaticSpacingTextOutput(
            output: ConfiguredTextOutput(preferences: preferences, direct: direct, paste: paste)
        )

        output.output("First sentence!")
        output.output("Second sentence?")

        XCTAssertTrue(direct.values.isEmpty)
        XCTAssertEqual(paste.values, ["First sentence!", " Second sentence?"])
    }

    func testAutomaticSpacingDoesNotAddSpaceWhenWhitespaceExists() {
        let direct = RecordingTextOutput()
        let output = AutomaticSpacingTextOutput(output: direct)

        output.output("First sentence. ")
        output.output("Second sentence.")
        output.output("Third sentence!")
        output.output(" Fourth sentence?")

        XCTAssertEqual(
            direct.values,
            ["First sentence. ", "Second sentence.", " Third sentence!", " Fourth sentence?"]
        )
    }

    func testAutomaticSpacingRecognizesSentencePunctuationBeforeClosingMarks() {
        let direct = RecordingTextOutput()
        let output = AutomaticSpacingTextOutput(output: direct)

        output.output(#"She said, "Stop!""#)
        output.output(#""Then she left.""#)

        XCTAssertEqual(direct.values, [#"She said, "Stop!""#, #" "Then she left.""#])
    }

    func testAutomaticSpacingDoesNotSeparateTextThatContinuesCurrentSentence() {
        let direct = RecordingTextOutput()
        let output = AutomaticSpacingTextOutput(output: direct)

        output.output("This thought")
        output.output("continues here.")
        output.output("and this continues the same sentence")

        XCTAssertEqual(
            direct.values,
            ["This thought", "continues here.", "and this continues the same sentence"]
        )
    }

    func testPasteOutputRestoresEveryPasteboardRepresentation() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SyrinxPasteTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let originalItem = NSPasteboardItem()
        let customType = NSPasteboard.PasteboardType("com.example.private")
        originalItem.setString("original text", forType: .string)
        originalItem.setData(Data([0, 1, 2, 3]), forType: customType)
        XCTAssertTrue(pasteboard.writeObjects([originalItem]))
        var restoration: (() -> Void)?
        var pasteCount = 0
        let output = ClipboardPasteTextOutput(
            pasteboard: pasteboard,
            pasteAction: { pasteCount += 1 },
            scheduleRestore: { restoration = $0 }
        )

        output.output("dictation")

        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
        restoration?()
        let restored = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(restored.string(forType: .string), "original text")
        XCTAssertEqual(restored.data(forType: customType), Data([0, 1, 2, 3]))
    }

    func testOverlappingPasteOutputsRestoreTheOriginalClipboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SyrinxPasteTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var restorations: [() -> Void] = []
        let output = ClipboardPasteTextOutput(
            pasteboard: pasteboard,
            pasteAction: {},
            scheduleRestore: { restorations.append($0) }
        )

        output.output("first")
        output.output("second")

        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        XCTAssertEqual(restorations.count, 2)
        restorations[0]()
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        restorations[1]()

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testOverlappingPasteOutputsRestoreClipboardChangedByAnotherOwner() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SyrinxPasteTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var restorations: [() -> Void] = []
        let output = ClipboardPasteTextOutput(
            pasteboard: pasteboard,
            pasteAction: {},
            scheduleRestore: { restorations.append($0) }
        )

        output.output("first")
        pasteboard.clearContents()
        pasteboard.setString("new owner", forType: .string)
        output.output("second")

        restorations[0]()
        restorations[1]()

        XCTAssertEqual(pasteboard.string(forType: .string), "new owner")
    }

    func testPasteOutputDoesNotOverwriteAClipboardChangeMadeAfterPaste() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SyrinxPasteTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var restoration: (() -> Void)?
        let output = ClipboardPasteTextOutput(
            pasteboard: pasteboard,
            pasteAction: {},
            scheduleRestore: { restoration = $0 }
        )

        output.output("dictation")
        pasteboard.clearContents()
        pasteboard.setString("new owner", forType: .string)
        restoration?()

        XCTAssertEqual(pasteboard.string(forType: .string), "new owner")
    }

    private func makeSession(
        transcriber: any Transcriber,
        monitor: FakeSessionHotkeyMonitor,
        capture: FakeAudioCapture,
        preferences: AppPreferences,
        textOutput: any TextOutputting,
        copyText: @escaping (String) -> Void
    ) -> DictationSession {
        DictationSession(
            model: TextOutputTestModel.model,
            transcriber: transcriber,
            monitorFactory: { _ in monitor },
            capture: capture,
            preferences: preferences,
            loginItemController: LoginItemController(service: TextOutputFakeLoginItemService()),
            menuBar: MenuBarController(modelID: TextOutputTestModel.model.id),
            textOutput: textOutput,
            copyText: copyText
        )
    }

    private func makeAutomaticOutput(
        direct: any TextOutputting,
        paste: any TextOutputting
    ) -> AutomaticSpacingTextOutput {
        let preferences = AppPreferences(defaults: defaults)
        preferences.textOutputMode = .directTyping
        return AutomaticSpacingTextOutput(
            output: ConfiguredTextOutput(preferences: preferences, direct: direct, paste: paste)
        )
    }
}

private enum TextOutputTestModel {
    static let model = TranscriptionModel(
        id: "text-output-test",
        displayName: "Text output test",
        engine: .whisperKit,
        whisperKitID: "text-output-test",
        sizeMB: 1,
        languages: ["en"],
        recommended: false
    )
}

private final class RecordingTextOutput: TextOutputting {
    var values: [String] = []
    var onOutput: (() -> Void)?

    func output(_ text: String) {
        values.append(text)
        onOutput?()
    }
}

private final class StringRecorder {
    var values: [String] = []
}

private struct ImmediateTranscriber: Transcriber {
    let modelID = TextOutputTestModel.model.id
    let text: String

    func prepare() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        text
    }
}

private final class FakeAudioCapture: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    private let samples: [Float]

    init(samples: [Float]) {
        self.samples = samples
    }

    func start() throws {}

    func stop() -> [Float] {
        samples
    }
}

private final class FakeSessionHotkeyMonitor: HotkeyMonitoring {
    let choice: HotkeyChoice = .fnOrGlobe
    private var handler: ((HotkeyMonitor.Event) -> Void)?

    func start(onEvent: @escaping (HotkeyMonitor.Event) -> Void) throws {
        handler = onEvent
    }

    func stop() {
        handler = nil
    }

    func send(_ event: HotkeyMonitor.Event) {
        handler?(event)
    }
}

private final class TextOutputFakeLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus = .disabled

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .disabled
    }
}
