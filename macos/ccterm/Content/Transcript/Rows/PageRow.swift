import Foundation

/// One row of a transcript tab's `TranscriptView`: what a page entry becomes
/// once the reader's disclosure is applied.
///
/// An entry is one or more rows. Every line of a run is its own row — the
/// run's line, each item shown, *Show N more*, the approval card — so an item
/// is scrolled to, recycled and measured like any row, and expanding a run is
/// inserting rows, which slide in around the run's line. A plan, and a
/// message from any agent but a subagent, are a caption row and a
/// `.markdown` row: TranscriptKit draws the words. A subagent's report is one
/// line that opens beside.
nonisolated struct PageRow: Sendable, Equatable, Identifiable {
    /// A row's identity: the entry it belongs to, and which of its rows.
    /// Stable across disclosure, so TranscriptKit's cache holds.
    struct ID: Hashable, Sendable {
        let entry: String
        let part: Part
    }

    enum Part: Hashable, Sendable {
        /// The entry's own row: a run's or news's line, a prompt, a reply, a
        /// capsule, a divider, a question.
        case main
        /// A message's or plan's caption, above its words.
        case caption
        /// A message's or plan's words, under its caption.
        case body
        /// One item of an expanded run or news row, by its id.
        case item(String)
        /// *Show N more* under an expanded run's twelfth item.
        case more
        /// The approval card of a run waiting for the reader.
        case approval
        /// A waiting plan's Keep Planning / Approve.
        case decision
    }

    enum Kind: Sendable, Equatable {
        /// What the user typed — TranscriptKit's bubble.
        case prompt(String)
        /// Markdown TranscriptKit renders: a reply, a message's or plan's words.
        case markdown(String)
        case runLine(ToolRun, RunDisclosure)
        case runItem(RunItem)
        /// *Show N more*: `hidden` items past the list's end.
        case showMore(runID: String, hidden: Int)
        case approval(Approval)
        case newsLine(NewsRun, RunDisclosure)
        case newsItem(TaskNews)
        /// A subagent's report: its line, which opens the words beside.
        case agentReport(AgentMessage)
        case command(LocalCommand)
        case divider(SessionDivider)
        case interruption
        case caption(Caption)
        case question(Question)
        /// Keep Planning / Approve for the plan of call `callID`.
        case planDecision(callID: String)
    }

    let id: ID
    let kind: Kind

    /// The id this row opens beside the transcript when clicked — and so what
    /// ↑ / ↓ step through — or `nil` for a row that only toggles or opens
    /// nothing. An item, or a line that is its only item.
    var opens: String? {
        switch kind {
        case .runItem(let item): item.id
        case .runLine(let run, _): run.isSingle ? run.items[0].id : nil
        case .newsItem(let news): news.id
        case .newsLine(let news, _): news.isSingle ? news.news[0].id : nil
        case .agentReport(let message): message.id
        default: nil
        }
    }
}

nonisolated extension PageRow {
    /// The rows of a whole page, every run collapsed.
    static func rows(for page: TranscriptPage) -> [PageRow] {
        page.entries.flatMap { rows(for: $0, disclosure: .collapsed) }
    }

    /// The rows of one entry, its runs disclosed as `disclosure` says.
    static func rows(for entry: TranscriptEntry, disclosure: RunDisclosure) -> [PageRow] {
        let id = entry.id
        func row(_ part: Part, _ kind: Kind) -> PageRow { PageRow(id: ID(entry: id, part: part), kind: kind) }
        switch entry {
        case .prompt(_, let text):
            return [row(.main, .prompt(text))]
        case .reply(_, let markdown):
            return [row(.main, .markdown(markdown))]
        case .run(let run):
            let disclosure = run.isSingle ? .collapsed : disclosure
            var rows = [row(.main, .runLine(run, disclosure))]
            if disclosure != .collapsed {
                let shown =
                    disclosure == .showingAll ? run.items : Array(run.items.prefix(PageThresholds.listedItems))
                rows += shown.map { row(.item($0.id), .runItem($0)) }
                if shown.count < run.items.count {
                    rows.append(row(.more, .showMore(runID: run.id, hidden: run.items.count - shown.count)))
                }
            }
            if let waiting = run.waitingCall {
                rows.append(row(.approval, .approval(Approval(waiting))))
            }
            return rows
        case .news(let news):
            let disclosure = news.isSingle ? .collapsed : disclosure
            var rows = [row(.main, .newsLine(news, disclosure))]
            if disclosure != .collapsed {
                rows += news.news.map { row(.item($0.id), .newsItem($0)) }
            }
            return rows
        case .command(let command):
            return [row(.main, .command(command))]
        case .divider(let divider):
            return [row(.main, .divider(divider))]
        case .interruption:
            return [row(.main, .interruption)]
        case .agentMessage(let message):
            if message.opensBeside { return [row(.main, .agentReport(message))] }
            return [row(.caption, .caption(message.caption)), row(.body, .markdown(Self.quoted(message.text)))]
        case .question(let question):
            return [row(.main, .question(question))]
        case .plan(let plan):
            var rows = [
                row(.caption, .caption(plan.caption)),
                row(.body, .markdown(plan.text)),
            ]
            if plan.isWaiting { rows.append(row(.decision, .planDecision(callID: plan.id))) }
            return rows
        }
    }

    /// `text` as a blockquote: TranscriptKit's form for someone else's words.
    static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }
}
