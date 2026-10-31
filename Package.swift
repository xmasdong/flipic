// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Flipic",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Flipic",
            path: "Sources/Photoview",
            swiftSettings: [
                .unsafeFlags(["-Osize", "-cross-module-optimization"], .when(configuration: .release))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))
            ]
        )
    ]
)
