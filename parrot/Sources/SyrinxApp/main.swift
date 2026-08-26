import ApplicationServices
import AppKit
import AVFoundation
import Foundation
import SyrinxClient

@main
struct SyrinxApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = SyrinxAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class SyrinxAppDelegate: NSObject, NSApplicationDelegate {
    private var session: DictationSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let model = try Self.requireRecommendedModel()
            let session = try DictationSession(model: model)
            self.session = session
            session.setStatus("waiting for permissions")
            Task {
                await start(session: session)
            }
        } catch {
            showError(
                title: "Syrinx could not start",
                message: "The recommended Whisper model is not available."
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    private func start(session: DictationSession) async {
        guard await PermissionFlow.requestAccess() else {
            session.setStatus("permissions required")
            return
        }

        session.setStatus("loading Whisper model")
        do {
            try await session.prepare()
            try session.start()
        } catch {
            session.setStatus("could not start")
            showError(
                title: "Syrinx could not start",
                message: "Syrinx could not load the local Whisper model or register the Fn key. Check Microphone, Accessibility, and the Fn or Globe key setting."
            )
        }
    }

    private static func requireRecommendedModel() throws -> TranscriptionModel {
        guard let model = ModelRegistry.recommended() else {
            throw AppError.recommendedModelMissing
        }
        return model
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum AppError: Error {
    case recommendedModelMissing
}

@MainActor
private enum PermissionFlow {
    private static let didShowGuidanceKey = "Syrinx.didShowFirstRunGuidance"

    static func requestAccess() async -> Bool {
        if !UserDefaults.standard.bool(forKey: didShowGuidanceKey) {
            let response = showFirstRunGuidance()
            UserDefaults.standard.set(true, forKey: didShowGuidanceKey)
            if response == .alertSecondButtonReturn {
                openSettings(anchor: "Privacy_Accessibility")
            }
        }

        let microphoneGranted = await requestMicrophoneIfNeeded()
        let accessibilityGranted = requestAccessibilityIfNeeded()
        guard microphoneGranted && accessibilityGranted else {
            showMissingPermissions(
                microphoneGranted: microphoneGranted,
                accessibilityGranted: accessibilityGranted
            )
            return false
        }
        return true
    }

    private static func showFirstRunGuidance() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set up Syrinx"
        alert.informativeText = SyrinxAppInfo.firstRunGuidance
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open System Settings")
        return alert.runModal()
    }

    private static func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func requestAccessibilityIfNeeded() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private static func showMissingPermissions(
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) {
        let missing = [
            microphoneGranted ? nil : "Microphone",
            accessibilityGranted ? nil : "Accessibility",
        ].compactMap { $0 }.joined(separator: " and ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Syrinx needs " + missing + " access"
        alert.informativeText = "Open System Settings > Privacy & Security and enable Syrinx under " + missing + ". Also set the Fn or Globe key to Do Nothing under System Settings > Keyboard, then quit and reopen Syrinx."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings(anchor: accessibilityGranted ? "Privacy_Microphone" : "Privacy_Accessibility")
        }
    }

    private static func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
