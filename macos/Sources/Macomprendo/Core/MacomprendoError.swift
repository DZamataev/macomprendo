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
    case audioFileMissing
    case audioEncoding(String)
    case speechKeyMissing
    case noSelection
    case insertFailed
    case dictationHistory(String)
    case glossary(String)
    case glossaryPackNameInvalid(String)
    case glossaryPackNameTaken(String)
    case licenseTextMissing(String)
    case licenseTextUnreadable(String)
    case silentCapture
    case mediaUnreadable(String)
    case noAudioTrack
    case noSpeechFound
    case sourceFileUnavailable
    case transcriptStore(String)
    case speechDetector(String)
    case exportFailed(String)
    case systemAudioCaptureFailed(String)
    case callRecordingLocationUnavailable
    case callRecordingWriteFailed(String)
    case callRecordingUnavailable
    case transcriptPlaybackUnavailable(String)
    /// Deleting a transcript together with its source, the source would not go to the Trash.
    case sourceNotMovedToTrash(String)
    /// A finished call's `.srt` could not be written into its recording folder.
    case callSubtitlesNotSaved(String)
    /// A finished call's other participants could not be told apart; its far side stays
    /// labelled `Others`.
    case speakersNotIdentified(String)
    /// A transcript's notes file exists but cannot be read as text.
    case notesUnreadable(String)
    /// A transcript's notes could not be written (or an emptied notes file removed).
    case notesNotSaved(String)
    /// The transcript and its source were deleted, but the notes file stayed where it was.
    case notesNotMovedToTrash(String)
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
        case .audioFileMissing:
            return "The saved recording is no longer on disk."
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
        case .glossary(let reason):
            return "The glossary folder could not be changed: \(reason)"
        case .glossaryPackNameInvalid(let name):
            return "\"\(name)\" is not a usable pack name."
        case .glossaryPackNameTaken(let name):
            return "A pack called \"\(name)\" already exists."
        case .licenseTextMissing(let component):
            return "The licence text for \"\(component)\" is missing from this build."
        case .licenseTextUnreadable(let component):
            return "The licence text for \"\(component)\" is bundled but could not be read."
        case .silentCapture:
            return "No sound was captured."
        case .mediaUnreadable(let reason):
            return "Macomprendo cannot read this file: \(reason)"
        case .noAudioTrack:
            return "This file has no audio track."
        case .noSpeechFound:
            return "No speech was found in this file."
        case .sourceFileUnavailable:
            return "The original file can no longer be found."
        case .transcriptStore(let reason):
            return "Transcripts are unavailable: \(reason)"
        case .speechDetector(let reason):
            return "The speech detector could not start: \(reason)"
        case .exportFailed(let reason):
            return "The transcript could not be saved: \(reason)"
        case .systemAudioCaptureFailed(let reason):
            return "System audio could not be recorded (\(reason))."
        case .callRecordingLocationUnavailable:
            return "The call recordings folder cannot be written."
        case .callRecordingWriteFailed(let reason):
            return "The call recording stopped because a file could not be written (\(reason))."
        case .callRecordingUnavailable:
            return "The call recording cannot be found."
        case .sourceNotMovedToTrash(let reason):
            return "The source could not be moved to the Trash (\(reason)). The transcript was kept."
        case .transcriptPlaybackUnavailable(let reason):
            return "Can't play this transcript's audio: \(reason)."
        case .callSubtitlesNotSaved(let reason):
            return "The call's subtitles could not be saved (\(reason)). The transcript is ready."
        case .speakersNotIdentified(let reason):
            return "The other speakers could not be told apart (\(reason)). The transcript is ready, labelled Others."
        case .notesUnreadable(let reason):
            return "The notes file could not be read (\(reason))."
        case .notesNotSaved(let reason):
            return "The notes could not be saved (\(reason))."
        case .notesNotMovedToTrash(let reason):
            return "The transcript and its source were moved to the Trash, but the notes file could not be (\(reason))."
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
        case .audioFileMissing:
            return "It was deleted outside Macomprendo, or by Delete saved audio. The transcript is kept."
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
        case .glossary:
            return "Check that the disk has free space and that Macomprendo can write to Application Support, then use Reload."
        case .glossaryPackNameInvalid:
            return "Give the pack a name that is not empty and contains no “/” or “:”."
        case .glossaryPackNameTaken:
            return "Pick another name, or edit the existing pack instead."
        case .licenseTextMissing:
            return "Read it at the component's homepage, or in macos/Sources/Macomprendo/Resources/Licenses in the project source."
        case .licenseTextUnreadable:
            return "Read it at the component's homepage, or in macos/Sources/Macomprendo/Resources/Licenses in the project source."
        case .silentCapture:
            return "The microphone produced silence for the whole recording. Check that the right input device is selected and that no other app has taken it."
        case .mediaUnreadable:
            return "Check that the file opens in QuickTime Player. Files protected by DRM cannot be transcribed."
        case .noAudioTrack:
            return "Choose a recording or a video that has sound."
        case .noSpeechFound:
            return "The file contains only silence, music or noise. Check that it is the right file."
        case .sourceFileUnavailable:
            return "Choose the file again to continue transcribing it."
        case .transcriptStore:
            return "Check that the disk has free space and that Macomprendo can write to Application Support."
        case .speechDetector:
            return "Reinstall Macomprendo: the bundled speech detector model is missing or damaged."
        case .exportFailed:
            return "Choose another folder, or check that the disk has free space."
        case .systemAudioCaptureFailed:
            return "Check System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then start the recording again."
        case .callRecordingLocationUnavailable:
            return "Choose another folder in Settings ▸ General ▸ Call recordings."
        case .callRecordingWriteFailed:
            return "Free some disk space or choose another folder in Settings ▸ General. What was recorded so far is kept."
        case .callRecordingUnavailable:
            return "Choose the recording's folder again, or restore it from the Trash."
        case .sourceNotMovedToTrash:
            return "Delete the transcript without its source, or move the file to the Trash yourself."
        case .transcriptPlaybackUnavailable:
            return "If the file or the recording folder moved, choose it again with Choose File… or Choose Folder…."
        case .callSubtitlesNotSaved:
            return "Check that the recording folder still exists and the disk has free space, or use Export ▸ Subtitles (.srt)."
        case .speakersNotIdentified:
            return "Download the speaker models again in Settings ▸ General ▸ Call recordings, then choose Transcribe Again."
        case .notesUnreadable:
            return "Open the .notes.txt file in a text editor and save it as plain UTF-8 text. Macomprendo will not change it until then."
        case .notesNotMovedToTrash:
            return "Move the .notes.txt file next to the source to the Trash yourself."
        case .notesNotSaved:
            return "Check that the recording folder or the source file's folder still exists and can be written. Your text is kept while the window stays open."
        case .cancelled:
            return nil
        }
    }
}
