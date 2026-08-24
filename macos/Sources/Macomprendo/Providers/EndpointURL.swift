import Foundation

/// Builds request URLs from user-entered base URLs, which arrive in every shape:
/// with or without a trailing slash, with or without a `/v1` suffix.
enum EndpointURL {

    /// Appends `path` to `base` verbatim. Used for Ollama's native API (`/api/…`).
    static func join(_ base: URL, _ path: String) -> URL {
        URL(string: normalisedBase(base) + leadingSlashed(path)) ?? base
    }

    /// Appends `path` under the OpenAI `/v1` prefix, adding `/v1` only when the base
    /// URL does not already end with that path segment.
    /// `path` is given without the prefix, e.g. `"/models"`, `"/chat/completions"`.
    static func openAI(_ base: URL, _ path: String) -> URL {
        let root = normalisedBase(base)
        let prefixed = root.hasSuffix("/v1") ? root : root + "/v1"
        return URL(string: prefixed + leadingSlashed(path)) ?? base
    }

    /// The base URL as a string with any single trailing slash removed.
    private static func normalisedBase(_ base: URL) -> String {
        let string = base.absoluteString
        return string.hasSuffix("/") ? String(string.dropLast()) : string
    }

    private static func leadingSlashed(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }
}
