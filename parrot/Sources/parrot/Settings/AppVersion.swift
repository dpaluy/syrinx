import Foundation

public enum AppVersion {
    public static let developmentFallback = "Development"

    public static func current(bundle: Bundle = .main) -> String {
        version(from: bundle.infoDictionary)
    }

    public static func version(from infoDictionary: [String: Any]?) -> String {
        guard let value = infoDictionary?["CFBundleShortVersionString"] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return developmentFallback
        }
        return value
    }
}
