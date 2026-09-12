import Foundation

/// The testable core of the About window: what it shows and where its links go. Holds no
/// SwiftUI, so it can be driven from tests with a fake opener and a fake bundle.
///
/// The licence list is `LicenseRegistry.all` verbatim — invariant 16 makes that registry the
/// single source for third-party notices, so this model never assembles a second list.
@MainActor
final class AboutModel: ObservableObject {
    /// Shown when the bundle carries no name, so the window never renders a blank title.
    static let fallbackAppName = "Macomprendo"
    /// Shown when the bundle carries no version or build keys.
    static let unknownVersionText = "—"
    /// Generated from `PRIVACY.md` and served from the project subpath (invariant 15).
    /// One constant, because a shipped 404 here would need another release to fix.
    static let privacyURL = URL(string: "https://dzamataev.github.io/macomprendo/privacy/")!

    let appName: String
    let version: String
    let build: String

    /// Every redistributed component, in the registry's own order.
    let entries: [LicenseEntry]

    @Published private(set) var selected: LicenseEntry?
    /// The selected entry's bundled licence text, or nil when the resource is missing.
    @Published private(set) var licenseText: String?
    /// Set instead of leaving an empty pane when a licence text cannot be read.
    @Published private(set) var errorMessage: String?

    private let bundle: Bundle
    private let opener: any URLOpening

    init(bundle: Bundle = ResourceBundle.current, opener: any URLOpening) {
        self.bundle = bundle
        self.opener = opener
        self.entries = LicenseRegistry.all
        let info = bundle.infoDictionary ?? [:]
        func string(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        self.appName = string("CFBundleName") ?? Self.fallbackAppName
        self.version = string("CFBundleShortVersionString") ?? Self.unknownVersionText
        self.build = string("CFBundleVersion") ?? Self.unknownVersionText
    }

    /// `1.2.3 (45)` — the marketing version with the build behind it.
    var versionText: String { "\(version) (\(build))" }

    /// The copyleft disclosure, taken from the entries that carry it rather than restated
    /// here: a third copy of this wording alongside `NOTICE` and the registry note would be a
    /// third thing to keep in step.
    var copyleftDisclosure: String {
        LicenseRegistry.copyleft
            .compactMap(\.note)
            .joined(separator: "\n\n")
    }

    func select(_ entry: LicenseEntry) {
        selected = entry
        if let text = entry.licenseText(in: bundle) {
            licenseText = text
            errorMessage = nil
        } else {
            licenseText = nil
            errorMessage = ErrorText.describe(MacomprendoError.licenseTextMissing(entry.component))
        }
    }

    /// Selects the first entry so the licence pane is never empty on first appearance, and
    /// does nothing once the reader has chosen: the window's `.onAppear` fires again every
    /// time it is reopened, and re-applying the default there would discard their choice.
    func selectDefaultIfNeeded() {
        guard selected == nil, let first = entries.first else { return }
        select(first)
    }

    func openPrivacyStatement() {
        opener.open(Self.privacyURL)
    }

    func openHomepage(of entry: LicenseEntry) {
        opener.open(entry.homepage)
    }
}
