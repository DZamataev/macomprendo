import Foundation
import Testing
@testable import Macomprendo

// MARK: - Decoding

@Test func aMissingConfigFileMeansNothingEnabledAndSaysNothing() {
    let outcome = GlossaryPackConfig.decode(from: nil)
    #expect(outcome.config.enabled.isEmpty)
    #expect(outcome.message == nil)
}

@Test func decodesTheEnabledNamesInFileOrder() {
    let data = Data(#"{ "enabled": ["typescript", "python", "godot"] }"#.utf8)
    let outcome = GlossaryPackConfig.decode(from: data)
    #expect(outcome.config.enabled == ["typescript", "python", "godot"])
    #expect(outcome.message == nil)
}

@Test func anEmptyEnabledListIsNotAFailure() {
    let outcome = GlossaryPackConfig.decode(from: Data(#"{"enabled":[]}"#.utf8))
    #expect(outcome.config.enabled.isEmpty)
    #expect(outcome.message == nil)
}

@Test func anEmptyConfigFileMeansNothingEnabledAndReportsAMessage() {
    let outcome = GlossaryPackConfig.decode(from: Data())
    #expect(outcome.config.enabled.isEmpty)
    #expect(outcome.message != nil)
}

@Test func malformedJSONMeansNothingEnabledAndReportsAMessage() {
    let outcome = GlossaryPackConfig.decode(from: Data("{ enabled: typescript".utf8))
    #expect(outcome.config.enabled.isEmpty)
    #expect(outcome.message != nil)
}

@Test func aConfigWithoutTheEnabledKeyReportsAMessage() {
    let outcome = GlossaryPackConfig.decode(from: Data(#"{ "enable": ["typescript"] }"#.utf8))
    #expect(outcome.config.enabled.isEmpty)
    #expect(outcome.message != nil)
}

@Test func theMessageDoesNotEchoTheFileContents() {
    // Pack names are user content (invariant 6); a decode failure must not quote them back.
    let outcome = GlossaryPackConfig.decode(from: Data(#"{ "enabled": ["my-secret-project",, ] }"#.utf8))
    #expect(outcome.config.enabled.isEmpty)
    #expect(outcome.message?.contains("my-secret-project") == false)
}

// MARK: - Unknown names

@Test func aNameWithNoMatchingPackSurvivesARoundTrip() {
    // The config has no filesystem and must not filter: deleting a pack file must not require
    // editing the config, and putting the file back must restore it.
    let original = Data(#"{ "enabled": ["typescript", "deleted-pack", "godot"] }"#.utf8)
    let once = GlossaryPackConfig.decode(from: original)
    let twice = GlossaryPackConfig.decode(from: once.config.encoded())
    #expect(twice.config.enabled == ["typescript", "deleted-pack", "godot"])
    #expect(twice.message == nil)
}

@Test func namesAreKeptVerbatimIncludingDuplicates() {
    let outcome = GlossaryPackConfig.decode(from: Data(#"{ "enabled": ["go", "go", "Go"] }"#.utf8))
    #expect(outcome.config.enabled == ["go", "go", "Go"])
}

// MARK: - Encoding

@Test func roundTripsTheSameNamesInTheSameOrder() {
    let config = GlossaryPackConfig(enabled: ["typescript", "react-native", "python"])
    let decoded = GlossaryPackConfig.decode(from: config.encoded())
    #expect(decoded.config == config)
    #expect(decoded.message == nil)
}

@Test func anEmptyConfigEncodesToAnEmptyEnabledList() {
    let encoded = GlossaryPackConfig().encoded()
    let object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: [String]]
    #expect(object?["enabled"] == [])
    #expect(GlossaryPackConfig.decode(from: encoded).config.enabled.isEmpty)
}

@Test func theEncodedFileEndsWithANewlineSoItIsATidyTextFile() {
    let encoded = GlossaryPackConfig(enabled: ["python"]).encoded()
    #expect(String(decoding: encoded, as: UTF8.self).hasSuffix("\n"))
}
