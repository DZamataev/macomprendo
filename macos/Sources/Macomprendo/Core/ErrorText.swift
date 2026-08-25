import Foundation

/// Turns any error into the one-line text shown in a toast or the panel's error banner.
enum ErrorText {
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        if let localized = error as? LocalizedError {
            let parts = [localized.errorDescription, localized.recoverySuggestion].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return error.localizedDescription
    }
}
