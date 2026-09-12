import Foundation

/// The `id` every SwiftUI `Window` scene is declared with and every `openWindow(id:)` call
/// opens by. One shared source rather than a bare string at each site — a typo on either
/// side is a silently dead menu item no test can see, because `openWindow` for an unknown id
/// does nothing observable.
enum WindowID {
    static let dictationHistory = "dictation-history"
    static let about = "about"
}
