// swift-tools-version: 6.0
import PackageDescription

// Language mode v5 throughout: the TUI render loop, AVPlayer and the audio tap all
// share state across threads in ways that strict concurrency wants reworked. That
// rework is worth doing, but not while the skeleton is still moving.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "hum",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hum", targets: ["hum"]),
    ],
    targets: [
        .target(name: "HumTUI", swiftSettings: v5),
        .target(name: "HumPlex", swiftSettings: v5),
        .target(name: "HumPlayer", dependencies: ["HumPlex"], swiftSettings: v5),
        .target(name: "HumVisualizer", dependencies: ["HumPlayer"], swiftSettings: v5),
        .executableTarget(
            name: "hum",
            dependencies: ["HumTUI", "HumPlex", "HumPlayer", "HumVisualizer"],
            swiftSettings: v5
        ),
    ]
)
