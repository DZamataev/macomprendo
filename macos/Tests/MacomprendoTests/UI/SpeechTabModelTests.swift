import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeechTabModelTests {
    private let voices = [
        Voice(id: "v.fr", name: "Amélie", language: "fr-FR", quality: "premium"),
        Voice(id: "v.en2", name: "Alex", language: "en-US", quality: "default"),
        Voice(id: "v.en1", name: "Ava", language: "en-US", quality: "enhanced"),
    ]

    @Test func voicesAreGroupedByLanguageAndSortedByName() {
        let groups = SpeechTabModel.group(voices)
        #expect(groups.map(\.language) == ["en-US", "fr-FR"])
        #expect(groups[0].voices.map(\.name) == ["Alex", "Ava"])
        #expect(groups[0].displayName.contains("English"))
        #expect(groups[1].voices.map(\.name) == ["Amélie"])
    }

    @Test func groupingAnEmptyListYieldsNoGroups() {
        #expect(SpeechTabModel.group([]).isEmpty)
    }

    @Test func reloadPublishesTheServiceVoices() {
        let speech = ScriptedSpeech()
        speech.available = voices
        let model = SpeechTabModel(speech: speech, holder: ScriptedSettingsHolder())
        #expect(model.groups.count == 2)

        speech.available = [voices[0]]
        model.reload()
        #expect(model.groups.count == 1)
    }

    @Test func previewSpeaksTheSampleWithTheCurrentSettings() {
        let speech = ScriptedSpeech()
        let holder = ScriptedSettingsHolder()
        holder.settings.speech = SpeechSettings(voiceID: "v.en1", rate: 0.7, pitch: 1.2, volume: 0.8)
        let model = SpeechTabModel(speech: speech, holder: holder)

        model.preview()

        #expect(speech.spoken.count == 1)
        #expect(speech.spoken[0].text == SpeechTabModel.sampleText)
        #expect(speech.spoken[0].settings.voiceID == "v.en1")
        #expect(speech.spoken[0].settings.rate == 0.7)
    }
}
