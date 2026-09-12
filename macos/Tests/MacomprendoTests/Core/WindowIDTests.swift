import Testing
@testable import Macomprendo

@Suite struct WindowIDTests {
    @Test func idsAreStableAndDistinct() {
        #expect(WindowID.about == "about")
        #expect(WindowID.dictationHistory == "dictation-history")
        #expect(WindowID.about != WindowID.dictationHistory)
    }
}
