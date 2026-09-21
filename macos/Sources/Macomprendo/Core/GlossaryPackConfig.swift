import Foundation

/// The contents of `Vocabulary/packs.json` (ADR-0012): the names of the packs that are on.
///
/// ```json
/// { "enabled": ["typescript", "python"] }
/// ```
///
/// A pack absent from `enabled` is off, including a file just dropped into the directory —
/// enabling is a deliberate act. A name here with no matching file is ignored at use time but
/// kept verbatim, so deleting a pack never requires editing the config and putting the file back
/// restores it. This type has no filesystem and deliberately never filters names.
struct GlossaryPackConfig: Equatable, Codable, Sendable {
    /// The enabled pack names, in file order. Order is meaningful: it decides which term wins a
    /// key collision.
    var enabled: [String]

    init(enabled: [String] = []) {
        self.enabled = enabled
    }

    /// The result of reading `packs.json`: the config, plus a message when the file could not be
    /// read as one. Decoding never throws — an unparsable glossary config must not take dictation
    /// down with it (invariant 8's "user-visible failure" is surfaced by the caller in the
    /// Glossary section, not raised).
    struct Outcome: Equatable, Sendable {
        /// Always usable. Empty when the file was missing or unreadable.
        var config: GlossaryPackConfig
        /// `nil` when the file was read successfully, including when it was simply absent.
        var message: String?
    }

    /// Reads `packs.json`'s bytes. `nil` data means no file, which is "nothing enabled" and not a
    /// problem worth telling the user about — that is the state a fresh install seeds.
    /// Empty or malformed bytes are "nothing enabled" *and* a message.
    static func decode(from data: Data?) -> Outcome {
        guard let data else { return Outcome(config: GlossaryPackConfig(), message: nil) }
        guard let config = try? JSONDecoder().decode(GlossaryPackConfig.self, from: data) else {
            // The underlying error is deliberately not quoted: it carries the file's contents,
            // and pack names are user content (invariant 6).
            return Outcome(
                config: GlossaryPackConfig(),
                message: "packs.json could not be read, so no glossary packs are enabled. "
                    + "Fix or delete the file, then use Reload."
            )
        }
        return Outcome(config: config, message: nil)
    }

    /// The bytes to write to `packs.json`. Sorted keys and a trailing newline keep the file
    /// readable and diffable for the agent that is expected to edit it by hand.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(self)) ?? Data(#"{"enabled":[]}"#.utf8)
        return body + Data("\n".utf8)
    }
}
