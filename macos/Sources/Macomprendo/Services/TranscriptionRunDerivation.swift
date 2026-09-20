import Foundation

/// Deriving what produced a transcript from the settings that chose the provider. Lives in
/// Services, beside `ModelCatalog`, because that is the only thing it needs: `TranscriptionRun`
/// itself stays in Core, and the controllers call this rather than growing a catalog
/// dependency of their own.
extension TranscriptionRun {

    /// Used when the bundle carries no version — a `swift test` run, where `.module` has no
    /// `CFBundleShortVersionString`. Never empty, so a row always says something about the
    /// build that wrote it.
    static let unknownAppVersion = "unknown"

    /// `CFBundleShortVersionString` of the running build.
    static var currentAppVersion: String {
        let value = ResourceBundle.current.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let value, !value.isEmpty else { return unknownAppVersion }
        return value
    }

    /// Pure, so it is unit-testable without a recogniser. A local model id the catalog does not
    /// know still records the id: which model ran matters more than which runtime opened it.
    static func from(_ source: TranscriptionSource,
                     language: String?,
                     appVersion: String = TranscriptionRun.currentAppVersion) -> TranscriptionRun {
        // "" and "   " mean the same thing as nil here — automatic detection — and storing
        // them would make the corpus unable to tell "auto" from "not recorded".
        let requestedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedLanguage = (requestedLanguage?.isEmpty ?? true) ? nil : requestedLanguage

        switch source {
        case let .local(modelID):
            return TranscriptionRun(modelID: modelID,
                                    engine: ModelCatalog.model(id: modelID)?.engine.rawValue,
                                    language: normalisedLanguage,
                                    appVersion: appVersion)
        case let .endpoint(_, model):
            // The endpoint's identifier is deliberately not stored: it is a local UUID that
            // says nothing about what ran, and the configured model name does.
            return TranscriptionRun(modelID: model,
                                    engine: "endpoint",
                                    language: normalisedLanguage,
                                    appVersion: appVersion)
        }
    }
}
