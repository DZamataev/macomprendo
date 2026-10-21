import Foundation

/// A process as Core Audio's process-object list reports it, read by `CoreAudioProcessMonitor`.
struct AudioProcessActivity: Sendable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// An entry in the user's call-app list. `matches` and `activeCall` are pure so both `Settings`
/// and the matcher need nothing above Core.
struct CallApp: Codable, Sendable, Equatable, Identifiable {
    /// An app's own process using the microphone is a call. A browser holds the microphone for
    /// dictation sites and voice notes too, so it needs output as well.
    enum Kind: String, Codable, Sendable, CaseIterable { case app, browser }

    var name: String
    var bundleIDPrefix: String
    var kind: Kind

    var id: String { bundleIDPrefix }

    static let defaults: [CallApp] = [
        CallApp(name: "Zoom", bundleIDPrefix: "us.zoom.xos", kind: .app),
        CallApp(name: "Microsoft Teams", bundleIDPrefix: "com.microsoft.teams2", kind: .app),
        CallApp(name: "Microsoft Teams (classic)", bundleIDPrefix: "com.microsoft.teams",
                kind: .app),
        CallApp(name: "FaceTime", bundleIDPrefix: "com.apple.FaceTime", kind: .app),
        CallApp(name: "Slack", bundleIDPrefix: "com.tinyspeck.slackmacgap", kind: .app),
        CallApp(name: "Webex", bundleIDPrefix: "Cisco-Systems.Spark", kind: .app),
        CallApp(name: "Telegram", bundleIDPrefix: "ru.keepcoder.Telegram", kind: .app),
        CallApp(name: "Telegram Desktop", bundleIDPrefix: "org.telegram.desktop", kind: .app),
        CallApp(name: "WhatsApp", bundleIDPrefix: "net.whatsapp.WhatsApp", kind: .app),
        CallApp(name: "Discord", bundleIDPrefix: "com.hnc.Discord", kind: .app),
        // Browser helpers carry the prefix as a dotted suffix, e.g.
        // `com.google.Chrome.helper` and `com.apple.WebKit.GPU`.
        CallApp(name: "Google Chrome", bundleIDPrefix: "com.google.Chrome", kind: .browser),
        CallApp(name: "Safari", bundleIDPrefix: "com.apple.WebKit.GPU", kind: .browser),
        CallApp(name: "Arc", bundleIDPrefix: "company.thebrowser.Browser", kind: .browser),
        CallApp(name: "Microsoft Edge", bundleIDPrefix: "com.microsoft.edgemac", kind: .browser),
        CallApp(name: "Firefox", bundleIDPrefix: "org.mozilla.firefox", kind: .browser),
        CallApp(name: "Brave", bundleIDPrefix: "com.brave.Browser", kind: .browser),
        CallApp(name: "Yandex Browser", bundleIDPrefix: "ru.yandex.desktop.yandex-browser",
                kind: .browser),
    ]

    /// True when `bundleID` equals the prefix or continues it after a `.` — so
    /// `com.microsoft.teams` does not cover `com.microsoft.teams2`.
    func matches(bundleID: String) -> Bool {
        bundleID == bundleIDPrefix || bundleID.hasPrefix(bundleIDPrefix + ".")
    }

    /// The first app in `apps` that is in a call, per the App / Browser rules.
    static func activeCall(in processes: [AudioProcessActivity], apps: [CallApp],
                           excludingPID: pid_t) -> CallApp? {
        apps.first { app in
            let matching = app.processes(in: processes, excludingPID: excludingPID)
            switch app.kind {
            case .app:
                return matching.contains(where: \.isRunningInput)
            case .browser:
                return matching.contains(where: \.isRunningInput)
                    && matching.contains(where: \.isRunningOutput)
            }
        }
    }

    /// What each listed app is doing with audio, for the detector's log: app names and two
    /// flags, nothing anyone said.
    static func audioSummary(of processes: [AudioProcessActivity], apps: [CallApp],
                             excludingPID: pid_t) -> String {
        let lines = apps.compactMap { app -> String? in
            let matching = app.processes(in: processes, excludingPID: excludingPID)
            let input = matching.contains(where: \.isRunningInput)
            let output = matching.contains(where: \.isRunningOutput)
            guard input || output else { return nil }
            return "\(app.name): microphone \(input ? "on" : "off"), output \(output ? "on" : "off")"
        }
        return lines.isEmpty ? "no listed app is using audio" : lines.joined(separator: "; ")
    }

    private func processes(in processes: [AudioProcessActivity],
                           excludingPID: pid_t) -> [AudioProcessActivity] {
        processes.filter { process in
            process.pid != excludingPID && (process.bundleID.map(matches(bundleID:)) ?? false)
        }
    }
}
