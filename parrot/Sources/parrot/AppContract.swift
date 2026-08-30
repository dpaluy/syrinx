import Foundation

public enum SyrinxAppInfo {
    public static let productName = "Syrinx"
    public static let executableName = "syrinx"
    public static let bundleIdentifier = "com.dpaluy.syrinx"
    public static let minimumMacOSVersion = "14.0"
    public static let iconFileName = "AppIcon.icns"
    public static let hotkeyName = "Fn or Globe"
    public static let hotkeySetting = "Do Nothing"

    public static let microphoneUsageDescription =
        "Syrinx records audio only while you hold the Fn or Globe key to transcribe it on this Mac."
    public static let accessibilityUsageDescription =
        "Syrinx uses Accessibility to detect the Fn or Globe key and insert your local transcript at the active cursor."
    public static let firstRunGuidance =
        "Set the Fn or Globe key to Do Nothing in System Settings > Keyboard. Syrinx then needs Microphone and Accessibility access. Audio and transcription stay on this Mac."
}

public enum SyrinxPermissionPane: Equatable {
    case microphone
    case accessibility
}

public enum SyrinxPermissionStatus: Equatable, Sendable {
    case unknown
    case notDetermined
    case denied
    case restricted
    case granted

    public var displayText: String {
        switch self {
        case .unknown:
            return "Checking"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Not allowed"
        case .restricted:
            return "Restricted"
        case .granted:
            return "Allowed"
        }
    }
}

public struct SyrinxPermissionState: Equatable, Sendable {
    public let microphone: SyrinxPermissionStatus
    public let accessibility: SyrinxPermissionStatus

    public init(
        microphone: SyrinxPermissionStatus,
        accessibility: SyrinxPermissionStatus
    ) {
        self.microphone = microphone
        self.accessibility = accessibility
    }

    public static let unknown = SyrinxPermissionState(
        microphone: .unknown,
        accessibility: .unknown
    )
    public static let granted = SyrinxPermissionState(
        microphone: .granted,
        accessibility: .granted
    )

    public var allGranted: Bool {
        microphone == .granted && accessibility == .granted
    }

    public var recordingUnavailableReason: String? {
        let microphoneMissing = microphone != .granted
        let accessibilityMissing = accessibility != .granted
        switch (microphoneMissing, accessibilityMissing) {
        case (false, false):
            return nil
        case (true, false):
            return "Microphone permission required"
        case (false, true):
            return "Accessibility permission required"
        case (true, true):
            return "Microphone and Accessibility permissions required"
        }
    }

    public func status(for pane: SyrinxPermissionPane) -> SyrinxPermissionStatus {
        switch pane {
        case .microphone:
            return microphone
        case .accessibility:
            return accessibility
        }
    }

    public func recoveryTitle(for pane: SyrinxPermissionPane) -> String? {
        let status = status(for: pane)
        guard status != .granted, status != .unknown else { return nil }
        if pane == .microphone, status == .notDetermined {
            return "Request Microphone Access"
        }
        switch pane {
        case .microphone:
            return "Open Microphone Settings"
        case .accessibility:
            return "Open Accessibility Settings"
        }
    }
}

public enum SyrinxPermissionFlowAction: Equatable {
    case requestAccessibility
    case requestMicrophone
    case showSettings(SyrinxPermissionPane)
    case openSettings(SyrinxPermissionPane)
    case recheck
    case start
    case cancel
}

public enum SyrinxPermissionFlowUserAction: Equatable {
    case openSettings
    case checkAgain
    case cancel
}

public enum SyrinxPermissionFlow {
    public static func next(
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        accessibilityRequested: Bool,
        microphoneRequested: Bool,
        userAction: SyrinxPermissionFlowUserAction? = nil
    ) -> SyrinxPermissionFlowAction {
        if let userAction {
            switch userAction {
            case .openSettings:
                return .openSettings(missingPane(
                    microphoneGranted: microphoneGranted,
                    accessibilityGranted: accessibilityGranted
                ))
            case .checkAgain:
                return .recheck
            case .cancel:
                return .cancel
            }
        }

        if microphoneGranted && accessibilityGranted {
            return .start
        }
        if !accessibilityGranted && !accessibilityRequested {
            return .requestAccessibility
        }
        if !microphoneGranted && !microphoneRequested {
            return .requestMicrophone
        }
        return .showSettings(missingPane(
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted
        ))
    }

    private static func missingPane(
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) -> SyrinxPermissionPane {
        accessibilityGranted ? .microphone : .accessibility
    }
}

public enum SyrinxPermissionGrantWaiter {
    public static func waitUntilGranted(
        isGranted: () -> Bool,
        waitForNextCheck: () async -> Bool
    ) async -> Bool {
        while !isGranted() {
            guard await waitForNextCheck() else {
                return false
            }
        }
        return true
    }
}
