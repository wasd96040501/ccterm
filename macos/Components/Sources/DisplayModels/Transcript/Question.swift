import Foundation

/// An `AskUserQuestion` call: questions put to the reader, and the answers
/// given — kept together, like a form filled in
/// (design/transcript/07-talk.md). It breaks out of the run around it.
public nonisolated struct Question: Sendable, Equatable, Identifiable {
    /// One question as the row shows it: the header as its title, the
    /// question, and the options with the chosen ones marked.
    public struct Item: Sendable, Equatable {
        public struct Option: Sendable, Equatable {
            public let label: String
            /// 12-pt tertiary under the label; may be empty.
            public let detail: String
            public let isChosen: Bool
            /// Shown beside the list, monospaced, while this option is picked
            /// (single-select only).
            public var preview: String? = nil

            public init(label: String, detail: String, isChosen: Bool, preview: String? = nil) {
                self.label = label
                self.detail = detail
                self.isChosen = isChosen
                self.preview = preview
            }
        }

        public let header: String
        public let text: String
        /// What the model offered; an answer that was typed (*Other*) is one more,
        /// chosen, with *Other* as its detail.
        public let options: [Option]
        /// Checkboxes rather than radio buttons while it waits.
        public let allowsSeveral: Bool

        public init(header: String, text: String, options: [Option], allowsSeveral: Bool) {
            self.header = header
            self.text = text
            self.options = options
            self.allowsSeveral = allowsSeveral
        }

        /// Whether a preview is shown beside the options while it waits.
        public var hasPreviews: Bool { !allowsSeveral && options.contains { $0.preview != nil } }
    }

    /// The call's id: what a decision answers.
    public let id: String
    public let items: [Item]
    /// Waiting for the reader's answer: the options are controls, and
    /// **Submit** answers.
    public let isWaiting: Bool
    /// What a question the reader didn't answer says under it: *Not answered —
    /// talked over in the conversation* after *Chat About This*, *Not answered*
    /// after ⎋. `nil` for an answered or waiting one.
    public let outcome: String?
    /// *Chat About This* answered it: the card shows the questions without
    /// their options (07-talk.md; preview.js `row.chat`).
    public let isTalkedOver: Bool

    /// `questionmark.bubble`, coral while it waits.
    public var tile: Tile { Tile(glyph: .question, state: isWaiting ? .waiting : .done) }

    public init(id: String, items: [Item], isWaiting: Bool, outcome: String?, isTalkedOver: Bool) {
        self.id = id
        self.items = items
        self.isWaiting = isWaiting
        self.outcome = outcome
        self.isTalkedOver = isTalkedOver
    }
}
