import Foundation

/// One place that turns any error into the sentence the HUD, panels and settings show.
enum ErrorText {
    static func describe(_ error: Error) -> String {
        if let error = error as? MacomprendoError {
            return [error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return error.localizedDescription
    }
}
