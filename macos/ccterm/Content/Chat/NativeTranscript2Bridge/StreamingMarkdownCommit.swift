import Foundation

/// Streaming-time policy deciding *which* of an assistant message's
/// accumulated markdown text is safe to put on screen right now. Pure string
/// logic — no UI, no markdown parse — unit-tested in `StreamingMarkdownCommitTests`.
///
/// Product rule: paragraphs / headings / lists may render live as they grow,
/// but a **fenced code block** or a **GFM table** is held back in its entirety
/// until it is complete. Partial fences and partial table rows otherwise
/// reflow violently on every token (an open ``` turns the rest of the message
/// into "code", a half-built table shifts column widths each row).
///
/// `committedPrefix(of:)` returns the largest leading slice of the text
/// containing no in-progress code block or table; the caller renders that
/// slice through `MarkdownToBlocks` and shows nothing for the held remainder
/// until further text seals it. The held structure pops on screen, fully
/// formed, exactly once — on completion or at the finalized envelope.
enum StreamingMarkdownCommit {

    /// The portion of `text` safe to render now. Any trailing open code fence
    /// or still-growing table run is dropped from the returned string.
    static func committedPrefix(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        let lines = text.components(separatedBy: "\n")

        // 1) Open fenced code block wins: an odd fence count means the last
        //    fence opened a block that hasn't closed — cut before it.
        if let cut = openFenceCutIndex(lines) {
            return rejoin(lines, upTo: cut)
        }
        // 2) Trailing in-progress table: a maximal run of trailing table-row
        //    lines, not yet sealed by a blank line, is held.
        if let cut = trailingTableCutIndex(lines) {
            return rejoin(lines, upTo: cut)
        }
        return text
    }

    /// `true` when `committedPrefix` would hold something back (an open code
    /// block or an unsealed trailing table).
    static func hasHeldTail(in text: String) -> Bool {
        committedPrefix(of: text).count < text.count
    }

    // MARK: - Fenced code block

    private static func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// Line index to cut *before* when an unterminated fence is open; nil when
    /// fences are balanced.
    private static func openFenceCutIndex(_ lines: [String]) -> Int? {
        var fenceCount = 0
        var lastOpenIndex: Int?
        for (i, line) in lines.enumerated() where isFenceLine(line) {
            if fenceCount.isMultiple(of: 2) { lastOpenIndex = i }  // an opening fence
            fenceCount += 1
        }
        return fenceCount.isMultiple(of: 2) ? nil : lastOpenIndex
    }

    // MARK: - Table

    private static func isTableRowLine(_ line: String) -> Bool {
        line.drop { $0 == " " }.first == "|"
    }

    /// If the text ends with an unsealed run of table-row lines, return the
    /// first line index of that run (to cut before); nil otherwise. A blank
    /// line (`\n\n`) after the run seals it (CommonMark table termination), so
    /// it is not held.
    private static func trailingTableCutIndex(_ lines: [String]) -> Int? {
        // Count trailing empty components. "row\n" → 1 (still active), but
        // "row\n\n" → 2 (a real blank line → sealed).
        var idx = lines.count - 1
        var trailingEmpties = 0
        while idx >= 0, lines[idx].isEmpty {
            trailingEmpties += 1
            idx -= 1
        }
        if trailingEmpties >= 2 { return nil }  // blank line seals the table
        guard idx >= 0, isTableRowLine(lines[idx]) else { return nil }
        var start = idx
        while start > 0, isTableRowLine(lines[start - 1]) { start -= 1 }
        return start
    }

    // MARK: - Rejoin

    private static func rejoin(_ lines: [String], upTo cut: Int) -> String {
        guard cut > 0 else { return "" }
        var slice = Array(lines[0..<cut])
        while let last = slice.last, last.isEmpty { slice.removeLast() }
        return slice.joined(separator: "\n")
    }
}
