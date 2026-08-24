import Foundation
import Testing
@testable import Macomprendo

@Test func ollamaLocalHasStableIdentityAndURL() {
    let endpoint = Endpoint.ollamaLocal()
    #expect(endpoint.id == UUID(uuidString: "00000000-0000-0000-0000-00000000A11A"))
    #expect(endpoint.name == "Ollama (local)")
    #expect(endpoint.kind == .ollama)
    #expect(endpoint.baseURL.absoluteString == "http://localhost:11434")
    #expect(endpoint.apiKeyRef == nil)
}

@Test func endpointRoundTripsThroughJSON() throws {
    let endpoint = Endpoint(
        name: "Work",
        kind: .openAICompatible,
        baseURL: URL(string: "https://api.openai.com")!,
        apiKeyRef: "work-key"
    )
    let data = try JSONEncoder().encode(endpoint)
    #expect(try JSONDecoder().decode(Endpoint.self, from: data) == endpoint)
}

@Test func endpointKindCoversBothDialects() {
    #expect(EndpointKind.allCases == [.ollama, .openAICompatible])
}
