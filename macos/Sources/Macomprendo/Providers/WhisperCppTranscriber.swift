import Foundation
import whisper

/// Facts about the linked whisper.cpp build. Plan 2 adds `WhisperCppTranscriber` here.
enum WhisperRuntime {
    /// whisper.cpp's capability string, e.g. "AVX = 0 | … | METAL = 1 | …".
    static func systemInfo() -> String {
        String(cString: whisper_print_system_info())
    }
}
