import Foundation

/// The documents a session tab opens beside itself from its own controls —
/// the failure's *Show Log* and the context ring — as pre-resolved
/// `Document`s: nothing in the transcript backs them, so the tab never reloads
/// them. Both are the command-output shape, which draws its words in a
/// monospaced block. Pure.
nonisolated enum SessionTabDocuments {
    /// What the CLI wrote to stderr before it quit; says so when it wrote none.
    static func log(_ failure: SessionFailure, transcriptURL: URL) -> Document {
        let text = failure.log.trimmingCharacters(in: .whitespacesAndNewlines)
        return Document(
            reference: DocumentReference(transcriptURL: transcriptURL, id: "log"),
            content: .commandOutput(
                LocalCommand(
                    id: "log", command: .slash(name: String(localized: "Session Log"), arguments: ""),
                    output: text.isEmpty ? String(localized: "Claude wrote nothing to its log.") : text,
                    errorOutput: "")),
            workingDirectory: nil)
    }

    /// How full the context is, as the ring says it.
    static func context(usage: Double, transcriptURL: URL) -> Document {
        let percent = Int((min(max(usage, 0), 1) * 100).rounded())
        return Document(
            reference: DocumentReference(transcriptURL: transcriptURL, id: "context-\(percent)"),
            content: .commandOutput(
                LocalCommand(
                    id: "context", command: .slash(name: "/context", arguments: ""),
                    output: String(localized: "\(percent)% of the context window is in use."),
                    errorOutput: "")),
            workingDirectory: nil)
    }
}
