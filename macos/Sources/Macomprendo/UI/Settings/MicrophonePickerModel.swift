import Combine
import Foundation
import SwiftUI

/// One row of the microphone picker. `uid == nil` is the system-default row.
struct MicrophoneOption: Identifiable, Equatable, Sendable {
    let uid: String?
    let title: String

    var id: String { uid ?? "" }
}

/// The microphone picker in Settings ▸ General ▸ Microphone. Lists the connected input
/// devices live, behind a "System default" row that names the device it currently means,
/// and keeps a chosen-but-disconnected device listed — a switched-off headset comes back,
/// and silently resetting the user's choice to the default is worse than showing it with
/// its problem.
///
/// One instance per surface (Settings, the menubar panel); each owns its own device
/// observation, so closing either never stops the other's updates. They share only the
/// holder and the device service, which is why a write through one is announced to the
/// other through `settingsChanges`.
@MainActor
final class MicrophonePickerModel: ObservableObject {
    let holder: any SettingsHolding
    private let devices: any AudioInputDeviceListing
    @Published private(set) var connected: [AudioInputDevice] = []
    @Published private(set) var systemDefault: AudioInputDevice?
    private var observation: Task<Void, Never>?
    private var settingsCancellable: AnyCancellable?
    /// The persisted microphone fields as this surface last saw them. A write from the other
    /// surface arrives as an opaque new `Settings`; comparing against this is what separates a
    /// real microphone change from the rest of a settings write, so unrelated writes are silent.
    private var lastSeenChoice: Choice

    private struct Choice: Equatable {
        let uid: String?
        let name: String?

        init(_ settings: Settings) {
            uid = settings.preferredInputDeviceUID
            name = settings.preferredInputDeviceName
        }
    }

    /// `settingsChanges` carries every write to the holder's settings (in `AppModel`,
    /// `$settings`). Defaults to a silent publisher for callers with no other surface to sync
    /// with.
    init(holder: any SettingsHolding,
         devices: any AudioInputDeviceListing,
         settingsChanges: AnyPublisher<Settings, Never> = Empty().eraseToAnyPublisher()) {
        self.holder = holder
        self.devices = devices
        self.lastSeenChoice = Choice(holder.settings)
        reload()
        settingsCancellable = settingsChanges.sink { [weak self] settings in
            self?.settingsDidChange(to: settings)
        }
    }

    /// Republishes only when the microphone choice actually moved, so a settings write about
    /// anything else leaves the picker (and the view drawing it) alone.
    private func settingsDidChange(to settings: Settings) {
        let choice = Choice(settings)
        guard choice != lastSeenChoice else { return }
        lastSeenChoice = choice
        objectWillChange.send()
    }

    /// Re-reads the device list. Called on every Core Audio change while observing.
    func reload() {
        connected = devices.inputDevices()
        systemDefault = devices.defaultInputDevice()
    }

    /// Starts following device changes. Paired with `stopObserving()` from the view's
    /// lifetime so a closed Settings window holds no listener.
    func startObserving() {
        guard observation == nil else { return }
        reload()
        let changes = devices.changes()
        observation = Task { [weak self] in
            for await _ in changes {
                self?.reload()
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    var options: [MicrophoneOption] {
        var options = [MicrophoneOption(uid: nil, title: Self.defaultTitle(systemDefault))]
        options += connected.map { MicrophoneOption(uid: $0.uid, title: $0.name) }
        if let missing = missingChoiceName {
            options.append(MicrophoneOption(uid: holder.settings.preferredInputDeviceUID,
                                            title: "\(missing) — not connected"))
        }
        return options
    }

    var selection: String? {
        get { holder.settings.preferredInputDeviceUID }
        set {
            guard newValue != holder.settings.preferredInputDeviceUID else { return }
            // `settings` lives on the holder, not here: without this the picker would keep
            // drawing the old choice (see the swiftui-macos-ui skill).
            objectWillChange.send()
            let name: String?
            if let newValue, let device = connected.first(where: { $0.uid == newValue }) {
                name = device.name
            } else if newValue == nil {
                name = nil
            } else {
                // A disconnected pick keeps the name it was remembered under.
                name = holder.settings.preferredInputDeviceName
            }
            // UID and name go in one assignment: two writes would announce two microphone
            // changes and make the other surface republish twice for a single pick.
            var updated = holder.settings
            updated.preferredInputDeviceUID = newValue
            updated.preferredInputDeviceName = name
            // Claim this choice before the write, so our own subscription sees the echo as
            // already-known instead of republishing it.
            lastSeenChoice = Choice(updated)
            holder.settings = updated
        }
    }

    /// Explains a disconnected choice; `nil` when the choice is connected or is the default.
    var caption: String? {
        guard let missing = missingChoiceName else { return nil }
        let fallback = systemDefault.map { ", \($0.name)," } ?? ""
        return "\(missing) is not connected. Dictation uses the system default\(fallback) "
            + "until it is back."
    }

    /// The chosen device's name when it is chosen but not connected.
    private var missingChoiceName: String? {
        guard let uid = holder.settings.preferredInputDeviceUID,
              !connected.contains(where: { $0.uid == uid }) else { return nil }
        return holder.settings.preferredInputDeviceName ?? uid
    }

    nonisolated static func defaultTitle(_ device: AudioInputDevice?) -> String {
        "System default (\(device?.name ?? "no input device"))"
    }
}
