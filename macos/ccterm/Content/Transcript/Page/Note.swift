import Foundation

/// The 11-pt line under a bubble, right-aligned, where Messages puts
/// *Delivered* (design/transcript/05-local.md, 08-live.md): it reports on the
/// message above it and is no message of its own — a command's output, or
/// where a prompt written here has got to.
nonisolated struct Note: Sendable, Equatable {
    enum Style: Sendable, Equatable {
        case tertiary
        /// stderr: red words.
        case failure
        /// A prompt that was not sent: secondary words after a red mark — the
        /// bubble stays, and the mark says it went nowhere.
        case notSent
    }

    /// What a link in the line asks for.
    enum Intent: Sendable, Equatable {
        /// Open what `id` names beside (`TranscriptPage.document(for:)`).
        case open(String)
        /// Take back the queued prompt `uuid`.
        case withdraw(String)
        /// Send the prompt `uuid` again.
        case resend(String)
    }

    struct Link: Sendable, Equatable {
        var title: String
        var intent: Intent
        /// On its own line under the words (*Show all*) rather than after
        /// them (*Queued · Withdraw*).
        var isBelow = false
    }

    /// May be empty when only the link says anything (*4 lines ›*).
    var text: String
    var style: Style = .tertiary
    var link: Link?
}
