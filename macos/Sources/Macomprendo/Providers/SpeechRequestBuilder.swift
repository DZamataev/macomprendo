import Foundation

/// Builds the request for an OpenAI-compatible `POST /v1/audio/speech` endpoint and names its
/// failures. The whole API shape lives here, so a change to it touches exactly one file.
///
///     POST {base}/v1/audio/speech
///     Authorization: Bearer <key>
///     {"input": …, "instructions": …, "model": …, "response_format": "wav", "voice": …}
///
/// The response body **is** the audio file — no envelope, no base64. `AVAudioPlayer` sniffs the
/// container, so a server that ignores `response_format` and returns MP3 still plays.
enum SpeechRequestBuilder {
    /// Appended under `EndpointURL.openAI`'s `/v1` prefix.
    static let path = "/audio/speech"
    static let responseFormat = "wav"

    /// What the user sees in `providerUnreachable`: the host they configured, not a raw URL.
    static func endpointName(for baseURL: URL) -> String {
        baseURL.host() ?? baseURL.absoluteString
    }

    private struct Body: Encodable {
        let model: String
        let voice: String
        let input: String
        let responseFormat: String
        /// Omitted from the JSON entirely when nil, so a server that does not know the field
        /// sees exactly the body a plain `tts-1` request would send.
        let instructions: String?

        enum CodingKeys: String, CodingKey {
            case model, voice, input, instructions
            case responseFormat = "response_format"
        }
    }

    /// Deterministic key order so the body is assertable byte for byte in tests.
    static func requestBody(model: String,
                            voice: String,
                            input: String,
                            instructions: String) throws -> Data {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(model: model,
                                       voice: voice,
                                       input: input,
                                       responseFormat: responseFormat,
                                       instructions: trimmed.isEmpty ? nil : trimmed))
    }

    /// The key goes in the `Authorization` header and nowhere else (invariant 5).
    static func request(baseURL: URL,
                        apiKey: String,
                        model: String,
                        voice: String,
                        input: String,
                        instructions: String,
                        timeout: TimeInterval) throws -> HTTPRequest {
        HTTPRequest(method: "POST",
                    url: EndpointURL.openAI(baseURL, path),
                    headers: ["Content-Type": "application/json",
                              "Authorization": "Bearer \(apiKey)"],
                    body: try requestBody(model: model,
                                          voice: voice,
                                          input: input,
                                          instructions: instructions),
                    timeout: timeout)
    }

    /// A 2xx with no bytes is a server that accepted the request and produced nothing; that is
    /// a malformed response, not silence to play.
    static func audio(from response: HTTPResponse) throws -> Data {
        guard !response.body.isEmpty else { throw MacomprendoError.providerStreamMalformed }
        return response.body
    }

    /// `HTTPClient` names the host it could not reach from the URL it was handed; re-derive it
    /// from the configured base so the message matches what the user typed in Settings.
    static func mapped(_ error: MacomprendoError, baseURL: URL) -> MacomprendoError {
        if case .providerUnreachable = error {
            return .providerUnreachable(endpointName: endpointName(for: baseURL))
        }
        return error
    }
}
