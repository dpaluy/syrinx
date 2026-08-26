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
