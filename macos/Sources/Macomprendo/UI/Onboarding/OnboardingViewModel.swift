import Foundation

/// Probes whether an Ollama server answers at `url`.
protocol OllamaDetecting: Sendable {
    func isRunning(at url: URL) async -> Bool
}

/// `GET {baseURL}/api/tags` returns 200 with `{"models":[…]}` when Ollama is running.
struct HTTPOllamaDetector: OllamaDetecting {
    let http: any HTTPClient

    init(http: any HTTPClient) {
        self.http = http
    }

    func isRunning(at url: URL) async -> Bool {
        let request = HTTPRequest(method: "GET",
                                  url: url.appendingPathComponent("api/tags"),
                                  headers: [:],
                                  body: nil,
                                  timeout: 5)
        guard let response = try? await http.send(request) else { return false }
        return (200..<300).contains(response.status)
    }
}
