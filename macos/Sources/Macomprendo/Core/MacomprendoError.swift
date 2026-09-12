import Foundation

enum PermissionKind: String, Sendable {
    case microphone
    case accessibility
}

/// Every failure a user can see. Adding a case means adding both strings below and a
/// row in `MacomprendoErrorTests`.
enum MacomprendoError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied(PermissionKind)
    case modelMissing(String)
    case modelDownloadFailed(String)
    case providerUnreachable(endpointName: String)
    case providerHTTP(status: Int, body: String)
    case providerStreamMalformed
    case audio(String)
    case audioPlayback(String)
    case audioEncoding(String)
    case speechKeyMissing
    case noSelection
    case insertFailed
    case dictationHistory(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied(.microphone):
            return "Macomprendo cannot use the microphone."
        case .permissionDenied(.accessibility):
            return "Macomprendo cannot read the selection or paste text."
        case .modelMissing(let id):
            return "The speech model \"\(id)\" is not downloaded."
        case .modelDownloadFailed(let reason):
            return "Downloading the speech model failed: \(reason)"
        case .providerUnreachable(let name):
            return "Could not reach \"\(name)\"."
        case .providerHTTP(let status, let body):
            return "The server replied with HTTP \(status): \(body)"
        case .providerStreamMalformed:
            return "The server sent a response Macomprendo could not read."
        case .audio(let reason):
            return "Recording failed: \(reason)"
        case .audioPlayback(let reason):
            return "Playing the speech audio failed: \(reason)"
        case .audioEncoding(let reason):
            return "Saving the recording failed: \(reason)"
        case .speechKeyMissing:
            return "No speech API key."
        case .noSelection:
            return "No text is selected."
        case .insertFailed:
            return "Macomprendo could not insert the text."
        case .dictationHistory(let reason):
            return "Dictation history is unavailable: \(reason)"
        case .cancelled:
            return "Cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied(.microphone):
            return "Open System Settings ▸ Privacy & Security ▸ Microphone and enable Macomprendo."
        case .permissionDenied(.accessibility):
            return "Open System Settings ▸ Privacy & Security ▸ Accessibility and enable Macomprendo."
        case .modelMissing:
            return "Open Settings ▸ Models and download it."
        case .modelDownloadFailed:
            return "Check your internet connection and try the download again."
        case .providerUnreachable:
            return "Start the server or choose another endpoint in Settings ▸ Providers."
        case .providerHTTP:
            return "Check the endpoint URL, model name and API key in Settings ▸ Providers."
        case .providerStreamMalformed:
            return "Try again, or pick a different model for this endpoint."
        case .audio:
            return "Check that an input device is connected and try again."
        case .audioPlayback:
            return "Check that an output device is connected and try again."
        case .audioEncoding:
            return "Check that the disk has free space and that Macomprendo can write to Application Support."
        case .speechKeyMissing:
            return "Add one in Settings ▸ Speech."
        case .noSelection:
            return "Select some text and press the shortcut again."
        case .insertFailed:
            return "The text is on the clipboard — paste it manually with ⌘V."
        case .dictationHistory:
            return "Open Dictation History and clear it, or check that Macomprendo can write to Application Support."
        case .cancelled:
            return nil
        }
    }
}
