import AppKit
import SwiftUI

/// Single, main-actor-isolated instance shared by the SwiftUI scenes and the app delegate.
@MainActor
enum AppRoot {
    static let model = AppModel(store: UserDefaultsSettingsStore(),
                                keychain: SystemKeychainStore(),
                                env: .live())
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let replyToTermination: @MainActor (Bool) -> Void

    override convenience init() {
        self.init(model: AppRoot.model,
                  replyToTermination: { NSApp.reply(toApplicationShouldTerminate: $0) })
    }

    init(model: AppModel, replyToTermination: @escaping @MainActor (Bool) -> Void) {
        self.model = model
        self.replyToTermination = replyToTermination
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        OnboardingWindowController.showIfNeeded(model: model)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { [model, replyToTermination] in
            await model.shutdown()
            replyToTermination(true)
        }
        return .terminateLater
    }
}

@main
struct MacomprendoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppRoot.model

    var body: some Scene {
        // The status item is deliberately an SF Symbol template image (spec §2, §3.5).
        // `AppIcon` raw values are SVG file names and must not be used here.
        MenuBarExtra("Macomprendo", systemImage: "waveform") {
            MenuBarView(dictation: model.dictationTabModel, models: model.modelsViewModel)
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)

        // `Settings` alone would resolve to our own Core type, so qualify the scene.
        SwiftUI.Settings {
            SettingsView()
                .environmentObject(model)
                .onAppear { model.dockIcon.open(.settings) }
                .onDisappear { model.dockIcon.close(.settings) }
        }

        Window("Dictation History", id: "dictation-history") {
            DictationHistoryView(controller: model.history) { text in
                model.textFeatures?.refine(text: text)
            }
                .onAppear {
                    model.dockIcon.open(.history)
                    Task { await model.history.loadInitial() }
                }
                .onDisappear {
                    model.history.cancelLoading()
                    model.dockIcon.close(.history)
                }
        }
        .defaultSize(width: 720, height: 560)
    }
}
