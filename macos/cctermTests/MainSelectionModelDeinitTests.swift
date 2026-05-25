import XCTest

@testable import ccterm

/// Regression guard for a flaky double-free that took down any test
/// class which built a `MainSelectionModel` and let it deallocate from a
/// **synchronous** XCTest method body (`ChatComposeStackRoutingTests`,
/// `DetailRouterContainmentTests`, `TranscriptHostReentryLayoutCacheTests`,
/// `DetailRouterLayoutDiagnosticsTests`).
///
/// Root cause: the project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
/// `SWIFT_APPROACHABLE_CONCURRENCY`, so a `@MainActor` class gets an
/// **isolated deinit** — deallocation hops to the main actor through
/// `swift_task_deinitOnExecutorImpl`. XCTest invokes a synchronous test
/// method via `-[NSInvocation invoke]`, i.e. NOT inside a Swift
/// concurrency task, so there is no current task / task-local stack. The
/// runtime's `TaskLocal::StopLookupScope` teardown on that hop then frees
/// a pointer it never allocated → `___BUG_IN_CLIENT_OF_LIBMALLOC_…`.
/// `nonisolated deinit` on `MainSelectionModel` removes the executor hop
/// (its teardown needs no isolation), so dealloc runs inline on the
/// releasing thread and the buggy runtime path is never entered.
///
/// This test is intentionally **synchronous** (no `async`) — an `async`
/// test runs inside a Swift task, which supplies the task context the
/// crash needs to be absent, so it would mask the bug. The tight
/// alloc/release loop makes the corruption hit deterministically rather
/// than once-every-few-runs.
@MainActor
final class MainSelectionModelDeinitTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Allocate and release many models from a synchronous method body.
    /// Without `nonisolated deinit` this corrupts the task-local stack
    /// and aborts; with it, every release is a plain inline deinit.
    func testSynchronousDeallocDoesNotCorruptTaskLocalStack() {
        for i in 0..<5_000 {
            autoreleasepool {
                let model = MainSelectionModel()
                model.selection = .session("s-\(i)")
                model.draftSessionId = "d-\(i)"
                // Touch a derived property so the instance is genuinely
                // used (and not optimised away before its deinit).
                XCTAssertEqual(model.effectiveSessionId, "s-\(i)")
            }
        }
    }

}
