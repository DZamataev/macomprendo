import Foundation

/// Uploads recorded audio as a WAV file to any OpenAI-compatible
/// `POST /v1/audio/transcriptions` endpoint.
struct OpenAICompatibleTranscriber: TranscriptionProvider {
    private let endpoint: Endpoint
    private let apiKey: String?
    private let model: String
    private let http: any HTTPClient
    private let boundary: String

    init(endpoint: Endpoint, apiKey: String?, model: String, http: any HTTPClient) {
        self.init(
            endpoint: endpoint, apiKey: apiKey, model: model, http: http,
            boundary: "macomprendo-\(UUID().uuidString)"
        )
    }

    /// Deterministic-boundary initialiser, used by tests.
    init(endpoint: Endpoint, apiKey: String?, model: String, http: any HTTPClient, boundary: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.http = http
        self.boundary = boundary
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        let wav = WAVEncoder.encode(pcm: pcm, sampleRate: sampleRate)

        var fields = [("model", model), ("response_format", "json")]
        if let language, !language.isEmpty { fields.append(("language", language)) }

        var headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }

        let request = HTTPRequest(
            method: "POST",
            url: EndpointURL.openAI(endpoint.baseURL, "/audio/transcriptions"),
            headers: headers,
            body: Self.multipartBody(
                boundary: boundary,
                fileName: "audio.wav",
                fileType: "audio/wav",
                fileData: wav,
                fields: fields
            ),
            // Transcribing a five-minute recording on a loaded server is slow;
            // this is deliberately far above the 10 s used for metadata calls.
            timeout: 120
        )

        let response = try await http.send(request)
        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: response.body) else {
            throw MacomprendoError.providerStreamMalformed
        }
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exercises the same route dictation will use. `listModels()` would only prove
    /// reachability and credentials; a status that says "ready" must mean that the thing
    /// which runs at hotkey-press time has run.
    func probe() async throws {
        _ = try await transcribe(Array(repeating: 0, count: 16_000), sampleRate: 16_000, language: nil)
    }

    /// Builds a `multipart/form-data` body: the file part first (field name `file`),
    /// then each simple field, then the closing boundary. Every terminator is CRLF.
    static func multipartBody(
        boundary: String,
        fileName: String,
        fileType: String,
        fileData: Data,
        fields: [(String, String)]
    ) -> Data {
        var body = Data()

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(fileType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n".utf8))

        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
