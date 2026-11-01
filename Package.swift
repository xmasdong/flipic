// swift-tools-version:5.9
import Foundation
import PackageDescription

// Pro 功能的源码在 Sources/Photoview/Pro/，不在公开仓库里；有这个文件夹才编进去
let hasPro = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Sources/Photoview/Pro")

let package = Package(
    name: "Flipic",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Flipic",
            path: "Sources/Photoview",
            swiftSettings: [
                .unsafeFlags(["-Osize", "-cross-module-optimization"], .when(configuration: .release))
            ] + (hasPro ? [.define("FLIPIC_PRO")] : []),
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))
            ]
        )
    ]
)
