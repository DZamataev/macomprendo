import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct AboutModelTests {

    /// A bundle written to disk so the version readout can be tested without depending on
    /// whichever bundle happens to host the test run.
    private func makeBundle(info: [String: String]) throws -> Bundle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AboutModelTests-\(UUID().uuidString).bundle",
                                    isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info,
                                                       format: .xml,
                                                       options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: root))
    }

    @Test func versionAndBuildComeFromTheBundle() throws {
        let bundle = try makeBundle(info: [
            "CFBundleName": "Macomprendo",
            "CFBundleShortVersionString": "9.9.9",
            "CFBundleVersion": "42",
        ])
        let model = AboutModel(bundle: bundle, opener: FakeURLOpener())

        #expect(model.appName == "Macomprendo")
        #expect(model.version == "9.9.9")
        #expect(model.build == "42")
        #expect(model.versionText == "9.9.9 (42)")
    }

    @Test func aBundleWithoutVersionKeysStillShowsSomething() throws {
        let bundle = try makeBundle(info: [:])
        let model = AboutModel(bundle: bundle, opener: FakeURLOpener())

        #expect(model.appName == AboutModel.fallbackAppName)
        #expect(model.version == AboutModel.unknownVersionText)
        #expect(model.build == AboutModel.unknownVersionText)
        #expect(!model.versionText.isEmpty)
    }

    @Test func offersEveryRegistryEntryInTheRegistryOrder() {
        let model = AboutModel(bundle: ResourceBundle.current, opener: FakeURLOpener())

        #expect(model.entries == LicenseRegistry.all)
    }

    @Test func selectingAnEntryYieldsItsBundledText() throws {
        let model = AboutModel(bundle: ResourceBundle.current, opener: FakeURLOpener())
        let espeak = try #require(LicenseRegistry.all.first { $0.component == "espeak-ng" })

        model.select(espeak)

        #expect(model.selected == espeak)
        let text = try #require(model.licenseText)
        #expect(text.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(model.errorMessage == nil)
    }

    @Test func aMissingLicenceTextBecomesAnExplicitStateNotAnEmptyPane() throws {
        let bundle = try makeBundle(info: [:])
        let model = AboutModel(bundle: bundle, opener: FakeURLOpener())
        let entry = try #require(LicenseRegistry.all.first)

        model.select(entry)

        #expect(model.licenseText == nil)
        let message = try #require(model.errorMessage)
        #expect(message.contains(entry.component))
        #expect(message == ErrorText.describe(MacomprendoError.licenseTextMissing(entry.component)))
    }

    @Test func theCopyleftDisclosureNamesBothLicences() {
        let model = AboutModel(bundle: ResourceBundle.current, opener: FakeURLOpener())

        // The app as distributed is GPL-3.0 while Macomprendo's own source is MIT. Dropping
        // either half of that sentence is the failure this guards.
        #expect(model.copyleftDisclosure.contains("GPL-3.0"))
        #expect(model.copyleftDisclosure.contains("MIT"))
        #expect(model.copyleftDisclosure.contains("github.com/DZamataev/macomprendo"))
    }

    @Test func openingThePrivacyStatementUsesTheOneConstant() {
        let opener = FakeURLOpener()
        let model = AboutModel(bundle: ResourceBundle.current, opener: opener)

        model.openPrivacyStatement()

        #expect(opener.opened == [AboutModel.privacyURL])
        #expect(AboutModel.privacyURL.absoluteString
                == "https://dzamataev.github.io/macomprendo/privacy/")
    }

    @Test func openingAComponentHomepageUsesTheRegistryURL() throws {
        let opener = FakeURLOpener()
        let model = AboutModel(bundle: ResourceBundle.current, opener: opener)
        let entry = try #require(LicenseRegistry.all.first { $0.component == "sherpa-onnx" })

        model.openHomepage(of: entry)

        #expect(opener.opened == [entry.homepage])
    }
}
