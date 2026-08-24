// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macomprendo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Macomprendo", targets: ["Macomprendo"])
    ],
    dependencies: [
        .package(path: "Packages/WhisperBinary"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Macomprendo",
            dependencies: [
                .product(name: "Whisper", package: "WhisperBinary"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Macomprendo",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacomprendoTests",
            dependencies: ["Macomprendo"],
            path: "Tests/MacomprendoTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
