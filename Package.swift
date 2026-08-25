// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Syrinx",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SyrinxCore", targets: ["SyrinxCore"]),
        .executable(name: "syrinx", targets: ["syrinx"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "19600a485baa4998812e4654b70d2bab8f2c9949"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            revision: "55bc9025a4825ee2a234b1f82b51b87be6ef74e4"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            revision: "9829955b385e5bb88128b73f1b8389e9b9c3191a"
        )
    ],
    targets: [
        .target(name: "SyrinxCore", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdCore", package: "hummingbird"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
        ], resources: [
            .copy("Resources/parakeet-tdt-0.6b-v3-int8.json")
        ]),
        .executableTarget(name: "syrinx", dependencies: ["SyrinxCore"]),
        .executableTarget(name: "LockHelper", dependencies: ["SyrinxCore"]),
        .testTarget(name: "SyrinxCoreTests", dependencies: ["SyrinxCore"]),
        .testTarget(name: "ContractTests", dependencies: [
            "SyrinxCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "ServiceLifecycleTestKit", package: "swift-service-lifecycle")
        ]),
        .testTarget(name: "IntegrationTests", dependencies: ["SyrinxCore"])
    ]
)
