import Foundation

/// The 11-pt line under a bubble, right-aligned, where Messages puts
/// *Delivered* (design/transcript/05-local.md, 08-live.md): it reports on the
/// message above it and is no message of its own — a command's output, or
/// where a prompt written here has got to.
public nonisolated struct Note: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case tertiary
        /// stderr: red words.
        case failure
        /// A prompt that was not sent: secondary words after a red mark — the
        /// bubble stays, and the mark says it went nowhere.
        case notSent
    }

    /// What a link in the line asks for.
    public enum Intent: Sendable, Equatable {
        /// Open what `id` names beside (`TranscriptPage.document(for:)`).
        case open(String)
        /// Take back the queued prompt `uuid`.
        case withdraw(String)
        /// Send the prompt `uuid` again.
        case resend(String)
    }

    public struct Link: Sendable, Equatable {
        public var title: String
        public var intent: Intent
        /// After the words and a ` · ` (*61k / 200k tokens (31%) · Show all*),
        /// rather than 8 pt after them (*Queued  Withdraw*).
        public var isAfterDot = false

        public init(title: String, intent: Intent, isAfterDot: Bool = false) {
            self.title = title
            self.intent = intent
            self.isAfterDot = isAfterDot
        }
    }

    /// May be empty when only the link says anything (*4 lines ›*).
    public var text: String
    public var style: Style = .tertiary
    public var link: Link?

    public init(text: String, style: Style = .tertiary, link: Link? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}
