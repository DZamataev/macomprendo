import Foundation
@testable import Macomprendo

/// Mutable settings for controller tests; stands in for `AppModel.settings`.
@MainActor
final class SettingsHolder {
    var value: Settings = .default
}
