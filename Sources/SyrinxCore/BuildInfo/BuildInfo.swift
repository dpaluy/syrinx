import Foundation

public struct BuildInfo: Codable, Equatable, Sendable {
    public let projectVersion: String
    public let commit: String
    public let buildTarget: String
    public let buildDate: String
    public let swiftVersion: String
    public let fluidAudio: String
    public let reproducibleBuildStatus: String

    public init(
        projectVersion: String,
        commit: String,
        buildTarget: String,
        buildDate: String,
        swiftVersion: String,
        fluidAudio: String,
        reproducibleBuildStatus: String
    ) {
        self.projectVersion = projectVersion
        self.commit = commit
        self.buildTarget = buildTarget
        self.buildDate = buildDate
        self.swiftVersion = swiftVersion
        self.fluidAudio = fluidAudio
        self.reproducibleBuildStatus = reproducibleBuildStatus
    }

    public static func from(environment: [String: String]) -> Self {
        Self(
            projectVersion: environment["SYRINX_PROJECT_VERSION"] ?? "0.1.0-dev",
            commit: environment["SYRINX_COMMIT"] ?? "unknown",
            buildTarget: environment["SYRINX_BUILD_TARGET"] ?? "arm64-apple-macosx14.0",
            buildDate: environment["SYRINX_BUILD_DATE"] ?? "unknown",
            swiftVersion: environment["SYRINX_SWIFT_VERSION"] ?? "6.0",
            fluidAudio: environment["SYRINX_FLUID_AUDIO"] ?? "v0.15.5@19600a485baa4998812e4654b70d2bab8f2c9949",
            reproducibleBuildStatus: environment["SYRINX_REPRODUCIBLE_BUILD_STATUS"] ?? "not-configured"
        )
    }

    public static func fromProcessEnvironment() -> Self {
        from(environment: ProcessInfo.processInfo.environment)
    }

    enum CodingKeys: String, CodingKey {
        case projectVersion = "project_version"
        case commit
        case buildTarget = "build_target"
        case buildDate = "build_date"
        case swiftVersion = "swift_version"
        case fluidAudio = "fluid_audio"
        case reproducibleBuildStatus = "reproducible_build_status"
    }
}
