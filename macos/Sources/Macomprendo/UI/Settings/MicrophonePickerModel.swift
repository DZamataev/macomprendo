import Foundation
import SwiftUI

/// One row of the microphone picker. `uid == nil` is the system-default row.
struct MicrophoneOption: Identifiable, Equatable, Sendable {
    let uid: String?
    let title: String

    var id: String { uid ?? "" }
}

/// The microphone picker in Settings ▸ Dictation ▸ Recording. Lists the connected input
/// devices live, behind a "System default" row that names the device it currently means,
/// and keeps a chosen-but-disconnected device listed — a switched-off headset comes back,
/// and silently resetting the user's choice to the default is worse than showing it with
/// its problem.
@MainActor
final class MicrophonePickerModel: ObservableObject {
    let holder: any SettingsHolding
    private let devices: any AudioInputDeviceListing
    @Published private(set) var connected: [AudioInputDevice] = []
    @Published private(set) var systemDefault: AudioInputDevice?
    private var observation: Task<Void, Never>?

    init(holder: any SettingsHolding, devices: any AudioInputDeviceListing) {
        self.holder = holder
        self.devices = devices
        reload()
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
            holder.settings.preferredInputDeviceUID = newValue
            if let newValue, let device = connected.first(where: { $0.uid == newValue }) {
                holder.settings.preferredInputDeviceName = device.name
            } else if newValue == nil {
                holder.settings.preferredInputDeviceName = nil
            }
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
