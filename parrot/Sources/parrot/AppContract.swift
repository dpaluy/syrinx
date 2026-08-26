import Foundation

public enum SyrinxAppInfo {
    public static let productName = "Syrinx"
    public static let executableName = "syrinx"
    public static let bundleIdentifier = "com.dpaluy.syrinx"
    public static let minimumMacOSVersion = "14.0"
    public static let hotkeyName = "Fn or Globe"
    public static let hotkeySetting = "Do Nothing"

    public static let microphoneUsageDescription =
        "Syrinx records audio only while you hold the Fn or Globe key to transcribe it on this Mac."
    public static let accessibilityUsageDescription =
        "Syrinx uses Accessibility to detect the Fn or Globe key and insert your local transcript at the active cursor."
    public static let firstRunGuidance =
        "Set the Fn or Globe key to Do Nothing in System Settings > Keyboard. Syrinx then needs Microphone and Accessibility access. Audio and transcription stay on this Mac."
}
