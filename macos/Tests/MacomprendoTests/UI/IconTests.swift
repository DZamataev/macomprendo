import AppKit
import Testing
@testable import Macomprendo

@Test(arguments: AppIcon.allCases)
func everyIconHasAVendoredSVG(icon: AppIcon) throws {
    let url = try #require(icon.resourceURL(), "missing Resources/Icons/\(icon.rawValue).svg — add it to icons.json and run `npm run sync-icons`")
    #expect(url.lastPathComponent == "\(icon.rawValue).svg")
}

// Touches `Icon.nsImage`, whose cache is main-actor confined, so this suite of cases runs
// on the main actor instead of in parallel on the cooperative pool.
@MainActor
@Test(arguments: AppIcon.allCases)
func everyIconLoadsAsATemplateImage(icon: AppIcon) throws {
    let image = try #require(Icon.nsImage(for: icon, size: 16))
    #expect(image.isTemplate)
    #expect(image.size == NSSize(width: 16, height: 16))
}

@Test func iconRawValuesAreUnique() {
    #expect(Set(AppIcon.allCases.map(\.rawValue)).count == AppIcon.allCases.count)
}

@Test func theLicenceTravelsWithTheIcons() {
    #expect(ResourceBundle.current.url(forResource: "LICENSE-phosphor", withExtension: "txt", subdirectory: "Icons") != nil)
}

@MainActor
@Test func repeatedLoadsOfTheSameIconAndSizeReturnTheSameCachedInstance() throws {
    let first = try #require(Icon.nsImage(for: .microphone, size: 16))
    let second = try #require(Icon.nsImage(for: .microphone, size: 16))
    #expect(first === second)
}
