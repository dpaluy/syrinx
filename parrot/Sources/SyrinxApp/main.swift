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
        var accessibilityRequested = false
        var microphoneRequested = false

        if !UserDefaults.standard.bool(forKey: didShowGuidanceKey) {
            let response = showFirstRunGuidance()
            guard response == .alertFirstButtonReturn else {
                return false
            }
            UserDefaults.standard.set(true, forKey: didShowGuidanceKey)
        }

        while true {
            let microphoneGranted = microphoneIsGranted()
            let accessibilityGranted = requestAccessibilityIfNeeded(prompt: false)
            let action = SyrinxPermissionFlow.next(
                microphoneGranted: microphoneGranted,
                accessibilityGranted: accessibilityGranted,
                accessibilityRequested: accessibilityRequested,
                microphoneRequested: microphoneRequested
            )

            switch action {
            case .requestAccessibility:
                accessibilityRequested = true
                _ = requestAccessibilityIfNeeded(prompt: true)
            case .requestMicrophone:
                microphoneRequested = true
                _ = await requestMicrophoneIfNeeded()
            case .showSettings:
                let userAction = showMissingPermissions(
                    microphoneGranted: microphoneGranted,
                    accessibilityGranted: accessibilityGranted
                )
                let followUp = SyrinxPermissionFlow.next(
                    microphoneGranted: microphoneGranted,
                    accessibilityGranted: accessibilityGranted,
                    accessibilityRequested: accessibilityRequested,
                    microphoneRequested: microphoneRequested,
                    userAction: userAction
                )
                switch followUp {
                case .openSettings(let pane):
                    guard waitForSettings(anchor: settingsAnchor(for: pane)) else {
                        return false
                    }
                    let recheck = SyrinxPermissionFlow.next(
                        microphoneGranted: microphoneGranted,
                        accessibilityGranted: accessibilityGranted,
                        accessibilityRequested: accessibilityRequested,
                        microphoneRequested: microphoneRequested,
                        userAction: .checkAgain
                    )
                    guard recheck == .recheck else {
                        return false
                    }
                case .recheck:
                    break
                case .cancel:
                    return false
                default:
                    return false
                }
            case .start:
                return true
            case .openSettings, .recheck, .cancel:
                return false
            }
        }
    }

    private static func showFirstRunGuidance() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set up Syrinx"
        alert.informativeText = SyrinxAppInfo.firstRunGuidance
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
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

    private static func requestAccessibilityIfNeeded(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private static func microphoneIsGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private static func showMissingPermissions(
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) -> SyrinxPermissionFlowUserAction {
        let missing = [
            microphoneGranted ? nil : "Microphone",
            accessibilityGranted ? nil : "Accessibility",
        ].compactMap { $0 }.joined(separator: " and ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Syrinx needs " + missing + " access"
        alert.informativeText = "Enable Syrinx under " + missing + " in System Settings > Privacy & Security. Return to Syrinx and choose Check Again after you grant access."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Check Again")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .openSettings
        case .alertSecondButtonReturn:
            return .checkAgain
        default:
            return .cancel
        }
    }

    private static func waitForSettings(anchor: String) -> Bool {
        openSettings(anchor: anchor)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Return to Syrinx when access is enabled"
        alert.informativeText = "Choose Check Again after you enable the requested access. Choose Cancel to leave Syrinx waiting for permissions."
        alert.addButton(withTitle: "Check Again")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func settingsAnchor(for pane: SyrinxPermissionPane) -> String {
        switch pane {
        case .microphone:
            return "Privacy_Microphone"
        case .accessibility:
            return "Privacy_Accessibility"
        }
    }

    private static func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
