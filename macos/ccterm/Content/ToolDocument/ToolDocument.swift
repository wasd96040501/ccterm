import AgentSDK
import Foundation

/// Something a transcript opens beside itself in an editor tab: the file a tool
/// read, the change it made, a command's output, a subagent's report.
///
/// Data only — what to show, never how. The tab (`ToolDocumentViewController`)
/// decides the view; the card that offers it only knows that there is one.
nonisolated struct ToolDocument: Sendable, Equatable {
    /// Which transcript it came from and what in it — a tool call's id, or a
    /// notification's. What the editor's history remembers a tab by.
    struct ID: Hashable, Sendable {
        var transcript: URL
        var key: String
    }

    enum Content: Sendable, Equatable {
        /// A file, or the part of one that starts at `firstLine`.
        case file(path: String, text: String, firstLine: Int)
        /// A change as the tool recorded it: hunks, over the whole file before
        /// the change when the tool kept it.
        case comparison(path: String, hunks: [DiffHunk], original: String?)
        /// A change known only by the text replaced and its replacement.
        case replacement(path: String, old: String, new: String)
        case command(Command)
        case markdown(String)
        /// Text with no structure worth drawing: search results, a tool's raw
        /// input and output.
        case text(String)
    }

    /// A shell command and what it printed.
    struct Command: Sendable, Equatable {
        enum Status: Sendable, Equatable {
            case succeeded
            case failed(exitCode: Int?)
            case interrupted
            /// Started in the background; its output arrives later.
            case running
            case unknown
        }

        var command: String?
        /// The model's one-line summary of what the command does.
        var description: String?
        var output: String
        var errorOutput: String
        var status: Status
    }

    var id: ID
    /// The tab's label: a file's name, a command's summary.
    var title: String
    /// SF Symbol for the path bar when there's no file to take an icon from.
    var symbol: String
    var content: Content

    /// The file the document is about, if it is about one.
    var path: String? {
        switch content {
        case .file(let path, _, _), .comparison(let path, _, _), .replacement(let path, _, _): path
        case .command, .markdown, .text: nil
        }
    }
}
