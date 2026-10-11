// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-audio-forge",
    // AVFoundation and Accelerate only — headless, no UI framework, no vendored
    // codecs. macOS 14 rather than the 26 its video sibling needs: nothing here
    // leans on a recent framework, and a CLI wants to run on whatever the user has.
    platforms: [
        .macOS(.v14), .iOS(.v17)
    ],
    products: [
        .library(name: "AudioForge", targets: ["AudioForge"]),
    ],
    targets: [
        .target(name: "AudioForge"),
        .testTarget(name: "AudioForgeTests", dependencies: ["AudioForge"]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
