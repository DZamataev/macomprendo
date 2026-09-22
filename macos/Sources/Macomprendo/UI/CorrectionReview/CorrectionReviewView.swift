import AppKit
import SwiftUI

/// Where the review panel sits and how big it is. Top-centre of the screen the mouse is on,
/// the placement the recording HUD already uses because it keeps the panel off the line the
/// user is dictating into — this one takes mouse events, so covering the caret would be worse
/// than cosmetic.
enum CorrectionReviewLayout {
    /// Wider than the HUD: this panel carries a sentence, not a status word.
    static let size = CGSize(width: 420, height: 132)

    static func origin(panelSize: CGSize,
                       screenFrame: CGRect,
                       visibleFrame: CGRect) -> CGPoint {
        HUDLayout.origin(panelSize: panelSize,
                         screenFrame: screenFrame,
                         visibleFrame: visibleFrame,
                         topInset: HUDLayout.topInset)
    }
}

/// The inserted text with every rewritten span marked, and the caption naming what fired.
///
/// The marks are an underline in the surrounding weight, never a recolour: a recoloured word
/// reads as an error, and these are corrections that already landed in the document.
struct CorrectionReviewView: View {
    @ObservedObject var controller: CorrectionReviewController

    /// The underline colour. Green, and only the underline — the text keeps its own colour.
    nonisolated static let markColor = NSColor.systemGreen

    /// Builds the marked text as one attributed string rather than a row of views, so the
    /// text wraps as a paragraph instead of breaking at every rewrite.
    ///
    /// Each marked span carries the recogniser's original spelling as its tooltip: hovering
    /// is how the user reads what the model actually produced.
    nonisolated static func markedText(for review: CorrectionReview) -> AttributedString {
        var attributed = AttributedString(review.text)
        for rewrite in review.rewrites {
            guard let range = Range(rewrite.range, in: attributed) else { continue }
            attributed[range].appKit.underlineStyle = .single
            attributed[range].appKit.underlineColor = markColor
            attributed[range].appKit.toolTip = rewrite.original
        }
        return attributed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let review = controller.review {
                MarkedText(attributed: Self.markedText(for: review))
                Text(review.caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(width: CorrectionReviewLayout.size.width,
               height: CorrectionReviewLayout.size.height,
               alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .onHover { controller.pointerInsideChanged($0) }
    }
}

/// An `NSTextView` rather than SwiftUI's `Text`: the per-span tooltip that reveals the
/// original spelling is an AppKit text attribute, and `Text` has no per-run equivalent.
/// Thin by design — it renders an attributed string and nothing else.
private struct MarkedText: NSViewRepresentable {
    let attributed: AttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let string = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
        ]
        string.addAttributes(attributes,
                             range: NSRange(location: 0, length: string.length))
        view.textStorage?.setAttributedString(string)
    }
}
