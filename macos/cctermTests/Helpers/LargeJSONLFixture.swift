import Foundation

/// Programmatic generator for a realistically-large session JSONL,
/// written to a temp file with no dependency on the user's
/// `~/.claude/projects`. Used by tests that need to drive
/// `SessionRuntime.loadHistory(overrideURL:)` against a transcript big
/// enough that Phase A's parse takes long enough for the SwiftUI
/// view-install path to race with `loadInitial`'s deferred branch.
///
/// Format & shape are anchored on real CLI-emitted JSONL
/// (`~/.claude/projects/<slug>/<sid>.jsonl`) sampled from the field:
/// the load path consumes plain `user` / `assistant` lines (any extra
/// metadata lines like `permission-mode` / `last-prompt` are tolerated
/// but produce no entries). Each `user` line carries a single text
/// content block; each `assistant` line carries a single text content
/// block and a stable `message.id`.
///
/// Field key shape uses the SDK's snake_case (`session_id`,
/// `parent_uuid`, ...) — `Message2Resolver` (the same path
/// `SessionRuntime.loadHistory` runs through) normalizes from there.
/// This is consistent with `Message2Fixtures.userTextJSONL` /
/// `assistantTextJSONL`.
struct LargeJSONLFixture {
    let url: URL
    /// Total user + assistant entries written.
    let entryCount: Int

    /// Number of entries to write. 400 is enough that the rendered
    /// transcript spans many viewports — first row and last row can't
    /// both be visible at any window size used in tests — and Phase A's
    /// off-main parse + block build takes long enough for the SwiftUI
    /// `.task` path to race with NSView install.
    init(sessionId: String, entryCount: Int = 400) throws {
        precondition(entryCount > 0)
        precondition(entryCount % 2 == 0, "entryCount must be even (user/assistant pairs)")

        let dir = FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("ccterm-large-history-\(UUID().uuidString).jsonl")
        self.entryCount = entryCount

        var lines: [String] = []
        lines.reserveCapacity(entryCount)
        var previousUuid: String? = nil
        let pairs = entryCount / 2
        for i in 0..<pairs {
            let userUuid = UUID().uuidString
            lines.append(
                Self.userLine(
                    uuid: userUuid,
                    parentUuid: previousUuid,
                    sessionId: sessionId,
                    text: Self.userText(index: i)))
            let asstUuid = UUID().uuidString
            lines.append(
                Self.assistantLine(
                    uuid: asstUuid,
                    parentUuid: userUuid,
                    sessionId: sessionId,
                    messageId: "msg_\(i)",
                    text: Self.assistantText(index: i)))
            previousUuid = asstUuid
        }
        let payload = lines.joined(separator: "\n") + "\n"
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Line generators

    private static func userLine(
        uuid: String,
        parentUuid: String?,
        sessionId: String,
        text: String
    ) -> String {
        let dict: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "parent_uuid": parentUuid ?? NSNull(),
            "session_id": sessionId,
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ]
        return encode(dict)
    }

    private static func assistantLine(
        uuid: String,
        parentUuid: String?,
        sessionId: String,
        messageId: String,
        text: String
    ) -> String {
        let dict: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "parent_uuid": parentUuid ?? NSNull(),
            "session_id": sessionId,
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        return encode(dict)
    }

    private static func encode(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Content shapes

    /// Multi-line user prompt — long enough that each row renders
    /// taller than one line; the index keeps lines unique so block ids
    /// (UUIDs) stay stable but content stays human-readable in xcresult
    /// dumps.
    private static func userText(index i: Int) -> String {
        """
        Question \(i): walk me through the layout pipeline for block kind \(i % 8).
        Cover height memoization, the lazy `heightOfRow` path, and how
        `applyInBackground` keeps the visible viewport stable when a
        prepend lands. If there's a subtle interaction with status flips
        or fold toggles, call it out.
        """
    }

    /// Assistant response with enough body text to consistently exceed
    /// a single line at typical transcript widths. Markdown-ish so the
    /// block builder produces a real paragraph block (the same path
    /// production Phase A goes through), not a degenerate single-glyph
    /// row.
    private static func assistantText(index i: Int) -> String {
        """
        Reply \(i): the row geometry is a pure function of \
        `(block, width, state)`. Heights are memoized in \
        `layoutCache` keyed by block id; the `width` field invalidates \
        entries when the table width changes so look-ups at a different \
        width treat the entry as a miss and overwrite on recompute. \
        Single source of truth is `Coordinator.blocks` — no parallel \
        rows mirror, no diff structure, mutation enters through the \
        `Change` enum and dispatches to `apply` (sync, lazy) or \
        `applyInBackground` (off-main precompute, single main hop).
        """
    }
}
