import AppKit
import CoreGraphics
import Foundation

/// The text-delivery boundary used by a dictation session.
public protocol TextOutputting: AnyObject {
    func output(_ text: String)
}

/// Posts text at the current cursor by synthesizing Unicode keyboard events.
/// Some Electron applications and secure fields can reject these events.
public final class CGEventTextOutput: TextOutputting {
    public init() {}

    public func output(_ text: String) {
        TextInjector.inject(text)
    }
}

/// Selects only the output mode that the user configured. It does not attempt
/// to detect whether the destination accepted direct typing.
public final class ConfiguredTextOutput: TextOutputting {
    private let preferences: AppPreferences
    private let direct: any TextOutputting
    private let paste: any TextOutputting

    public convenience init(preferences: AppPreferences) {
        self.init(
            preferences: preferences,
            direct: CGEventTextOutput(),
            paste: ClipboardPasteTextOutput()
        )
    }

    internal init(
        preferences: AppPreferences,
        direct: any TextOutputting,
        paste: any TextOutputting
    ) {
        self.preferences = preferences
        self.direct = direct
        self.paste = paste
    }

    public func output(_ text: String) {
        switch preferences.textOutputMode {
        case .directTyping:
            direct.output(text)
        case .clipboardPaste:
            paste.output(text)
        }
    }
}

/// Temporarily writes text to the pasteboard, sends Command-V, then restores
/// the previous pasteboard contents if no other owner changed them.
public final class ClipboardPasteTextOutput: TextOutputting {
    typealias RestoreScheduler = (@escaping () -> Void) -> Void

    private struct PendingRestore {
        let generation: UInt64
        let changeCount: Int
        let snapshot: PasteboardSnapshot
    }

    private let pasteboard: NSPasteboard
    private let pasteAction: () -> Void
    private let scheduleRestore: RestoreScheduler
    private var restoreGeneration: UInt64 = 0
    private var pendingRestore: PendingRestore?

    public convenience init() {
        self.init(
            pasteboard: .general,
            pasteAction: Self.postPasteShortcut,
            scheduleRestore: { restore in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: restore)
            }
        )
    }

    internal init(
        pasteboard: NSPasteboard,
        pasteAction: @escaping () -> Void,
        scheduleRestore: @escaping RestoreScheduler
    ) {
        self.pasteboard = pasteboard
        self.pasteAction = pasteAction
        self.scheduleRestore = scheduleRestore
    }

    public func output(_ text: String) {
        guard !text.isEmpty else { return }
        restoreGeneration &+= 1
        let generation = restoreGeneration
        let snapshot: PasteboardSnapshot
        if let pendingRestore,
           pasteboard.changeCount == pendingRestore.changeCount {
            snapshot = pendingRestore.snapshot
        } else {
            snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pendingRestore = nil
            snapshot.restore(to: pasteboard)
            return
        }

        let syrinxChangeCount = pasteboard.changeCount
        pendingRestore = PendingRestore(
            generation: generation,
            changeCount: syrinxChangeCount,
            snapshot: snapshot
        )
        pasteAction()
        scheduleRestore { [weak self] in
            self?.restorePending(generation: generation)
        }
    }

    private func restorePending(generation: UInt64) {
        guard let pendingRestore,
              pendingRestore.generation == generation
        else { return }
        self.pendingRestore = nil
        guard pasteboard.changeCount == pendingRestore.changeCount else { return }
        pendingRestore.snapshot.restore(to: pasteboard)
    }

    private static func postPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let pasteKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }
}

private struct PasteboardSnapshot {
    struct Item {
        let representations: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(representations: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.representations {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

enum ClipboardText {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Compatibility API for callers that use the original static injector.
public enum TextInjector {
    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit of approximately 20 characters.
    public static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
