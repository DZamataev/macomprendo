import Combine
import Foundation
@testable import Macomprendo

@MainActor final class ScriptedSettingsHolder: SettingsHolding {
    /// Announces every assignment to `settings`, standing in for `AppModel`'s `$settings`:
    /// a view model that reads the holder from the outside learns about foreign writes here.
    let settingsChanges = PassthroughSubject<Settings, Never>()

    var settings: Settings {
        didSet { settingsChanges.send(settings) }
    }

    init(_ settings: Settings = .default) {
        self.settings = settings
    }

    /// `Settings.default` with the factory presets already seeded.
    static func seeded() -> ScriptedSettingsHolder {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        return ScriptedSettingsHolder(s)
    }
}
