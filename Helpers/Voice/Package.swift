// swift-tools-version: 6.0
// lowtide-voice: Lowtide's on-device dictation helper, its own process so a
// model crash can't take the app down and the models' memory goes when it
// quits. Built by scripts/build-voice.sh into Contents/Helpers.
import PackageDescription

let package = Package(
    name: "lowtide-voice",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet on the Neural Engine (Core ML).
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.5"),
        // Qwen3-ASR on the GPU (MLX).
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", revision: "8d86630ade569728aaea3dc1a29fc44e2efa719b"),
        // The MLX releases mlx-audio-swift is tested with; newer ones make
        // `compile` closures `@Sendable` and its sources stop building.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        // Phonon-2 on the Neural Engine (Core ML); see Phonon/Package.swift.
        .package(path: "Phonon"),
    ],
    targets: [
        .executableTarget(
            name: "lowtide-voice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "PhononCoreML", package: "Phonon"),
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
