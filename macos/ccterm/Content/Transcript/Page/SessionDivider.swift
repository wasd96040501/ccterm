import Foundation

/// A hairline across the column where the session's shape changed
/// (design/transcript/05-local.md): it was compacted, it ended and was
/// resumed, or it was left alone for more than an hour.
nonisolated struct SessionDivider: Sendable, Equatable, Identifiable {
    let id: String
    let kind: Kind
    /// The compaction summary the model continued from — what *Summary*
    /// opens beside. Only a compaction has one.
    var summary: String?
    /// The words the CLI wrote to start a turn nobody typed — what *Prompt*
    /// opens beside (design/transcript/06-agent-messages.md).
    var prompt: String?

    init(id: String, kind: Kind, summary: String? = nil, prompt: String? = nil) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.prompt = prompt
    }

    /// Why the CLI started a turn on its own.
    enum Continuation: Sendable, Equatable {
        case usageLimitReset
        /// A plan approved in the browser (ultraplan), handed back.
        case planApproved
        /// A goal the reader set with `/goal`: they started it, so it has its
        /// own words.
        case goal
        case automatic

        /// What the known texts say (`origin.kind: "auto-continuation"`).
        init(text: String) {
            if text.contains("usage limit has reset") {
                self = .usageLimitReset
            } else if text.contains("approved the ultraplan in the browser") {
                self = .planApproved
            } else if text.hasPrefix("Goal set:") {
                self = .goal
            } else {
                self = .automatic
            }
        }
    }

    enum Kind: Sendable, Equatable {
        /// `/compact`, or the CLI's own. Token counts when the boundary
        /// recorded them.
        case compacted(automatically: Bool, preTokens: Int?, postTokens: Int?)
        /// Compacting now: the travelling arc, *Compacting…*.
        case compacting
        /// The session ended with `/exit` and was resumed at this time.
        case resumed(Date)
        /// Nothing happened for more than an hour; the time the next row came.
        case pause(Date)
        /// The CLI started a turn with its own words.
        case continued(Continuation)
        /// The session was ended and resumed in another account, on a model
        /// (design/transcript/08-live.md *Another account restarts the session*).
        case restarted(account: String, model: String)
    }

    /// The words centred on the hairline (05-local.md): *Conversation
    /// compacted · 168k → 14k tokens*, *Compacted automatically*,
    /// *Compacting…*, *Resumed · Tue 14:02*, or the time after a pause.
    /// *Summary*, when there is one, is the view's link after it.
    var label: String {
        switch kind {
        case .compacted(let automatically, let pre, let post):
            let what =
                automatically
                ? String(localized: "Compacted automatically") : String(localized: "Conversation compacted")
            guard let pre, let post else { return what }
            let tokens = String(localized: "\(Self.tokens(pre)) → \(Self.tokens(post)) tokens")
            return "\(what) · \(tokens)"
        case .compacting:
            return String(localized: "Compacting…")
        case .resumed(let date):
            return String(localized: "Resumed · \(Self.time(date))")
        case .pause(let date):
            return Self.time(date)
        case .continued(let why):
            switch why {
            case .usageLimitReset: return String(localized: "Continued after the usage limit reset")
            case .planApproved: return String(localized: "Continued with the plan approved in the browser")
            case .goal: return String(localized: "Goal set")
            case .automatic: return String(localized: "Continued automatically")
            }
        case .restarted(let account, let model):
            return String(localized: "Restarted as \(account) · \(model)")
        }
    }

    /// The link after the label: *Summary* of a compaction, *Prompt* of a turn
    /// the CLI started; `nil` when there is nothing to open.
    var linkTitle: String? {
        if summary != nil { return String(localized: "Summary") }
        if prompt != nil { return String(localized: "Prompt") }
        return nil
    }

    /// What the link opens beside.
    var opensDocument: Bool { linkTitle != nil }

    /// `168k`, `900`.
    private static func tokens(_ count: Int) -> String {
        count >= 1000 ? "\(Int((Double(count) / 1000).rounded()))k" : "\(count)"
    }

    /// `Tue 14:02`: the weekday within a week, the date beyond it.
    private static func time(_ date: Date, now: Date = Date()) -> String {
        let withinWeek = abs(now.timeIntervalSince(date)) < 6 * 24 * 3600
        let day: Date.FormatStyle = withinWeek ? .dateTime.weekday(.abbreviated) : .dateTime.month().day()
        return date.formatted(day.hour().minute())
    }
}
