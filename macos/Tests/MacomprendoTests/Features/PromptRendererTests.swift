import Foundation
import Testing
@testable import Macomprendo

@Suite struct PromptRendererTests {
    private func preset(system: String = "SYS",
                        template: String = "Do it.\n{instruction}\n\n{text}",
                        name: String = "P") -> PromptPreset {
        PromptPreset(id: UUID(), kind: .refine, name: name, systemPrompt: system,
                     userTemplate: template, isFactory: false, sortOrder: 0)
    }

    // MARK: validate

    @Test func validAllPresetsFromTheFactoryHaveNoProblems() {
        for factory in FactoryPresets.all() {
            #expect(PromptRenderer.validate(factory).isEmpty, "\(factory.name) should validate")
        }
    }

    @Test func missingTextPlaceholderIsAProblem() {
        let problems = PromptRenderer.validate(preset(template: "Just do something"))
        #expect(problems.contains("The user template must contain {text}."))
    }

    @Test func unknownPlaceholderIsFlagged() {
        let problems = PromptRenderer.validate(preset(template: "{text} {tone}"))
        #expect(problems.contains { $0.contains("{tone}") })
    }

    @Test func emptyNameIsAProblem() {
        let problems = PromptRenderer.validate(preset(name: "   "))
        #expect(problems.contains("Name must not be empty."))
    }

    @Test func unknownPlaceholderInSystemPromptIsFlagged() {
        let problems = PromptRenderer.validate(preset(system: "Speak like {robot}"))
        #expect(problems.contains { $0.contains("{robot}") && $0.contains("system prompt") })
    }

    @Test func placeholdersAreExtractedIgnoringNonIdentifierBraces() {
        #expect(PromptRenderer.placeholders(in: "{text} and {instruction} and { not this }")
                == ["text", "instruction"])
    }

    // MARK: render

    @Test func systemAndUserMessagesAreProduced() {
        let r = PromptRenderer.render(preset(), text: "hello", instruction: "be nice", language: nil)
        #expect(r.messages.count == 2)
        #expect(r.messages[0] == ChatMessage(role: .system, content: "SYS"))
        #expect(r.messages[1].role == .user)
        #expect(r.messages[1].content == "Do it.\nbe nice\n\nhello")
    }

    @Test func emptyInstructionRemovesItsLine() {
        let r = PromptRenderer.render(preset(), text: "hello", instruction: "   ", language: nil)
        #expect(r.messages[1].content == "Do it.\n\nhello")
    }

    @Test func nilInstructionRemovesItsLine() {
        let r = PromptRenderer.render(preset(), text: "hello", instruction: nil, language: nil)
        #expect(r.messages[1].content == "Do it.\n\nhello")
    }

    @Test func aLineHoldingBothTextAndInstructionIsKept() {
        let p = preset(template: "Rewrite {text} {instruction}")
        let r = PromptRenderer.render(p, text: "hi", instruction: nil, language: nil)
        #expect(r.messages[1].content == "Rewrite hi ")
    }

    @Test func languageDefaultsToEnglishWhenMissing() {
        let p = preset(template: "Into {language}: {text}")
        #expect(PromptRenderer.render(p, text: "x", instruction: nil, language: nil)
                .messages[1].content == "Into English: x")
        #expect(PromptRenderer.render(p, text: "x", instruction: nil, language: "Spanish")
                .messages[1].content == "Into Spanish: x")
    }

    @Test func emptySystemPromptYieldsOnlyTheUserMessage() {
        let r = PromptRenderer.render(preset(system: "  "), text: "x", instruction: nil, language: nil)
        #expect(r.messages.count == 1)
        #expect(r.messages[0].role == .user)
    }

    @Test func placeholdersInsideTheUserTextAreNotSubstituted() {
        let r = PromptRenderer.render(preset(), text: "say {instruction} now", instruction: "loud", language: nil)
        #expect(r.messages[1].content == "Do it.\nloud\n\nsay {instruction} now")
    }
}
