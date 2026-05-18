import AgentSDK
import Foundation

// MARK: - Messaging commands

extension SessionHandle2 {

    /// Interrupt the current turn. Guards on `isRunning`
    /// (`pendingTurnCount > 0`), not `status == .responding` — `send()` bumps
    /// `pendingTurnCount` synchronously, but status only flips to
    /// `.responding` after the CLI echo. During the 100-300ms gap the stop
    /// button is already visible, so the old `.responding` guard would
    /// reject the click and the user sees "click did nothing".
    ///
    /// Side effects ordered for "UI feedback first":
    /// 1. `pendingTurnCount = 0`: isRunning flips false immediately, bar
    ///    switches back to send state.
    /// 2. `.responding` → `.interrupting` (other statuses untouched, so we
    ///    don't pollute `.starting` / `.idle` "echo not received yet" sub-states).
    /// 3. Mark queued local user entries as failed, so a later
    ///    `flushBootstrapBacklog` (after bootstrap finishes) doesn't resend
    ///    them to the CLI — otherwise stop would still send the message.
    /// 4. Send RPC if `cliClient` is alive; skip otherwise (bootstrap not
    ///    attached yet) — no CLI means no turn to interrupt; local cleanup
    ///    already satisfies the semantics.
    func interrupt() {
        guard isRunning else {
            appLog(.info, "SessionHandle2", "interrupt() ignored — not running status=\(status) \(sessionId)")
            return
        }
        appLog(.info, "SessionHandle2", "interrupt() begin status=\(status) \(sessionId)")
        pendingTurnCount = 0
        if status == .responding {
            status = .interrupting
        }
        failQueuedEntries(reason: "interrupted")
        guard let cliClient else {
            appLog(.info, "SessionHandle2", "interrupt() no cliClient — local-only \(sessionId)")
            return
        }
        cliClient.interrupt { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.status == .interrupting {
                    self.status = .idle
                }
                appLog(.info, "SessionHandle2", "interrupt() ack \(self.sessionId)")
            }
        }
    }

    /// Cancel a user message.
    ///
    /// - `entry.delivery` is `.queued` / `.failed`: remove from `messages`.
    /// - `.confirmed` / nil (non-user entry): no-op.
    /// - id not found, or entry is not a user message: no-op.
    ///
    /// Caveat: a `.queued` message may already have been written to CLI
    /// stdin (queued CLI-side). Local removal only erases the UI entry and
    /// cannot prevent the CLI from processing it. If the CLI proceeds, it
    /// will emit a stray user echo with no matching local entry; `receive`
    /// will then take the append branch and surface it as a new message.
    /// Known limitation — real remote cancel requires CLI support, which
    /// doesn't exist yet.
    func cancelMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        guard case .single(let single) = messages[idx] else { return }
        let isUserEntry: Bool = {
            switch single.payload {
            case .localUser: return true
            case .remote(let m):
                if case .user = m { return true }
                return false
            }
        }()
        guard isUserEntry else { return }
        switch single.delivery {
        case .queued, .failed:
            let removed = messages.remove(at: idx)
            onMessagesChange?(.removed(removed))
        default:
            break
        }
    }
}
