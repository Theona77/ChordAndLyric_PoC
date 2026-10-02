// swift-tools-version: 6.2
//
// Command-line evaluation tool for the chord engine. Builds the app's Engine sources directly
// (same files, same concurrency settings as the Xcode target), so what you measure is what ships.
//
//   swift run -c release chord-eval --help
//
import PackageDescription

// Mirrors the app target: Swift 5 mode, MainActor by default, "approachable concurrency".
let appLikeSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "ChordDetection",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "chord-eval", targets: ["chord-eval"]),
    ],
    targets: [
        .executableTarget(
            name: "chord-eval",
            path: ".",
            sources: ["ChordDetectionPOC/Engine", "Tools/chord-eval"],
            swiftSettings: appLikeSettings
        ),
    ],
    swiftLanguageModes: [.v5]
)
