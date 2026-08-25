import Foundation
@testable import Macomprendo

struct ScriptedTranscriber: TranscriptionProvider {
    var text: String = "hello world"
    var failure: MacomprendoError?

    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        if let failure { throw failure }
        return text
    }
}
