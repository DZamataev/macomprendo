import AppKit
import ApplicationServices
import AVFoundation
import Foundation

enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

protocol PermissionsChecking: Sendable {
    func status(of kind: PermissionKind) async -> PermissionStatus
    /// Shows the system prompt when one is still available, then reports the resulting status.
    func request(_ kind: PermissionKind) async -> PermissionStatus
    func openSystemSettings(for kind: PermissionKind)
}

enum PrivacyPane {
    static func url(for kind: PermissionKind) -> URL {
        switch kind {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

struct SystemPermissions: PermissionsChecking {
    func status(of kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .undetermined
            default: .denied
            }
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .accessibility:
            // `kAXTrustedCheckOptionPrompt` is imported as a mutable global
            // `Unmanaged<CFString>`, which Swift 6 strict concurrency flags as a data
            // race even though the underlying C constant never changes. Its value is
            // the stable, documented ABI string "AXTrustedCheckOptionPrompt", so we use
            // the literal directly rather than touching the global.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        }
    }

    func openSystemSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(PrivacyPane.url(for: kind))
    }
}
