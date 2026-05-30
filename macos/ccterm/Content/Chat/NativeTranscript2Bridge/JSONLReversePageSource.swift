import AgentSDK
import Foundation

/// Production `ReversePageSource` over a session's history JSONL — a **single
/// streaming reverse reader**, no tail/prefix split.
///
/// `nextPage` pages backward through the file via `ReverseLineReader` and
/// returns one page in **document order**. The FIRST page is sized to roughly
/// one screen by a **merge-aware entry count**: a run of consecutive tool
/// children (the messages a tool group collapses into — tool_results + groupable
/// tool_use assistants) counts as **one** entry, mirroring how the transcript
/// renders them, so the first frame fills the viewport without over-reading
/// dozens of raw lines. Every later page is a fixed line budget — pure backfill
/// throughput. `nil` once the file top is reached.
///
/// All I/O + parse runs inside `nextPage`, off-main in the pipeline's producer
/// task. The single serial caller is documented by `@unchecked Sendable`.
final class JSONLReversePageSource: ReversePageSource, @unchecked Sendable {

    private let url: URL?
    /// First-page target in **merge-aware entries** (~one screen). A run of
    /// consecutive tool children counts as 1 (they render as one tool group).
    private let firstPageEntryTarget: Int
    /// Safety cap on first-page lines so an all-tool-child history (one giant
    /// run = 1 entry) can't read the whole file chasing `firstPageEntryTarget`.
    private let firstPageLineCap: Int
    /// Fixed per-page line budget for every page after the first.
    private let pageLineBudget: Int

    private var reader: ReverseLineReader?
    private var started = false
    private var done = false
    private var isFirstPage = true

    init(
        url: URL?,
        firstPageEntryTarget: Int = 20,
        firstPageLineCap: Int = 400,
        pageLineBudget: Int = 80
    ) {
        self.url = url
        self.firstPageEntryTarget = firstPageEntryTarget
        self.firstPageLineCap = firstPageLineCap
        self.pageLineBudget = pageLineBudget
    }

    func nextPage() async -> [Message2]? {
        if done { return nil }
        if !started {
            started = true
            if let url, let r = try? ReverseLineReader(url: url) {
                reader = r
            } else {
                done = true
                return nil
            }
        }
        guard let reader else {
            done = true
            return nil
        }

        // Retry loop only fires when a whole page failed to parse (every line
        // malformed) — keep paging instead of terminating early. Normal pages
        // return on the first pass.
        while true {
            let newestFirst = collectPage(from: reader)
            if newestFirst.isEmpty {
                done = true
                return nil
            }
            // Parse in document order so the per-page `Message2Resolver` pairs
            // each tool_result with its tool_use (they sit adjacent → same
            // page). Matches the old per-phase resolver scoping.
            let messages = HistoryLoader.parseLines(newestFirst.reversed())
            if !messages.isEmpty { return messages }
        }
    }

    /// Pull one page worth of raw lines, newest-first. The first page uses the
    /// merge-aware entry budget; later pages a flat line budget.
    private func collectPage(from reader: ReverseLineReader) -> [String] {
        var newestFirst: [String] = []
        if isFirstPage {
            isFirstPage = false
            var entryCount = 0
            var inToolRun = false
            while entryCount < firstPageEntryTarget,
                newestFirst.count < firstPageLineCap
            {
                guard let line = reader.popLine() else { break }
                newestFirst.append(line)
                switch Self.countClass(of: line) {
                case .invisible:
                    break  // doesn't count, doesn't break a tool run
                case .standalone:
                    entryCount += 1
                    inToolRun = false
                case .toolChild:
                    if !inToolRun {
                        entryCount += 1
                        inToolRun = true
                    }
                }
            }
        } else {
            while newestFirst.count < pageLineBudget {
                guard let line = reader.popLine() else { break }
                newestFirst.append(line)
            }
        }
        return newestFirst
    }

    // MARK: - Merge-aware first-page counting

    private enum CountClass { case invisible, standalone, toolChild }

    /// Classify a raw JSONL line for the first-page count, mirroring
    /// `ReverseEntryBuilder`'s grouping: a tool_result user message or a
    /// groupable (all-tool_use) assistant message is a **tool child** (a run of
    /// them collapses into one tool group); any other visible message is
    /// **standalone**; everything else is **invisible** (doesn't count, doesn't
    /// break a run). Parses without `Message2Resolver` — classification only
    /// inspects the message's own blocks, so no tool-use enrichment is needed.
    private static func countClass(of line: String) -> CountClass {
        guard let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = try? Message2(json: json)
        else { return .invisible }

        if case .user(let u) = message, u.toolResultBlock?.toolUseId != nil {
            return .toolChild
        }
        if message.isGroupableAssistant {
            return .toolChild
        }
        switch message {
        case .assistant(let a) where a.isVisible: return .standalone
        case .user(let u) where u.isVisible: return .standalone
        default: return .invisible
        }
    }
}
