// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mimamori",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Mimamori", targets: ["Mimamori"]),
        .library(name: "MimamoriCore", targets: ["MimamoriCore"]),
    ],
    targets: [
        // Everything that knows about git, the file system and change analysis.
        // No SwiftUI in here, so it can be tested quickly from the command line.
        .target(name: "MimamoriCore"),

        // The macOS app: SwiftUI shell over MimamoriCore. Mimamori.xcodeproj builds the shipped,
        // signed app from the same sources; this target is for `swift run` and the debug hooks.
        // It shares the widget's views (Sources/WidgetUI) with the widget extension, for the
        // menu-bar popover.
        .executableTarget(
            name: "Mimamori",
            dependencies: ["MimamoriCore"],
            path: "Sources",
            sources: ["Mimamori", "WidgetUI"],
            linkerSettings: [
                // Embed Info.plist so `swift run Mimamori` behaves like a real app
                // (name in the menu bar, activation) even without a bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),

        // Fixtures/state holds state.json as each release wrote it, for the loading tests.
        .testTarget(name: "MimamoriCoreTests", dependencies: ["MimamoriCore"], resources: [.copy("Fixtures")]),
    ]
)
