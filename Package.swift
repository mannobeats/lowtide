// swift-tools-version: 6.2
// Lowtide: one native app that keeps a Mac in shape.
// LowtideKit holds the logic (no SwiftUI, testable alone); Lowtide is the app.
// The dictation helper is its own package (Helpers/Voice) so the app builds
// in seconds without MLX.
import PackageDescription

let package = Package(
    name: "Lowtide",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "LowtideKit",
            path: "Sources/LowtideKit",
            linkerSettings: [
                .linkedLibrary("pcap"),
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "Lowtide",
            dependencies: [
                "LowtideKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Lowtide",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "LowtideKitTests", dependencies: ["LowtideKit"], path: "Tests/LowtideKitTests"),
    ]
)
