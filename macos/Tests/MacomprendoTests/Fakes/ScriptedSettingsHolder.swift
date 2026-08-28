import Foundation
@testable import Macomprendo

@MainActor final class ScriptedSettingsHolder: SettingsHolding {
    var settings: Settings

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
