import Foundation

/// What the post-dictation review panel shows: the text that was inserted, and every rewrite
/// normalisation made on the way there.
///
/// A projection of `NormalisationResult`, not a second computation. It holds no glossary and
/// runs no matching: everything it shows was decided when the text was normalised, so the panel
/// can never disagree with the text that was actually pasted.
///
/// It carries transcript content, so it must never reach a log line at default level.
struct CorrectionReview: Equatable, Sendable {
    /// One rewrite, exactly as normalisation reported it — the range indexes `text`, the final
    /// string, not the transcript the model produced.
    typealias Rewrite = NormalisationResult.Rewrite

    /// The inserted text.
    let text: String
    /// Every rewrite, in the order they appear in `text`.
    let rewrites: [Rewrite]

    /// Projects a normalisation result. The text and the rewrites are carried through unchanged.
    init(_ result: NormalisationResult) {
        self.text = result.text
        self.rewrites = result.rewrites
    }

    /// The line under the text: the sources that fired, then how many rewrites they made —
    /// `typescript · 3 corrections`, or `typescript, personal · 4 corrections`.
    ///
    /// Each source is named once, in the order it first fired, so a misbehaving pack is
    /// identifiable without opening Settings. A rewrite with no pack came from the manual list
    /// and is named `manual`.
    ///
    /// Empty when nothing was rewritten — a review with no rewrites is never shown.
    var caption: String {
        guard !rewrites.isEmpty else { return "" }

        var names: [String] = []
        var seen: Set<String> = []
        for rewrite in rewrites {
            let name = rewrite.packName ?? Self.manualSourceName
            if seen.insert(name).inserted { names.append(name) }
        }

        let noun = rewrites.count == 1 ? "correction" : "corrections"
        return "\(names.joined(separator: ", ")) · \(rewrites.count) \(noun)"
    }

    /// What the caption calls a term that came from the manual list rather than a pack.
    private static let manualSourceName = "manual"
}
