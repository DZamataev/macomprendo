import Combine
import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct MicrophonePickerModelTests {
    private func model(_ settings: Settings = .default,
                       devices: FakeAudioInputDevices) -> MicrophonePickerModel {
        MicrophonePickerModel(holder: ScriptedSettingsHolder(settings), devices: devices)
    }

    /// A surface's picker over a shared holder and device list, wired like `AppModel` wires it:
    /// it hears about microphone writes made through the other surface.
    private func surfaceModel(_ holder: ScriptedSettingsHolder,
                              devices: FakeAudioInputDevices) -> MicrophonePickerModel {
        MicrophonePickerModel(holder: holder,
                              devices: devices,
                              settingsChanges: holder.settingsChanges.eraseToAnyPublisher())
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

    // MARK: - Two surfaces over one holder

    /// Settings and the panel each keep the device list live. Closing one surface must not
    /// stop the other's updates, so each owns its own observation task over the same service.
    @Test func closingOneSurfaceLeavesTheOtherObserving() async {
        let holder = ScriptedSettingsHolder()
        let devices = FakeAudioInputDevices([.builtIn])
        let settings = surfaceModel(holder, devices: devices)
        let panel = surfaceModel(holder, devices: devices)
        settings.startObserving()
        panel.startObserving()

        settings.stopObserving()
        devices.devices = [.builtIn, .mchose]
        devices.emitChange()

        #expect(await eventually { panel.options.count == 3 })
        panel.stopObserving()
    }

    /// The panel writes the microphone choice through its own picker; Settings has to redraw,
    /// and exactly once, without the write churning on an intermediate state.
    @Test func aWriteThroughOneSurfaceRepublishesTheOtherExactlyOnce() {
        let holder = ScriptedSettingsHolder()
        let devices = FakeAudioInputDevices([.builtIn, .mchose])
        let settings = surfaceModel(holder, devices: devices)
        let panel = surfaceModel(holder, devices: devices)
        var emissions = 0
        let cancellable = panel.objectWillChange.sink { emissions += 1 }

        settings.selection = AudioInputDevice.mchose.uid

        #expect(emissions == 1)
        #expect(panel.selection == AudioInputDevice.mchose.uid)
        cancellable.cancel()
    }

    /// A settings write that touched nothing about the microphone must not churn either picker.
    @Test func anUnrelatedSettingsWriteRepublishesNothing() {
        let holder = ScriptedSettingsHolder()
        let devices = FakeAudioInputDevices([.builtIn])
        let panel = surfaceModel(holder, devices: devices)
        var emissions = 0
        let cancellable = panel.objectWillChange.sink { emissions += 1 }

        holder.settings.maximumRecordingSeconds = 120

        #expect(emissions == 0)
        cancellable.cancel()
    }

    /// A chosen-but-disconnected headset reads the same on both surfaces — the choice kept,
    /// the fallback explained.
    @Test func bothSurfacesShowADisconnectedChoiceTheSameWay() {
        var settings = Settings.default
        settings.preferredInputDeviceUID = AudioInputDevice.mchose.uid
        settings.preferredInputDeviceName = AudioInputDevice.mchose.name
        let holder = ScriptedSettingsHolder(settings)
        let devices = FakeAudioInputDevices([.builtIn])
        let settingsSurface = surfaceModel(holder, devices: devices)
        let panel = surfaceModel(holder, devices: devices)

        #expect(panel.options == settingsSurface.options)
        #expect(panel.options.last?.title == "MCHOSE V9 — not connected")
        #expect(panel.caption == settingsSurface.caption)
        #expect(panel.selection == AudioInputDevice.mchose.uid)
    }
}
