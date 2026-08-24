import Testing
@testable import Macomprendo

@Test func whisperBinaryLinksAndReportsItsCapabilities() {
    let info = WhisperRuntime.systemInfo()
    #expect(!info.isEmpty)
    // whisper >= 1.9 labels the Metal backend "MTL" in system info
    #expect(info.contains("MTL"))
}
