import AppKit
import Combine
import SwiftUI

/// The app's status item and popover as `AppModel` sees them: what the panel's commands
/// close, and what a headless test fakes in place of a real status bar (spec §6).
@MainActor
protocol StatusItemHosting: AnyObject {
    func closePanel()
    /// Shows the panel if it is not already shown; never closes it.
    func revealPanel()
    var isPanelShown: Bool { get }
}

/// Owns the app's single status item, its button's title and the transient popover that
/// hosts `MenuPanelView`. Created once from `AppModel.start()` through the environment's
/// factory, so the model can close the panel without touching AppKit.
///
/// The title follows the recording and transcription controllers' state and elapsed-clock
/// publishers — never their level meters, which tick at 10 Hz (spec §4).
@MainActor
final class StatusItemController: NSObject, StatusItemHosting, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hostingController: NSHostingController<AnyView>
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    /// When the popover last closed, to tell a genuine reopen from the mouse-up half of the
    /// click that just closed it (see `StatusItemToggle`).
    private var lastClosedAt: Date?
    /// The title the item's width was last reserved for; `nil` until the first render.
    private var reservedSample: String?
    /// Watches clicks delivered to other apps while the popover is shown. `.transient` alone
    /// misses some of them — a click into another app's window on another display, made after
    /// scrolling it without focusing it, left the panel open — so such a click closes it here.
    private var outsideClickMonitor: Any?
    /// The same for our own windows and Escape, which `.applicationDefined` leaves to us.
    private var localEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    /// Follows the status button's window while the popover is shown (see `reanchor()`).
    private var buttonWindowObservers: [NSObjectProtocol] = []
    /// The display the panel settled on after opening; `nil` until that first pass.
    private var anchoredScreen: NSScreen?

    private lazy var titleWriter = StatusItemTitleWriter { [weak self] content in
        self?.write(content)
    }

    var isPanelShown: Bool { popover.isShown }

    init(model: AppModel, now: @escaping () -> Date = { Date() }) {
        self.model = model
        self.now = now
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hostingController = NSHostingController(
            rootView: AnyView(Self.panel(for: model, maxHeight: .greatestFiniteMagnitude)))
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            // Both clicks are the same command; a status button only sends on left mouse-up
            // by default.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            // Tabular digits: per-second clock and percent updates must not jitter (spec §4).
            button.font = Self.titleFont
        }
        hostingController.sizingOptions = .preferredContentSize
        // Not `.transient`: activating the app to make the panel key also brings an open
        // window of ours (Transcripts, Settings) forward, and a transient popover took that
        // key change for a dismissal — it closed and reopened. Dismissal is ours instead:
        // a click elsewhere, Escape, the app losing focus (`installDismissal()`).
        popover.behavior = .applicationDefined
        popover.contentViewController = hostingController
        popover.delegate = self

        observe()
    }

    // MARK: - Toggling

    @objc private func togglePanel() {
        switch StatusItemToggle.decide(isShown: isPanelShown, lastClosedAt: lastClosedAt, now: now()) {
        case .close: closePanel()
        case .show: showPanel()
        case .ignore: break
        }
    }

    func closePanel() {
        guard isPanelShown else { return }
        popover.performClose(nil)
        recordClose()
        // Belt and braces with the delegate callbacks below: a close this method asks for
        // must never leave the button pressed (spec §6, §8's stuck-highlight check).
        statusItem.button?.highlight(false)
    }

    func revealPanel() {
        guard !isPanelShown else { return }
        showPanel()
    }

    /// Called on every close path so the toggle can recognise the mouse-up that follows a
    /// click's own dismissal (`StatusItemToggle`). Not on `willClose`: `performClose` and
    /// every AppKit dismissal reach `didClose`, and the shortest recency window is centred
    /// on the moment the popover is actually gone.
    private func recordClose() {
        lastClosedAt = now()
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        hostingController.rootView = AnyView(
            Self.panel(for: model, maxHeight: maxPanelHeight(for: button)))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        NSApp.activate(ignoringOtherApps: true)
        // The popover window must be key for ⌘, ⌘Q and Escape to reach the panel.
        popover.contentViewController?.view.window?.makeKey()
        installOutsideClickMonitor()
        followButtonWindow(of: button)
        // Clicking the menu bar of a display that is not the focused one moves the status
        // item's window there during this very click; AppKit has anchored the popover to the
        // frame it had before. A pass on the next turn finds it where it now is.
        anchoredScreen = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reanchor()
            self.anchoredScreen = self.statusItem.button?.window?.screen
        }
    }

    /// Showing an already shown popover again repositions it — window and arrow — against
    /// the button's current frame.
    private func reanchor() {
        guard isPanelShown, let button = statusItem.button else { return }
        popover.animates = false
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.animates = true
    }

    /// The button's window also moves while the panel is open: a title that changes width
    /// (the recording clock, a percent) or a display change. Each move re-anchors.
    private func followButtonWindow(of button: NSStatusBarButton) {
        stopFollowingButtonWindow()
        guard let window = button.window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            buttonWindowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.buttonWindowMoved() }
            })
        }
    }

    /// A move on the same display (the title changed width) keeps the panel and re-anchors
    /// it; a move to another display means the menu bar there was clicked, and the panel
    /// closes rather than jumping across — the same as clicking anywhere else outside it.
    private func buttonWindowMoved() {
        guard let anchoredScreen else { return }
        if let screen = statusItem.button?.window?.screen, screen != anchoredScreen {
            closePanel()
        } else {
            reanchor()
        }
    }

    private func stopFollowingButtonWindow() {
        buttonWindowObservers.forEach(NotificationCenter.default.removeObserver)
        buttonWindowObservers = []
    }

    /// Every way the panel is dismissed besides its own commands. A global monitor sees clicks
    /// sent to other apps; a local one sees clicks in our own windows (the status item's
    /// window excluded — its click is the toggle) and Escape. Pop-up menus inside the panel
    /// track in their own loop and never reach the local monitor.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) {
            [weak self] event in
            // Local monitors run on the main thread; NSEvent is not Sendable, so the hop into
            // the main actor's isolation carries it unchecked.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { result = self?.handleLocal(event) ?? event }
            return result
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        guard isPanelShown else { return event }
        let panelWindow = popover.contentViewController?.view.window
        if event.type == .keyDown {
            // Escape, while the panel is the key window.
            guard event.keyCode == 53, event.window === panelWindow else { return event }
            closePanel()
            return nil
        }
        if event.window !== panelWindow, event.window !== statusItem.button?.window {
            closePanel()
        }
        return event
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        localEventMonitor = nil
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        resignActiveObserver = nil
    }

    /// The panel with its three observed selector models wired in. The root view is rebuilt per
    /// show, which resets the panel's `@State` — so Options starts collapsed and the shortcut
    /// annotations are re-read on every opening (spec §6).
    private static func panel(for model: AppModel, maxHeight: CGFloat) -> some View {
        MenuPanelView(dictation: model.dictationTabModel,
                      models: model.modelsViewModel,
                      microphone: model.panelMicrophonePickerModel,
                      maxHeight: maxHeight)
            .environmentObject(model)
    }

    /// Caps the panel on the status button's own screen, leaving the popover's arrow and
    /// margins their room (spec §6: a short display scrolls instead of overflowing).
    private func maxPanelHeight(for button: NSStatusBarButton) -> CGFloat {
        guard let visibleHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height
        else { return .greatestFiniteMagnitude }
        return max(0, visibleHeight - 40)
    }

    // MARK: - NSPopoverDelegate

    // Cleared on both: every dismissal AppKit performs itself — Escape, outside click,
    // transient close — posts both callbacks, and neither alone should be trusted to be the
    // one that observes the close.
    func popoverWillClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        // Stop here, not on didClose: `isShown` stays true through the close animation, and a
        // window opened by a panel command can move the status item in that time — a re-anchor
        // then reopened the panel over the new window.
        stopFollowingButtonWindow()
        removeOutsideClickMonitor()
        anchoredScreen = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        stopFollowingButtonWindow()
        anchoredScreen = nil
        recordClose()
        statusItem.button?.highlight(false)
    }

    // MARK: - The title

    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                                    weight: .regular)
    /// Room around the image and title inside a reserved slot: the image–title gap plus a
    /// narrow margin each side. AppKit's own variable-length frames leave 23.2–23.8 pt here,
    /// which crowds a clock under the notch on a full menu bar.
    private static let slotMargin: CGFloat = 14
    /// The call clock's pill is tighter still: it is the item most likely to meet the notch.
    private static let recordingSlotMargin: CGFloat = 4

    /// The three publishers the title derives from. Deliberately not `$levels`: the meters
    /// tick at 10 Hz and would repaint the menu bar for nothing.
    private func observe() {
        StatusItemInputs.latest(isRecording: model.callRecording.$state.map(\.isRecording),
                                elapsed: model.callRecording.$elapsed,
                                transcription: model.fileTranscription.$state)
            .sink { [weak self] in self?.render($0.recordingElapsed, $0.transcription) }
            .store(in: &cancellables)
    }

    private func render(_ elapsed: TimeInterval?,
                        _ transcription: FileTranscriptionController.State) {
        titleWriter.apply(MenuPanelPresentation.statusItem(recordingElapsed: elapsed,
                                                           transcription: transcription))
        reserveWidth(for: StatusItemTitleSample.widest(recordingElapsed: elapsed,
                                                       transcription: transcription),
                     margin: elapsed == nil ? Self.slotMargin : Self.recordingSlotMargin)
    }

    /// One width per title mode (spec §4): the item is sized for the widest title the mode
    /// can render, so no digit-count change inside it can resize the button and re-anchor
    /// the open popover. Re-measured only when the sample changes; idle keeps AppKit's own
    /// content sizing, which already fits an image-only item.
    private func reserveWidth(for sample: String, margin: CGFloat) {
        guard sample != reservedSample else { return }
        reservedSample = sample
        guard let button = statusItem.button else { return }
        guard !sample.isEmpty else {
            statusItem.length = NSStatusItem.variableLength
            return
        }
        let text = (sample as NSString).size(withAttributes: [.font: Self.titleFont]).width
        statusItem.length = ceil((button.image?.size.width ?? 0) + text + margin)
    }

    private static let idleImage = makeIdleImage()

    static func makeIdleImage(resourceURL: URL? = ResourceBundle.current.url(
        forResource: "StatusItemHeart", withExtension: "svg", subdirectory: "StatusItem")
    ) -> NSImage? {
        let custom = resourceURL.flatMap { NSImage(contentsOf: $0) }
        let image = custom?.isValid == true ? custom
            : NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }

    private func write(_ content: MenuPanelPresentation.StatusItemContent) {
        guard let button = statusItem.button else { return }
        let image = switch content.symbol {
        case .idle: Self.idleImage
        case .recording: NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        }
        // Both the custom idle glyph and recording symbol are templates (invariant 12), so
        // macOS picks their contrast against the menu bar's own wallpaper (spec §6).
        image?.isTemplate = true
        button.image = image
        button.title = content.title
        button.toolTip = content.tooltip
        button.setAccessibilityLabel(content.accessibilityLabel)
    }
}
