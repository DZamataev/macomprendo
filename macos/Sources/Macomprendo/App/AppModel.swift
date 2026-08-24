import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings {
        didSet { persist() }
    }

    let keychain: any KeychainStoring
    private let store: any SettingsPersisting

    init(store: any SettingsPersisting, keychain: any KeychainStoring) {
        self.store = store
        self.keychain = keychain
        if let data = store.load() {
            do {
                settings = try Settings.migrate(data)
            } catch {
                Log.app.error("Settings could not be read, falling back to defaults: \(error.localizedDescription, privacy: .public)")
                settings = .default
            }
        } else {
            settings = .default
            persist()
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            store.save(try encoder.encode(settings))
        } catch {
            Log.app.error("Settings could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
