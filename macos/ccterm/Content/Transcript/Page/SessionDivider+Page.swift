import DisplayModels
import Foundation

nonisolated extension SessionDivider {
    /// The divider of `kind`, its words composed: the label centred on the
    /// hairline and the link after it (`SessionDivider.label`, `linkTitle`).
    /// `now` is what a pause or a resume is measured against.
    init(id: String, kind: Kind, summary: String? = nil, prompt: String? = nil, now: Date = Date()) {
        self.init(
            id: id, kind: kind, summary: summary, prompt: prompt,
            label: Self.label(of: kind, now: now),
            linkTitle: Self.linkTitle(summary: summary, prompt: prompt))
    }

    /// The words centred on the hairline (05-local.md): *Conversation
    /// compacted · 168k → 14k tokens*, *Compacted automatically*,
    /// *Compacting…*, *Resumed · Tue 14:02*, or the time after a pause.
    private static func label(of kind: Kind, now: Date) -> String {
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
            return String(localized: "Resumed · \(Self.time(date, now: now))")
        case .pause(let date):
            return Self.time(date, now: now)
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
    private static func linkTitle(summary: String?, prompt: String?) -> String? {
        if summary != nil { return String(localized: "Summary") }
        if prompt != nil { return String(localized: "Prompt") }
        return nil
    }

    /// `168k`, `900`.
    private static func tokens(_ count: Int) -> String {
        count >= 1000 ? "\(Int((Double(count) / 1000).rounded()))k" : "\(count)"
    }

    /// `Tue 14:02`: the weekday within a week, the date beyond it.
    private static func time(_ date: Date, now: Date) -> String {
        let withinWeek = abs(now.timeIntervalSince(date)) < 6 * 24 * 3600
        let day: Date.FormatStyle = withinWeek ? .dateTime.weekday(.abbreviated) : .dateTime.month().day()
        return date.formatted(day.hour().minute())
    }
}

nonisolated extension SessionDivider.Continuation {
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
