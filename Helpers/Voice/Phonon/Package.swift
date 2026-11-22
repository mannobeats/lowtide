// swift-tools-version: 6.0
// PhononCoreML from github.com/fermionresearch/phonon-coreml at 1.1.2
// (bf59e57), Apache 2.0, minus its command-line tools. Vendored for one
// change: upstream requires macOS 15, and SwiftPM won't link that into a
// helper that still runs on macOS 14, so `Transcriber` (the only part that
// needs 15, for multifunction Core ML models) is marked available from 15
// instead. Its C decoder (`Binaries`) is built for 15 too, hence the
// linker's version warning, but it only calls libc and pthreads, which 14
// has. To update, copy `Sources/PhononCoreML` and `Binaries` from a newer
// release and put the `@available` back.
import PackageDescription

let package = Package(
    name: "PhononCoreML",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhononCoreML", targets: ["PhononCoreML"]),
    ],
    targets: [
        .binaryTarget(name: "PhononTDT", path: "Binaries/PhononTDT.xcframework"),
        .target(name: "PhononCoreML", dependencies: ["PhononTDT"], path: "Sources/PhononCoreML"),
    ]
)
