import AppKit
import Foundation

struct FrontmostApp: Sendable, Equatable {
    var pid: pid_t
    var bundleID: String?
    var name: String
}

protocol FrontmostAppTracking: Sendable {
    /// The app that is frontmost right now — captured when the hotkey fires.
    func capture() -> FrontmostApp?
    /// Brings `app` back to the front; returns false if it did not become frontmost in time.
    func activate(_ app: FrontmostApp) async -> Bool
}

/// Polls `isActive` until it is true or `timeout` elapses. Injected `sleep` keeps it unit-testable.
enum ActivationPoller {
    static func wait(timeout: TimeInterval,
                     interval: TimeInterval,
                     isActive: @Sendable () -> Bool,
                     sleep: @Sendable (TimeInterval) async -> Void) async -> Bool {
        if isActive() { return true }
        var waited: TimeInterval = 0
        while waited < timeout {
            await sleep(interval)
            waited += interval
            if isActive() { return true }
        }
        return false
    }
}

struct NSWorkspaceTracker: FrontmostAppTracking {
    var activationTimeout: TimeInterval = 0.5
    var pollInterval: TimeInterval = 0.025

    init(activationTimeout: TimeInterval = 0.5, pollInterval: TimeInterval = 0.025) {
        self.activationTimeout = activationTimeout
        self.pollInterval = pollInterval
    }

    func capture() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(pid: app.processIdentifier,
                            bundleID: app.bundleIdentifier,
                            name: app.localizedName ?? "")
    }

    func activate(_ app: FrontmostApp) async -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        let pid = app.pid
        let isActive: @Sendable () -> Bool = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        if isActive() { return true }
        // `.activateIgnoringOtherApps` is deprecated and a no-op as of macOS 14 — the deployment
        // target — since `activate()` now always brings the app forward regardless of other apps.
        running.activate()
        return await ActivationPoller.wait(
            timeout: activationTimeout,
            interval: pollInterval,
            isActive: isActive,
            sleep: { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            })
    }
}
