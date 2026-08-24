import Foundation
import KeyboardShortcuts
import Testing
@testable import Macomprendo

@MainActor
@Suite struct HotkeyNameTests {
    @Test func everyActionMapsToADistinctName() {
        let names = HotkeyAction.allCases.map { KeyboardShortcuts.Name.forAction($0).rawValue }
        #expect(Set(names).count == HotkeyAction.allCases.count)
    }

    @Test func dictateDefaultsToOptionSpace() {
        let shortcut = KeyboardShortcuts.Name.dictate.defaultShortcut
        #expect(shortcut?.key == .space)
        #expect(shortcut?.modifiers == [.option])
    }

    @Test func dictateAndRefineDefaultsToOptionShiftSpace() {
        let shortcut = KeyboardShortcuts.Name.dictateAndRefine.defaultShortcut
        #expect(shortcut?.key == .space)
        #expect(shortcut?.modifiers == [.option, .shift])
    }

    @Test func speakDefaultsToOptionS() {
        #expect(KeyboardShortcuts.Name.speak.defaultShortcut?.key == .s)
        #expect(KeyboardShortcuts.Name.speak.defaultShortcut?.modifiers == [.option])
    }

    @Test func summarizeDefaultsToOptionM() {
        #expect(KeyboardShortcuts.Name.summarize.defaultShortcut?.key == .m)
        #expect(KeyboardShortcuts.Name.summarize.defaultShortcut?.modifiers == [.option])
    }

    @Test func refineSelectionHasNoDefaultShortcut() {
        #expect(KeyboardShortcuts.Name.refineSelection.defaultShortcut == nil)
    }

    @Test func displayNamesAreHumanReadable() {
        #expect(HotkeyAction.dictate.displayName == "Dictate")
        #expect(HotkeyAction.dictateAndRefine.displayName == "Dictate & Refine")
        #expect(HotkeyAction.speak.displayName == "Speak selection")
        #expect(HotkeyAction.summarize.displayName == "Summarize selection")
        #expect(HotkeyAction.refineSelection.displayName == "Refine selection")
    }
}

@Suite struct HotkeyEventTests {
    @Test func actionIsReadableFromBothCases() {
        #expect(HotkeyEvent.keyDown(.dictate).action == .dictate)
        #expect(HotkeyEvent.keyUp(.summarize).action == .summarize)
    }
}

@Suite struct HotkeyEnablementStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.hotkeys.\(UUID().uuidString)")!
    }

    @Test func actionsAreEnabledByDefault() {
        let store = HotkeyEnablementStore(defaults: makeDefaults())
        #expect(store.isEnabled(.dictate) == true)
    }

    @Test func disablingIsRemembered() {
        let defaults = makeDefaults()
        let store = HotkeyEnablementStore(defaults: defaults)
        store.setEnabled(.dictate, false)
        #expect(store.isEnabled(.dictate) == false)
        #expect(HotkeyEnablementStore(defaults: defaults).isEnabled(.dictate) == false)
        #expect(store.isEnabled(.speak) == true)
    }
}

@Suite struct FakeHotkeyServiceTests {
    @Test func sendDeliversEventsToTheStream() async {
        let service = FakeHotkeyService()
        var iterator = service.events.makeAsyncIterator()
        service.send(.keyDown(.dictate))
        service.send(.keyUp(.dictate))
        #expect(await iterator.next() == .keyDown(.dictate))
        #expect(await iterator.next() == .keyUp(.dictate))
        #expect(service.enabled[.dictate] == nil)
        service.setEnabled(.dictate, false)
        #expect(service.enabled[.dictate] == false)
    }
}
