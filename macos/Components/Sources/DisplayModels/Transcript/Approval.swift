import Foundation

/// A call stopped on a permission request, worded for the two places that
/// ask the reader: the approval card under its run (01-run.md "Waiting for
/// you") and the approval bar over its document (02-command.md "Live").
/// Answering either answers the call.
public nonisolated struct Approval: Sendable, Equatable, Identifiable {
    /// What the call will do, whole: the command, the lines an edit takes out
    /// and puts in, or a new file's lines.
    public enum Body: Sendable, Equatable {
        case command(String)
        case change(removed: [String], added: [String])
        case newFile([String])
    }

    /// The call's id — what a decision answers.
    public let id: String
    /// The kind's tile, coral.
    public let tile: Tile
    /// The card's heading: *Run the unit tests*, *Edit A.swift*.
    public let title: String
    public let body: Body?
    /// Why the CLI asked, in its words; `nil` when it gave none.
    public let reason: String?
    /// The bar's words: *Claude wants to run this command*.
    public let request: String

    public init(id: String, tile: Tile, title: String, body: Body?, reason: String?, request: String) {
        self.id = id
        self.tile = tile
        self.title = title
        self.body = body
        self.reason = reason
        self.request = request
    }
}
