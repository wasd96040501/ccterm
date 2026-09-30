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
        }
    }

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
