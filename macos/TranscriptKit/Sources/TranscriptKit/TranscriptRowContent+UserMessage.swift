import Foundation

extension TranscriptRowContent {

    /// What a user's bubble holds: plain words, with runs set apart as *tokens*,
    /// and whether it is still waiting to be sent.
    ///
    /// **A value nested in the row vocabulary, not a fourth case.** A command
    /// (`/model`), a shell command (`!`) and a pasted picture (*Image 1*) are the
    /// user's own message, so each is the user's bubble with part of it inset —
    /// richer *content* of the one case, which the closed vocabulary allows (the
    /// package's CLAUDE.md §4). It is nested because a top-level `UserMessage`
    /// would be ambiguous in an app that also imports a model of the same name.
    public struct UserMessage: Sendable, Equatable {

        /// A run of ``text`` set apart: an inset of the bubble's own colour (the
        /// accent at 16 % over it, 5-pt radius, 4 pt of padding either side) with
        /// the run in SF Mono 13 medium, sitting on the line's baseline without
        /// changing the line's height.
        public struct Token: Sendable, Equatable {

            public enum Kind: Sendable, Equatable {
                /// A command's name: its first character — the `/` or the `!` —
                /// in secondary ink, the rest in label ink.
                case command
                /// A picture the message names (*Image 1*): the `photo` glyph in
                /// front of its words. It is a link to `URL` — hover and click are
                /// reported through the transcript's delegate like any link's.
                case image(URL)
            }

            /// UTF-16 offsets into ``UserMessage/text``. A token that reaches
            /// outside it, or overlaps an earlier one, is ignored.
            public var range: Range<Int>
            public var kind: Kind
            /// What the hover says: a skill's full name
            /// (`/skill-creator:skill-creator`) where the token shows the short one.
            public var toolTip: String?

            public init(range: Range<Int>, kind: Kind, toolTip: String? = nil) {
                self.range = range
                self.kind = kind
                self.toolTip = toolTip
            }
        }

        public var text: String
        public var tokens: [Token]
        /// Drawn at half strength: sent from here and not yet taken by the CLI.
        public var isPending: Bool
        /// The words are a shell command: SF Mono 12.5 in place of the body face.
        public var isMonospaced: Bool

        public init(
            _ text: String, tokens: [Token] = [], isPending: Bool = false, isMonospaced: Bool = false
        ) {
            self.text = text
            self.tokens = tokens
            self.isPending = isPending
            self.isMonospaced = isMonospaced
        }
    }
}

extension TranscriptRowContent.UserMessage: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
