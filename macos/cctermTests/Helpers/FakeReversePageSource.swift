import AgentSDK
import Foundation

@testable import ccterm

/// Test double for `ReversePageSource` (REFACTOR-PLAN §12.3): yields canned
/// pages on demand so Group B controls deposit order/timing while exercising
/// the real main-owned buffer + drain. Pages are supplied **tail-first**
/// (newest page first), matching the production reverse pager's contract.
///
/// `nextPage` is invoked serially by the single producer task, so the bare
/// index is race-free in practice; `@unchecked Sendable` documents that.
final class FakeReversePageSource: ReversePageSource, @unchecked Sendable {
    private let pages: [[Message2]]
    private var index = 0

    /// - Parameter pages: tail-first list of document-order message slices.
    init(_ pages: [[Message2]]) {
        self.pages = pages
    }

    func nextPage() async -> [Message2]? {
        guard index < pages.count else { return nil }
        defer { index += 1 }
        return pages[index]
    }
}
