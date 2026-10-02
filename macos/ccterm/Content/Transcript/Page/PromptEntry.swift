import Foundation

/// What the reader sent: a prompt in the transcript, or — until the CLI's
/// replay puts it there — one written here, drawn from Send under its uuid
/// with where it has got to (design/transcript/08-live.md *A prompt, from Send
/// to the transcript*).
///
/// A prompt written here and its transcript message share an id, so when the
/// replay arrives the same rows are there: the bubble doesn't change, the
/// delivery under it goes.
nonisolated struct PromptEntry: Sendable, Equatable, Identifiable {
    /// The message's uuid when it has one, else its position.
    let id: String
    /// As written: a pasted picture is `[Image #N]` in it.
    var text: String
    /// Pictures pasted into it, which sit above its bubble.
    var images: [PromptImage] = []
    /// Where a prompt written here has got to; `nil` for the transcript's own.
    var delivery: LocalPrompt.Delivery?

    /// The bubble: its words, with *Image N* and a typed `/command` as tokens;
    /// dimmed while the CLI hasn't taken it. `nil` when nothing was said but
    /// pictures — they stand alone, with no empty bubble.
    var bubble: Bubble? {
        Bubble.words(
            text, imageNumbers: Set(images.map(\.number)), readsCommand: delivery != nil, isPending: isPending)
    }

    /// Held or queued: dimmed.
    var isPending: Bool {
        switch delivery {
        case .held, .queued: true
        case .sent, .notSent, .returned, nil: false
        }
    }

    /// The line under the bubble: *Sent when Claude is ready*, *Queued ·
    /// Withdraw*, *Not sent — the session ended · Resend*. A sent prompt is
    /// just a bubble, as in Messages.
    var note: Note? {
        switch delivery {
        case .held?:
            return Note(text: String(localized: "Sent when Claude is ready"))
        case .queued?:
            return Note(
                text: String(localized: "Queued"),
                link: Note.Link(title: String(localized: "Withdraw"), intent: .withdraw(id)))
        case .notSent(let reason)?:
            let words =
                reason.isEmpty ? String(localized: "Not sent") : String(localized: "Not sent — \(reason)")
            return Note(
                text: words, style: .failure,
                link: Note.Link(title: String(localized: "Resend"), intent: .resend(id)))
        case .sent?, .returned?, nil:
            return nil
        }
    }
}

nonisolated extension PromptEntry {
    /// The entry of a prompt `local` the transcript doesn't have yet.
    init(_ local: LocalPrompt) {
        self.init(id: local.id, text: local.text, images: [], delivery: local.delivery)
    }
}

nonisolated extension LocalCommand {
    /// The bubble the command is drawn in: the user's own message with the
    /// command as a token (05-local.md).
    var bubble: Bubble {
        switch command {
        case .slash(let name, let arguments): .slash(name: name, arguments: arguments)
        case .shell(let line): .shell(line)
        }
    }

    /// The line under the bubble: a slash command's output, cut at two lines
    /// with *Show all* under it; a `!` command's one line of output, or how
    /// many it printed as a link that opens the command's document. `nil` when
    /// it printed nothing.
    var note: Note? {
        let style: Note.Style = outputIsError ? .failure : .tertiary
        if let count = lineCount {
            return Note(text: "", link: Note.Link(title: count + " ›", intent: .open(id)))
        }
        guard let text = inlineOutput else { return nil }
        guard isOutputCut else { return Note(text: text, style: style) }
        return Note(
            text: text, style: style,
            link: Note.Link(title: String(localized: "Show all"), intent: .open(id), isBelow: true))
    }
}
