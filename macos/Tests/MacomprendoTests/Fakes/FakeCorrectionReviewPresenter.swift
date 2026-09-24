import Foundation
@testable import Macomprendo

/// Records what was presented rather than counting calls: the decisions this presenter
/// stands in for are about *what* reaches the panel — which rewrites, in which order,
/// against which text — and a count cannot tell a replaced review from a stacked one.
@MainActor
final class FakeCorrectionReviewPresenter: CorrectionReviewPresenting {
    private(set) var presented: [CorrectionReview] = []
    private(set) var dismissCount = 0

    func present(_ review: CorrectionReview) { presented.append(review) }
    func dismiss() { dismissCount += 1 }
}
