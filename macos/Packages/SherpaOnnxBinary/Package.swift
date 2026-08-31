// swift-tools-version: 6.0
import PackageDescription

// sherpa-onnx publishes prebuilt xcframeworks with every release. The
// `-shared-onnxruntime-static` variant is chosen deliberately: its SherpaOnnxC.framework is a
// universal (arm64 + x86_64) dynamic framework whose only dylib dependencies are Foundation,
// libSystem, libc++ and CoreFoundation — onnxruntime is linked in statically, so there is no
// second dylib to ship, sign or discover. See ADR-0009.
let package = Package(
    name: "SherpaOnnxBinary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SherpaOnnx", targets: ["sherpa-onnx"])
    ],
    targets: [
        .binaryTarget(
            name: "sherpa-onnx",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.4-macos-shared-onnxruntime-static.xcframework.zip",
            checksum: "ef7daa86a1e5f5dcb0ccf53e4e475c3ae24414652c9ae9c3912a82140c86fb1a"
        )
    ]
)
