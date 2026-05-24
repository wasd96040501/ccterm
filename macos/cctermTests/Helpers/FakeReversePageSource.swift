import AgentSDK
import Foundation

@testable import ccterm

/// Test double for `ReversePageSource`: yields canned
/// pages on demand so Group B controls deposit order/timing while exercising
/// the real main-owned buffer + drain. Pages are supplied **tail-first**
/// (newest page first), matching the production reverse pager's contract.
///
/// `nextPage` is invoked serially by the single producer task, so the bare
/// index is race-free in practice; `@unchecked Sendable` documents that.
final class FakeReversePageSource: ReversePageSource, @unchecked Sendable {
    private let pages: [[Message2]]
    private var index = 0

    /// Optional async hook fired just **before** the page at the given index is
    /// returned, on the producer's executor. Lets a test interleave a side
    /// effect (e.g. `pipeline.retarget(width:)`) between specific pages
    /// deterministically — the producer reads the pipeline width *after*
    /// `nextPage` returns, so a width changed here lands on this very page.
    var onBeforePage: (@Sendable (Int) async -> Void)?

    /// - Parameter pages: tail-first list of document-order message slices.
    init(_ pages: [[Message2]]) {
        self.pages = pages
    }

    func nextPage() async -> [Message2]? {
        guard index < pages.count else { return nil }
        let current = index
        await onBeforePage?(current)
        defer { index += 1 }
        return pages[current]
    }
}
