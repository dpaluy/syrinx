// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyrinxClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyrinxClient", targets: ["SyrinxClient"]),
        .executable(name: "parrot", targets: ["ParrotCLI"]),
        .executable(name: "syrinx", targets: ["SyrinxApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
    ],
    targets: [
        .target(
            name: "SyrinxClient",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/parrot",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "ParrotCLI",
            dependencies: ["SyrinxClient"],
            path: "Sources/ParrotCLI"
        ),
        .executableTarget(
            name: "SyrinxApp",
            dependencies: ["SyrinxClient"],
            path: "Sources/SyrinxApp"
        ),
        .testTarget(
            name: "parrotTests",
            dependencies: ["SyrinxClient"]
        ),
    ]
)
