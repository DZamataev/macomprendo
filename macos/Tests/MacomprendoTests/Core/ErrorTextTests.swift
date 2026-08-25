import Foundation
import Testing
@testable import Macomprendo

@Suite struct ErrorTextTests {
    @Test func localizedErrorsGetDescriptionAndRecovery() {
        let text = ErrorText.describe(MacomprendoError.noSelection)
        #expect(text.contains(MacomprendoError.noSelection.errorDescription ?? "!"))
        if let recovery = MacomprendoError.noSelection.recoverySuggestion {
            #expect(text.contains(recovery))
        }
    }

    @Test func cancellationBecomesAShortMessage() {
        #expect(ErrorText.describe(CancellationError()) == "Cancelled.")
    }

    @Test func configErrorsNameTheFeature() {
        let text = ErrorText.describe(FeatureConfigError.llmNotConfigured(.summarize))
        #expect(text.contains("Summarize"))
        #expect(text.contains("Settings"))
    }

    @Test func missingPresetErrorNamesTheFeature() {
        let text = ErrorText.describe(FeatureConfigError.noPreset(.refine))
        #expect(text.contains("Refine"))
    }
}
