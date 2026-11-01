// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Vigil", targets: ["Vigil"]),
        .library(name: "VigilCore", targets: ["VigilCore"]),
    ],
    targets: [
        // Everything that knows about git, the file system and change analysis.
        // No SwiftUI in here, so it can be tested quickly from the command line.
        .target(name: "VigilCore"),

        // The macOS app: SwiftUI shell over VigilCore. Vigil.xcodeproj builds the shipped,
        // signed app from the same sources; this target is for `swift run` and the debug hooks.
        // It shares the widget's views (Sources/WidgetUI) with the widget extension, for the
        // menu-bar popover.
        .executableTarget(
            name: "Vigil",
            dependencies: ["VigilCore"],
            path: "Sources",
            sources: ["Vigil", "WidgetUI"],
            linkerSettings: [
                // Embed Info.plist so `swift run Vigil` behaves like a real app
                // (name in the menu bar, activation) even without a bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),

        .testTarget(name: "VigilCoreTests", dependencies: ["VigilCore"]),
    ]
)
