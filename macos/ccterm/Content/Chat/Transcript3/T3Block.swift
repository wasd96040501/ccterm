import Foundation

/// Foundation-only render IR for one transcript row.
///
/// Deliberately smaller than `NativeTranscript2/Model/Block` — no `NSImage`,
/// no SwiftUI, no NSColor. The image case carries an `ImageSource`
/// (URL / inline data / remote) that the view layer resolves at draw time;
/// the model itself never crosses into AppKit. Grouping semantics (all the
/// consecutive tool_use / tool_result assistant + user messages fold into
/// one `.toolGroup`) live in `BlockBuilder`, not in `T3Block` itself.
///
/// The `T3` prefix disambiguates from the old `NativeTranscript2/Model/Block`
/// during the transition — both types coexist in the `ccterm` module until
/// the old renderer retires. When it does, this file (and everything else
/// in `Transcript3/`) drops the prefix.
public struct T3Block: Identifiable, Sendable {

    public typealias ID = UUID
    public let id: ID
    public let kind: Kind

    public init(id: ID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public enum Kind: Sendable {
        /// Assistant plain-text paragraph. Plain string for now; when
        /// markdown lands it becomes an inline IR the layout can rasterise.
        case assistantText(String)

        /// User bubble (right-aligned, background-filled). Plain text +
        /// optional attachments in the same envelope.
        case userBubble(text: String, attachments: [T3ImageSource])

        /// System / metadata notice (small, muted). Session start / end
        /// timestamps, model switches, permission-mode toggles.
        case system(String)

        /// Fenced code block. `language` is the fence tag (`swift`, `bash`,
        /// or nil for untagged). No syntax highlighting in the first pass —
        /// mono-font attributed string until the syntax engine is wired.
        case codeBlock(language: String?, code: String)

        /// One tool call — the assistant's `tool_use` merged with its
        /// paired user `tool_result` if the pair resolved. Multiple
        /// consecutive tool calls collapse into `.toolGroup` upstream.
        case toolCall(ToolCall)

        /// Two or more consecutive tool calls rendered as a single row
        /// (matches the pre-refactor `.toolGroup` UX).
        case toolGroup(calls: [ToolCall])
    }

    public struct ToolCall: Sendable {
        public let name: String
        /// One-line summary of the input, already formatted for display.
        public let inputSummary: String
        /// Non-nil once the paired `tool_result` has been resolved. Nil
        /// while the call is still in flight (live path — history load
        /// always has this filled unless the CLI truncated the file).
        public let output: ToolOutput?

        public init(name: String, inputSummary: String, output: ToolOutput?) {
            self.name = name
            self.inputSummary = inputSummary
            self.output = output
        }
    }

    public struct ToolOutput: Sendable {
        public let text: String
        public let isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }
}

/// Foundation-only image reference. The view layer resolves this into
/// something drawable at render time; the Store never sees `NSImage`.
public enum T3ImageSource: Sendable {
    case file(URL)
    case remote(URL)
    case inline(Data, mediaType: String)
}
