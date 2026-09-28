import Combine
import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct MicrophonePickerModelTests {
    private func model(_ settings: Settings = .default,
                       devices: FakeAudioInputDevices) -> MicrophonePickerModel {
        MicrophonePickerModel(holder: ScriptedSettingsHolder(settings), devices: devices)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func theSystemDefaultComesFirstAndNamesTheDeviceItCurrentlyMeans() {
        let picker = model(devices: FakeAudioInputDevices([.builtIn, .mchose],
                                                          defaultUID: AudioInputDevice.mchose.uid))
        #expect(picker.options.map(\.title) == [
            "System default (MCHOSE V9)",
            "MacBook Pro Microphone",
            "MCHOSE V9"
        ])
        #expect(picker.options.first?.uid == nil)
        #expect(picker.selection == nil)
    }

    @Test func withNoDevicesTheDefaultRowSaysSo() {
        let picker = model(devices: FakeAudioInputDevices([]))
        #expect(picker.options.map(\.title) == ["System default (no input device)"])
    }

    @Test func choosingADeviceStoresItsUID() {
        let picker = model(devices: FakeAudioInputDevices([.builtIn, .mchose]))
        picker.selection = AudioInputDevice.builtIn.uid
        #expect(picker.holder.settings.preferredInputDeviceUID == AudioInputDevice.builtIn.uid)
        picker.selection = nil
        #expect(picker.holder.settings.preferredInputDeviceUID == nil)
    }

    /// The choice is kept rather than silently reset to Default: a headset that is merely
    /// switched off comes back, and the user's selection must still be there when it does.
    @Test func aDisconnectedChoiceStaysListedAndSelected() {
        var settings = Settings.default
        settings.preferredInputDeviceUID = AudioInputDevice.mchose.uid
        settings.preferredInputDeviceName = AudioInputDevice.mchose.name
        let picker = model(settings, devices: FakeAudioInputDevices([.builtIn]))
        #expect(picker.options.map(\.title) == [
            "System default (MacBook Pro Microphone)",
            "MacBook Pro Microphone",
            "MCHOSE V9 — not connected"
        ])
        #expect(picker.selection == AudioInputDevice.mchose.uid)
        #expect(picker.caption == "MCHOSE V9 is not connected. Dictation uses the system default, "
            + "MacBook Pro Microphone, until it is back.")
    }

    @Test func choosingADeviceRemembersItsNameForWhenItIsGone() {
        let picker = model(devices: FakeAudioInputDevices([.builtIn, .mchose]))
        picker.selection = AudioInputDevice.mchose.uid
        #expect(picker.holder.settings.preferredInputDeviceName == AudioInputDevice.mchose.name)
    }

    @Test func aConnectedChoiceHasNoCaption() {
        var settings = Settings.default
        settings.preferredInputDeviceUID = AudioInputDevice.builtIn.uid
        let picker = model(settings, devices: FakeAudioInputDevices([.builtIn]))
        #expect(picker.caption == nil)
    }

    @Test func pluggingADeviceInUpdatesTheList() async {
        let devices = FakeAudioInputDevices([.builtIn])
        let picker = model(devices: devices)
        picker.startObserving()
        devices.devices = [.builtIn, .mchose]
        devices.emitChange()
        #expect(await eventually { picker.options.count == 3 })
        picker.stopObserving()
    }

    @Test func writingTheSameChoicePublishesNothing() {
        var settings = Settings.default
        settings.preferredInputDeviceUID = AudioInputDevice.builtIn.uid
        let picker = model(settings, devices: FakeAudioInputDevices([.builtIn]))
        var emissions = 0
        let cancellable = picker.objectWillChange.sink { emissions += 1 }
        picker.selection = AudioInputDevice.builtIn.uid
        #expect(emissions == 0)
        picker.selection = nil
        #expect(emissions == 1)
        cancellable.cancel()
    }
}
