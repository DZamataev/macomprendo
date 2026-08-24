import CoreGraphics
import Foundation
import Testing
@testable import Macomprendo

@Suite struct CGEventKeySimulatorTests {
    @Test func mapsVAndCToTheirANSIKeyCodes() {
        #expect(CGEventKeySimulator.keyCode(for: "v") == 9)
        #expect(CGEventKeySimulator.keyCode(for: "V") == 9)
        #expect(CGEventKeySimulator.keyCode(for: "c") == 8)
        #expect(CGEventKeySimulator.keyCode(for: "C") == 8)
    }

    @Test func returnsNilForKeysItCannotSimulate() {
        #expect(CGEventKeySimulator.keyCode(for: "ß") == nil)
    }

    @Test func splitsTextIntoChunksOfAtMost20UTF16Units() {
        let text = String(repeating: "a", count: 45)
        let chunks = CGEventKeySimulator.chunks(of: text, maxUTF16: 20)
        #expect(chunks.count == 3)
        #expect(chunks.map(\.count) == [20, 20, 5])
        #expect(chunks.joined() == text)
    }

    @Test func neverSplitsInsideACharacter() {
        // Each emoji is 2 UTF-16 units, so 11 of them cannot fit 20 units without splitting a pair.
        let text = String(repeating: "😀", count: 11)
        let chunks = CGEventKeySimulator.chunks(of: text, maxUTF16: 20)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        #expect(chunks.count == 2)
    }

    @Test func emptyTextProducesNoChunks() {
        #expect(CGEventKeySimulator.chunks(of: "", maxUTF16: 20).isEmpty)
    }
}

@Suite struct FakeKeySimulatorTests {
    @Test func recordsPressesAndTypedText() async {
        let simulator = FakeKeySimulator()
        await simulator.pressCommand("v")
        await simulator.type("hello")
        #expect(simulator.pressed == ["v"])
        #expect(simulator.typed == ["hello"])
    }

    @Test func runsTheHookOnEveryCommandPress() async {
        let simulator = FakeKeySimulator()
        let counter = Counter()
        simulator.onPressCommand = { _ in counter.increment() }
        await simulator.pressCommand("v")
        await simulator.pressCommand("c")
        #expect(counter.count == 2)
    }
}
