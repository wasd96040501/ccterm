import AgentSDK
import Foundation

/// Production `ReversePageSource`: a session's history as the CLI resumes it
/// — `AgentSDK.Transcript`, the conversation chain with rewinds, forks and
/// compactions resolved, not the file's raw lines — served newest page first.
///
/// The file is read once, on the first `nextPage` (off-main, in the
/// pipeline's producer task). The first page is sized to roughly one screen
/// by a **merge-aware entry count**: a run of consecutive tool children (the
/// messages a tool group collapses into — tool_results and groupable tool_use
/// assistants) counts as **one** entry, mirroring how the transcript renders
/// them. Every later page is a fixed message count — pure backfill
/// throughput. `nil` once the oldest message has been served.
///
/// The single serial caller (the producer task) is what makes
/// `@unchecked Sendable` sound.
final class TranscriptPageSource: ReversePageSource, @unchecked Sendable {

    private let url: URL?
    /// First-page target in **merge-aware entries** (~one screen).
    private let firstPageEntryTarget: Int
    /// Cap on first-page messages so an all-tool-child history (one giant run
    /// = 1 entry) can't pull everything into the first page.
    private let firstPageMessageCap: Int
    /// Messages per page after the first.
    private let pageSize: Int

    /// Messages not yet served, in document order; pages are cut from the end.
    private var remaining: ArraySlice<Message>?
    private var isFirstPage = true

    init(url: URL?, firstPageEntryTarget: Int = 20, firstPageMessageCap: Int = 400, pageSize: Int = 80) {
        self.url = url
        self.firstPageEntryTarget = firstPageEntryTarget
        self.firstPageMessageCap = firstPageMessageCap
        self.pageSize = pageSize
    }

    func nextPage() async -> [Message]? {
        if remaining == nil {
            let transcript = url.flatMap { try? Transcript(contentsOf: $0) }
            remaining = ArraySlice(transcript?.messages ?? [])
        }
        guard var rest = remaining, !rest.isEmpty else { return nil }
        let count = isFirstPage ? firstPageCount(rest) : min(pageSize, rest.count)
        isFirstPage = false
        let page = Array(rest.suffix(count))
        rest.removeLast(count)
        remaining = rest
        return page
    }

    /// How many of the newest messages make up ~one screen of entries.
    private func firstPageCount(_ messages: ArraySlice<Message>) -> Int {
        var count = 0
        var entries = 0
        var inToolRun = false
        for message in messages.reversed() {
            guard entries < firstPageEntryTarget, count < firstPageMessageCap else { break }
            count += 1
            switch Self.countClass(of: message) {
            case .invisible:
                break  // doesn't count, doesn't break a tool run
            case .standalone:
                entries += 1
                inToolRun = false
            case .toolChild:
                if !inToolRun {
                    entries += 1
                    inToolRun = true
                }
            }
        }
        return count
    }

    private enum CountClass { case invisible, standalone, toolChild }

    /// Mirrors `ReverseEntryBuilder`'s grouping: a tool_result or a groupable
    /// assistant is a **tool child** (a run collapses into one tool group); any
    /// other visible message is **standalone**; the rest is **invisible**.
    private static func countClass(of message: Message) -> CountClass {
        switch message {
        case .user(let u) where u.toolResult != nil: return .toolChild
        case _ where message.isGroupableAssistant: return .toolChild
        case .assistant(let a) where a.isVisible: return .standalone
        case .user(let u) where u.isVisible: return .standalone
        default: return .invisible
        }
    }
}
