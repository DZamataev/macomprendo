import AppKit
import SwiftUI

/// The app's icon vocabulary. The raw value is the vendored Phosphor SVG's file name in
/// `Resources/Icons` — keep it in step with `Resources/Icons/icons.json`.
enum AppIcon: String, CaseIterable {
    case microphone = "microphone"
    case microphoneFill = "microphone-fill"
    case waveform = "waveform"
    case speak = "speaker-high"
    case stop = "stop"
    case play = "play"
    case refine = "sparkle"
    case summarize = "text-aa"
    case clipboard = "clipboard-text"
    case insert = "arrow-square-in"
    case copy = "copy"
    case settings = "gear"
    case hotkeys = "keyboard"
    case download = "download-simple"
    case delete = "trash"
    case success = "check-circle"
    case warning = "warning-circle"
    case close = "x"
    case add = "plus"
    case remove = "minus"
    case refresh = "arrows-clockwise"
    case endpoint = "cloud"
    case model = "cpu"
    case presets = "list-bullets"
    case magic = "magic-wand"

    /// Shown when the SVG resource is missing, so the UI degrades instead of going blank.
    var fallbackSymbol: String {
        switch self {
        case .microphone, .microphoneFill: return "mic"
        case .waveform: return "waveform"
        case .speak: return "speaker.wave.2"
        case .stop: return "stop.fill"
        case .play: return "play.fill"
        case .refine: return "sparkles"
        case .summarize: return "textformat"
        case .clipboard: return "doc.on.clipboard"
        case .insert: return "arrow.down.doc"
        case .copy: return "doc.on.doc"
        case .settings: return "gearshape"
        case .hotkeys: return "keyboard"
        case .download: return "arrow.down.circle"
        case .delete: return "trash"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .close: return "xmark"
        case .add: return "plus"
        case .remove: return "minus"
        case .refresh: return "arrow.clockwise"
        case .endpoint: return "cloud"
        case .model: return "cpu"
        case .presets: return "list.bullet"
        case .magic: return "wand.and.stars"
        }
    }

    /// The vendored SVG, or nil when the resource is missing.
    func resourceURL(in bundle: Bundle = ResourceBundle.current) -> URL? {
        bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "Icons")
    }
}

/// The only place in the app that knows an icon is an SVG. Views write `Icon(.microphone)`.
struct Icon: View {
    let icon: AppIcon
    var size: CGFloat

    init(_ icon: AppIcon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        if let image = Icon.nsImage(for: icon, size: size) {
            Image(nsImage: image)
                .renderingMode(.template)
        } else {
            Image(systemName: icon.fallbackSymbol)
                .font(.system(size: size))
        }
    }

    /// Loads the SVG through `NSImage` (SVG is supported since macOS 11) and marks it a
    /// template so AppKit and SwiftUI tint it with the current foreground style.
    ///
    /// The HUD re-renders at animation rates, so decoded images are cached by icon and size
    /// rather than re-decoded from the SVG on every render.
    ///
    /// The cache is mutable shared state, so it is explicitly confined to the main actor.
    /// `Icon` only *infers* main-actor isolation from its `View` conformance, and because
    /// `View` is `@preconcurrency` that inference is not enforced at call sites — an
    /// explicit annotation is what actually makes the compiler reject off-main access.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func nsImage(for icon: AppIcon, size: CGFloat) -> NSImage? {
        let key = "\(icon.rawValue)-\(size)"
        if let cached = cache[key] { return cached }
        guard let url = icon.resourceURL(), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        cache[key] = image
        return image
    }
}
