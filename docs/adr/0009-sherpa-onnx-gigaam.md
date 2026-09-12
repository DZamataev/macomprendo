# ADR-0009: sherpa-onnx provides local GigaAM transcription

## Status

Accepted — 2026-08-31

## Context

GigaAM has no whisper.cpp-style runtime. sherpa-onnx supports both its CTC and transducer
variants and publishes prebuilt macOS xcframeworks per release. Writing log-mel feature
extraction and RNN-T decoding by hand would be numeric code whose errors corrupt text silently
rather than failing.

## Decision

Vendor `sherpa-onnx-v1.13.4-macos-shared-onnxruntime-static.xcframework.zip` as a
`binaryTarget` in `macos/Packages/SherpaOnnxBinary`, checksum
`ef7daa86a1e5f5dcb0ccf53e4e475c3ae24414652c9ae9c3912a82140c86fb1a`.

## Consequences

- The installed `.app` grows by roughly 54 MB; the framework compresses to roughly 18 MB
  in a release archive.
- `SherpaOnnxC.framework` is an additional, second dynamic framework in the bundle after
  `whisper.framework`. Its presence exercises `Contents/Frameworks`, the added rpath, and
  innermost-out signing for Sherpa as well as whisper.
- Upstream's `xcframework` tag is a rolling tag, so upgrading means downloading the asset,
  re-running `swift package compute-checksum`, and re-verifying the resulting bundle.
- The two multilingual catalog entries come from a community conversion with no official sherpa
  export, pinned by SHA-256 and covered by a dedicated smoke-test step.
