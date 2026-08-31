import Foundation
import SherpaOnnxC

/// Facts about the linked sherpa-onnx build, mirroring `WhisperRuntime`.
enum SherpaRuntime {
    /// e.g. "1.13.4".
    static func version() -> String {
        String(cString: SherpaOnnxGetVersionStr())
    }

    /// The onnxruntime linked *into* this xcframework variant, not a separate dylib.
    static func onnxruntimeVersion() -> String {
        String(cString: SherpaOnnxGetOnnxruntimeVersionStr())
    }
}
