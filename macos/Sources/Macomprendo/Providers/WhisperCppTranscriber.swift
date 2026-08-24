import Foundation
import whisper

/// Facts about the linked whisper.cpp build. Plan 2 adds `WhisperCppTranscriber` here.
enum WhisperRuntime {
    /// whisper.cpp's capability string, e.g. "MTL : EMBED_LIBRARY = 1 | CPU : SSE3 = 1 | … " (v1.9.2 output).
    static func systemInfo() -> String {
        String(cString: whisper_print_system_info())
    }
}
