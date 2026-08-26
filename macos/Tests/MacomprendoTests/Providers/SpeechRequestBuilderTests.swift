import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechRequestBuilderTests {
    private let base = URL(string: "https://api.openai.com")!

    @Test func theRequestTargetsTheAudioSpeechEndpointWithABearerToken() throws {
        let request = try SpeechRequestBuilder.request(baseURL: base,
                                                       apiKey: "sk-SECRET",
                                                       model: "gpt-4o-mini-tts",
                                                       voice: "alloy",
                                                       input: "Hello",
                                                       instructions: "",
                                                       timeout: 60)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.headers["Authorization"] == "Bearer sk-SECRET")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.timeout == 60)
        // The key travels in the header only, never in the body.
        #expect(!String(decoding: request.body ?? Data(), as: UTF8.self).contains("sk-SECRET"))
    }

    @Test func resellerAndLocalBaseURLsResolveCorrectly() throws {
        func url(_ string: String) throws -> String {
            try SpeechRequestBuilder.request(baseURL: URL(string: string)!,
                                             apiKey: "k", model: "m", voice: "v",
                                             input: "i", instructions: "", timeout: 10)
                .url.absoluteString
        }
        #expect(try url("https://api.openai.com/") == "https://api.openai.com/v1/audio/speech")
        #expect(try url("https://api.proxyapi.ru/openai")
                == "https://api.proxyapi.ru/openai/v1/audio/speech")
        #expect(try url("http://localhost:8000/v1") == "http://localhost:8000/v1/audio/speech")
    }

    @Test func theBodyCarriesModelVoiceInputAndFormatAndOmitsEmptyInstructions() throws {
        let body = try SpeechRequestBuilder.requestBody(model: "gpt-4o-mini-tts",
                                                        voice: "alloy",
                                                        input: "Hello",
                                                        instructions: "   ")
        #expect(String(decoding: body, as: UTF8.self) == """
            {"input":"Hello","model":"gpt-4o-mini-tts","response_format":"wav","voice":"alloy"}
            """)
    }

    @Test func instructionsAreSentWhenSetAndNonASCIIStaysRawUTF8() throws {
        let body = try SpeechRequestBuilder.requestBody(model: "gpt-4o-mini-tts",
                                                        voice: "alloy",
                                                        input: "Привет!",
                                                        instructions: "Speak slowly")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text == """
            {"input":"Привет!","instructions":"Speak slowly","model":"gpt-4o-mini-tts",\
            "response_format":"wav","voice":"alloy"}
            """)
        #expect(!text.contains("\\u"))
    }

    @Test func theEndpointNameIsTheConfiguredHostAndTransportErrorsAreRenamed() {
        #expect(SpeechRequestBuilder.endpointName(for: base) == "api.openai.com")
        #expect(SpeechRequestBuilder.endpointName(for: URL(string: "http://localhost:8000")!)
                == "localhost")

        let renamed = SpeechRequestBuilder.mapped(
            .providerUnreachable(endpointName: "whatever"),
            baseURL: URL(string: "https://api.proxyapi.ru/openai")!)
        #expect(renamed == .providerUnreachable(endpointName: "api.proxyapi.ru"))

        // Anything else passes through untouched, including the silent cancellation case.
        #expect(SpeechRequestBuilder.mapped(.providerHTTP(status: 401, body: "bad key"), baseURL: base)
                == .providerHTTP(status: 401, body: "bad key"))
        #expect(SpeechRequestBuilder.mapped(.cancelled, baseURL: base) == .cancelled)
    }

    @Test func anEmptyResponseBodyIsMalformed() throws {
        let audio = try SpeechRequestBuilder.audio(
            from: HTTPResponse(status: 200, headers: [:], body: Data([0x52, 0x49, 0x46, 0x46])))
        #expect(audio == Data([0x52, 0x49, 0x46, 0x46]))

        #expect(throws: MacomprendoError.providerStreamMalformed) {
            _ = try SpeechRequestBuilder.audio(from: HTTPResponse(status: 200, headers: [:], body: Data()))
        }
    }
}
