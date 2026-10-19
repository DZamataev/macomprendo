import AppKit
import Testing
@testable import Macomprendo

@MainActor
@Suite struct StatusItemImageTests {
    @Test func idleGlyphIsBundledAndDecodes() throws {
        let url = try #require(ResourceBundle.current.url(
            forResource: "StatusItemHeart", withExtension: "svg", subdirectory: "StatusItem"))
        let image = try #require(NSImage(contentsOf: url))
        #expect(image.isValid)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test func idleImageIsAn18PointTemplate() throws {
        let image = try #require(StatusItemController.makeIdleImage())
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let url = try #require(ResourceBundle.current.url(
            forResource: "StatusItemHeart", withExtension: "svg", subdirectory: "StatusItem"))
        let bundled = try #require(NSImage(contentsOf: url))
        let pixels = try #require(image.tiffRepresentation)
        #expect(pixels == bundled.tiffRepresentation)
    }

    @Test func missingOrUndecodableGlyphFallsBackToASymbol() throws {
        let nonImage = try #require(ResourceBundle.current.url(
            forResource: "LICENSE-phosphor", withExtension: "txt", subdirectory: "Icons"))
        for url in [nil, nonImage] as [URL?] {
            let image = try #require(StatusItemController.makeIdleImage(resourceURL: url))
            let waveform = try #require(NSImage(systemSymbolName: "waveform", accessibilityDescription: nil))
            waveform.size = NSSize(width: 18, height: 18)
            waveform.isTemplate = true
            let pixels = try #require(image.tiffRepresentation)
            #expect(pixels == waveform.tiffRepresentation)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
        }
    }
}
