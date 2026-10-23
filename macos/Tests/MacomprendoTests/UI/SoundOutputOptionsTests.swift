import Testing
@testable import Macomprendo

@Suite struct SoundOutputOptionsTests {
    private let speakers = AudioInputDevice(id: 1, uid: "speakers", name: "MacBook Speakers")

    @Test func listsTheSystemDefaultFirstThenEachOutput() {
        #expect(GeneralTab.soundOutputOptions([speakers], selected: nil)
                == [.init(uid: nil, title: "System default"),
                    .init(uid: "speakers", title: "MacBook Speakers")])
    }

    @Test func keepsADisconnectedChoiceListed() {
        #expect(GeneralTab.soundOutputOptions([speakers], selected: "gone").last
                == .init(uid: "gone", title: "Disconnected device"))
    }
}
