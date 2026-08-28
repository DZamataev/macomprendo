import AppKit
import SwiftUI

/// Keeps the Dock icon alive for as long as the wizard's window is on screen. An `NSWindow`
/// does not retain its delegate, so the controller holds it.
@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

/// The onboarding window. `LSUIElement` apps have no Dock icon, so the window is created
/// programmatically and the app is activated so it comes to the front.
@MainActor
enum OnboardingWindowController {
    private static var window: NSWindow?
    private static var viewModel: OnboardingViewModel?
    private static var delegate: OnboardingWindowDelegate?

    static func showIfNeeded(model: AppModel) {
        guard OnboardingViewModel.shouldShow() else { return }
        show(model: model)
    }

    static func show(model: AppModel) {
        if let window, let viewModel {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // "Check permissions…" must reopen on whichever step still needs the user's
            // attention, not wherever the wizard happened to be left last time.
            Task { await viewModel.resetToFirstIncompleteStep() }
            model.dockIcon.open(.onboarding)
            return
        }

        let viewModel = OnboardingViewModel(permissions: model.env.permissions,
                                            models: model.env.models,
                                            detector: model.env.ollamaDetector)
        viewModel.applySelection = { modelID in
            model.settings.transcriptionSource = .local(modelID: modelID)
        }
        viewModel.onFinish = { close() }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Welcome to Macomprendo"
        window.isReleasedWhenClosed = false
        let delegate = OnboardingWindowDelegate { [weak model] in
            model?.dockIcon.close(.onboarding)
        }
        window.delegate = delegate
        self.delegate = delegate
        model.dockIcon.open(.onboarding)
        window.contentView = NSHostingView(rootView: OnboardingView(viewModel: viewModel))
        window.center()
        self.window = window
        self.viewModel = viewModel

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }
}
