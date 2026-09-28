import AgentSDK
import Foundation

/// A line of news in the conversation that nobody said: a background task
/// ended, the user interrupted, the history was compacted.
nonisolated struct TranscriptNotice: Sendable, Equatable {
    enum Tone: Sendable, Equatable {
        case positive
        case negative
        case neutral
    }

    var symbol: String
    var tone: Tone
    var text: String
    /// What the news carried in full — an agent's answer, a monitor's event.
    var document: ToolDocument?
}

nonisolated extension TranscriptNotice {
    init(_ notification: TaskNotification, id: ToolDocument.ID) {
        switch notification.status {
        case .completed?: self.init(symbol: "checkmark.circle.fill", tone: .positive, text: notification.summary)
        case .failed?: self.init(symbol: "xmark.circle.fill", tone: .negative, text: notification.summary)
        case .stopped?, .killed?: self.init(symbol: "stop.circle.fill", tone: .neutral, text: notification.summary)
        case .unknown?, nil: self.init(symbol: "bell.fill", tone: .neutral, text: notification.summary)
        }
        let body = [notification.result, notification.event, notification.failures, notification.recovery]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !body.isEmpty {
            document = ToolDocument(id: id, title: notification.summary, symbol: symbol, content: .markdown(body))
        }
    }

    static var interruption: TranscriptNotice {
        TranscriptNotice(symbol: "hand.raised.fill", tone: .neutral, text: String(localized: "Interrupted"))
    }

    static var compaction: TranscriptNotice {
        TranscriptNotice(
            symbol: "rectangle.compress.vertical", tone: .neutral, text: String(localized: "Conversation compacted"))
    }
}
