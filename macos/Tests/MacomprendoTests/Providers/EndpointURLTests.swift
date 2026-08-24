import Foundation
import Testing
@testable import Macomprendo

@Suite struct EndpointURLTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func joinAppendsPathWithoutTrailingSlashDuplication() {
        #expect(EndpointURL.join(url("http://localhost:11434"), "/api/tags")
                == url("http://localhost:11434/api/tags"))
        #expect(EndpointURL.join(url("http://localhost:11434/"), "/api/tags")
                == url("http://localhost:11434/api/tags"))
    }

    @Test func joinAcceptsPathWithoutLeadingSlash() {
        #expect(EndpointURL.join(url("http://localhost:11434"), "api/chat")
                == url("http://localhost:11434/api/chat"))
    }

    @Test func joinPreservesASubPathInTheBaseURL() {
        #expect(EndpointURL.join(url("https://gw.example.com/ollama"), "/api/tags")
                == url("https://gw.example.com/ollama/api/tags"))
    }

    @Test func openAIAppendsV1WhenTheBaseDoesNotHaveIt() {
        #expect(EndpointURL.openAI(url("https://api.openai.com"), "/models")
                == url("https://api.openai.com/v1/models"))
        #expect(EndpointURL.openAI(url("https://api.openai.com/"), "/models")
                == url("https://api.openai.com/v1/models"))
        #expect(EndpointURL.openAI(url("http://localhost:11434"), "/chat/completions")
                == url("http://localhost:11434/v1/chat/completions"))
    }

    @Test func openAIDoesNotDoubleUpWhenTheBaseAlreadyEndsInV1() {
        #expect(EndpointURL.openAI(url("https://api.openai.com/v1"), "/models")
                == url("https://api.openai.com/v1/models"))
        #expect(EndpointURL.openAI(url("https://api.openai.com/v1/"), "/models")
                == url("https://api.openai.com/v1/models"))
        #expect(EndpointURL.openAI(url("http://localhost:1234/v1"), "/audio/transcriptions")
                == url("http://localhost:1234/v1/audio/transcriptions"))
    }

    @Test func openAIDoesNotMistakeAV1SubstringForTheVersionSegment() {
        // "/apiv1" ends with "v1" but is not the "/v1" segment.
        #expect(EndpointURL.openAI(url("https://example.com/apiv1"), "/models")
                == url("https://example.com/apiv1/v1/models"))
    }

    @Test func chatOptionsDefaultsMatchTheSpec() {
        let options = ChatOptions()
        #expect(options.temperature == 0.3)
        #expect(options.maxTokens == nil)
        #expect(ChatOptions.default == options)
    }

    @Test func chatMessageEncodesAsRoleAndContent() throws {
        let data = try JSONEncoder().encode(ChatMessage(role: .user, content: "hi"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["role": "user", "content": "hi"])
    }
}
