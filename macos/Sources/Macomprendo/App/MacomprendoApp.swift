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
    private let isAppActive: @MainActor () -> Bool
    private let now: () -> Date
    private var becameActiveAt: Date?

    override convenience init() {
        self.init(model: AppRoot.model,
                  replyToTermination: { NSApp.reply(toApplicationShouldTerminate: $0) })
    }

    init(model: AppModel, replyToTermination: @escaping @MainActor (Bool) -> Void,
         isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         now: @escaping () -> Date = { Date() }) {
        self.model = model
        self.replyToTermination = replyToTermination
        self.isAppActive = isAppActive
        self.now = now
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

    /// The status item is the app's permanent surface and launch shows no window at all;
    /// closing the last window (Settings) must leave the app running (spec §7).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening the running app again; `false` keeps AppKit from opening a window of its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // The reopening click activates the app just before this arrives, so an activation
        // that recent means the app was in the background a moment ago.
        // shortcut: a 0.5 s window on activation order, revisit if a slow reopen is misread.
        let justActivated = becameActiveAt.map { now().timeIntervalSince($0) < 0.5 } ?? false
        model.reopen(wasActive: isAppActive() && !justActivated)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        becameActiveAt = now()
    }
}

@main
struct MacomprendoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppRoot.model

    var body: some Scene {
        // The first scene is deliberately a hidden extra: without a `MenuBarExtra`, SwiftUI
        // opens the first `Settings`/`Window` scene at launch, and the hidden one keeps
        // launch window-free (spike, spec §7). The real status item is app-owned —
        // `StatusItemController`, built from `AppModel.start()` — so no icon comes from
        // here; this scene only creates a zero-height status window.
        MenuBarExtra("Macomprendo", isInserted: .constant(false)) {
            EmptyView()
        }

        // `Settings` alone would resolve to our own Core type, so qualify the scene.
        SwiftUI.Settings {
            SettingsView()
                .environmentObject(model)
                .onAppear { model.dockIcon.open(.settings) }
                .onDisappear { model.dockIcon.close(.settings) }
        }

        Window("Dictation History", id: WindowID.dictationHistory) {
            DictationHistoryView(controller: model.history) { text in
                model.textFeatures?.refine(text: text)
            }
                .onAppear {
                    model.dockIcon.open(.history)
                    Task { await model.history.loadInitial() }
                }
                .onDisappear {
                    model.history.cancelLoading()
                    model.history.stopPlayback()
                    model.dockIcon.close(.history)
                }
        }
        .defaultSize(width: 720, height: 560)

        Window("Transcripts", id: WindowID.transcripts) {
            TranscriptsView(library: model.transcriptLibrary,
                            transcription: model.fileTranscription,
                            playback: model.transcriptPlayback,
                            notes: model.transcriptNotes)
                .environmentObject(model)
                .onAppear { model.dockIcon.open(.transcripts) }
                .onDisappear {
                    model.transcriptPlayback.stop()
                    model.dockIcon.close(.transcripts)
                }
        }
        .defaultSize(width: 880, height: 620)

        Window("About Macomprendo", id: WindowID.about) {
            AboutView(model: model.aboutModel)
                .onAppear { model.dockIcon.open(.about) }
                .onDisappear { model.dockIcon.close(.about) }
        }
        .defaultSize(width: 820, height: 620)
    }
}
