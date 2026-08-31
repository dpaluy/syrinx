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
    private var initialStartComplete = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let preferences = AppPreferences()
            let model = try Self.requireSelectedModel(preferences: preferences)
            let session = try DictationSession(
                model: model,
                preferences: preferences,
                onPermissionRecovery: { [weak self] pane in
                    self?.recoverPermission(pane)
                },
                onPermissionRecheck: { [weak self] in
                    self?.recheckPermissions()
                }
            )
            self.session = session
            session.setStatus("waiting for permissions")
            Task {
                await start(session: session)
            }
        } catch {
            showError(
                title: "Syrinx could not start",
                message: "The selected Whisper model is not available."
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard initialStartComplete else { return }
        recheckPermissions()
    }

    private func start(session: DictationSession) async {
        defer { initialStartComplete = true }
        let accessGranted = await PermissionFlow.requestAccess()
        let permissionState = PermissionFlow.currentState()
        session.updatePermissions(permissionState)
        guard accessGranted, permissionState.allGranted else {
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
                message: "Syrinx could not load the local Whisper model or register the selected shortcut. Check Microphone and Accessibility access, then verify the selected shortcut is available."
            )
        }
    }

    private func recoverPermission(_ pane: SyrinxPermissionPane) {
        Task {
            await PermissionFlow.recover(pane)
            recheckPermissions()
        }
    }

    private func recheckPermissions() {
        guard let session else { return }
        let state = PermissionFlow.currentState()
        session.updatePermissions(state)
        guard state.allGranted else { return }
        do {
            try session.resumeAfterPermissionRecovery()
        } catch {
            session.setStatus("could not resume")
        }
    }

    private static func requireSelectedModel(
        preferences: AppPreferences
    ) throws -> TranscriptionModel {
        guard let model = ModelRegistry.preferredInProcessModel(
            selectedID: preferences.selectedModelID
        ) else {
            throw AppError.selectedModelMissing
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
    case selectedModelMissing
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
                    guard await waitForPermissionGrant(pane: pane) else {
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

    static func currentState() -> SyrinxPermissionState {
        let microphone: SyrinxPermissionStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .notDetermined:
            microphone = .notDetermined
        case .denied:
            microphone = .denied
        case .restricted:
            microphone = .restricted
        @unknown default:
            microphone = .restricted
        }
        return SyrinxPermissionState(
            microphone: microphone,
            accessibility: AXIsProcessTrusted() ? .granted : .denied
        )
    }

    static func recover(_ pane: SyrinxPermissionPane) async {
        switch pane {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await requestMicrophoneIfNeeded()
            } else {
                _ = openSettings(anchor: settingsAnchor(for: .microphone))
            }
        case .accessibility:
            _ = openSettings(anchor: settingsAnchor(for: .accessibility))
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
        alert.informativeText = "Enable Syrinx under " + missing + " in System Settings > Privacy & Security. Syrinx checks again automatically."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .openSettings : .cancel
    }

    private static func waitForPermissionGrant(pane: SyrinxPermissionPane) async -> Bool {
        guard openSettings(anchor: settingsAnchor(for: pane)) else {
            return false
        }
        return await SyrinxPermissionGrantWaiter.waitUntilGranted {
            switch pane {
            case .microphone:
                return microphoneIsGranted()
            case .accessibility:
                return requestAccessibilityIfNeeded(prompt: false)
            }
        } waitForNextCheck: {
            do {
                try await Task.sleep(for: .milliseconds(500))
                return true
            } catch {
                return false
            }
        }
    }

    private static func settingsAnchor(for pane: SyrinxPermissionPane) -> String {
        switch pane {
        case .microphone:
            return "Privacy_Microphone"
        case .accessibility:
            return "Privacy_Accessibility"
        }
    }

    private static func openSettings(anchor: String) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
