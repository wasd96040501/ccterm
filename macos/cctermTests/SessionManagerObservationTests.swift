import Observation
import XCTest

@testable import ccterm

/// `SessionManager.handles` must be observation-tracked so SwiftUI views
/// that read it via `existingSession(_:)` get re-rendered when a handle is
/// later allocated.
///
/// Regression target: a sidebar row's body reads
/// `manager.existingSession(sessionId)` to drive the per-row running /
/// unread indicator. The first render of a cold-start row sees no cached
/// handle (the user hasn't clicked the session yet), so `existingSession`
/// returns nil. If `handles` is `@ObservationIgnored`, that read never
/// subscribes to the dict — and when the user later clicks the session
/// and `prepareDraftSession(_:)` inserts a handle, no re-render fires. The row
/// continues to display "no handle" indefinitely, so the trailing
/// running-pill never appears even when `pendingTurnCount > 0`.
///
/// The fix is purely a property-level annotation flip on `handles`. The
/// assertion here mirrors what SwiftUI does internally via
/// `withObservationTracking` — calling `existingSession` inside the
/// tracking block must register interest in the dict, so that a
/// subsequent `prepareDraft` mutation fires `onChange`.
@MainActor
final class SessionManagerObservationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Sidebar's reading pattern: read `existingSession(sid)` (returns
    /// nil for a session that has never been opened in this process),
    /// then expect the read to register observation so a later
    /// `prepareDraftSession(sid)` insertion triggers `onChange`.
    ///
    /// Without observation on `handles`, the read goes through an
    /// `@ObservationIgnored` storage and `onChange` never fires — the
    /// sidebar row stays stuck on `isRunning: false`.
    func testExistingHandleReadRegistersObservationOnHandlesDict() {
        let manager = SessionManager(repository: InMemorySessionRepository())
        let sid = UUID().uuidString

        let observed = XCTestExpectation(
            description: "withObservationTracking onChange fires after prepareDraft mutates handles")

        withObservationTracking {
            // Same call site the sidebar's SidebarHistoryRow body uses.
            // Returns nil here — no handle has been created yet — but
            // the read itself must subscribe to the dict.
            _ = manager.existingSession(sid)
        } onChange: {
            observed.fulfill()
        }

        // Mutate via the public API. `prepareDraft` is idempotent get-
        // or-create — for a fresh sid it allocates and inserts into the
        // handles dict, which is the production trigger that should
        // wake the sidebar row.
        _ = manager.prepareDraftSession(sid)

        wait(for: [observed], timeout: 1.0)
    }

    /// `session(_:)` is the other code path that mutates `handles` (the
    /// record-required variant used by `RootView2.onChange`). Same
    /// observation contract: a prior `existingSession` read must wake.
    func testSessionCreationAlsoTriggersObservation() {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid,
                title: "existing",
                cwd: "/tmp/some-existing",
                status: .created
            ))
        let manager = SessionManager(repository: repo)

        let observed = XCTestExpectation(
            description: "withObservationTracking onChange fires after session() mutates handles")

        withObservationTracking {
            _ = manager.existingSession(sid)
        } onChange: {
            observed.fulfill()
        }

        _ = manager.session(sid)

        wait(for: [observed], timeout: 1.0)
    }
}
