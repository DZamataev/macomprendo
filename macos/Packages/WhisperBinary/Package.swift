// swift-tools-version: 6.0
import PackageDescription

// whisper.cpp deleted its own Package.swift in March 2025 (commit 5bb1d58c) in favour of
// a prebuilt xcframework published with every release. This wrapper is what lets both
// SwiftPM and Xcode consume that one artefact. Metal shaders are embedded in the binary,
// so there is no shader compilation at build time.
let package = Package(
    name: "WhisperBinary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Whisper", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        )
    ]
)
