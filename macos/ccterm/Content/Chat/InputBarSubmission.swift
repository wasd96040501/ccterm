import AppKit
import Foundation

// Submission and Attachment were lifted verbatim out of `InputBarView2`
// (their original nested home) so that the new AppKit `InputBarController`
// (the chat-page AppKit migration, Phase 1) and the still-SwiftUI
// compose / draft / chrome chain share ONE `Submission` type and ONE
// `Attachment` type. The lift is a pure relocation — only the lexical
// scope changes (nested-in-`InputBarView2` → top-level). Critically this
// file imports only Foundation + AppKit (NSImage) and MUST NOT import
// SwiftUI: the whole point is a SwiftUI-free shared payload type.

/// One attached file or in-memory image. Identifiable so the thumbnail
/// strip can `ForEach` with stable per-card hover state.
struct Attachment: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Decoded once at attach-time so we don't pay an `NSImage`
        /// decode each layout pass; sent via
        /// `Session.send(image:mediaType:caption:)`.
        case image(data: Data, mediaType: String)
        /// Absolute path on disk; sent inline as `@<path>` in the
        /// outgoing text so the CLI can read it on demand.
        case file(path: String)
    }

    let id: UUID
    let kind: Kind
    /// Image thumbnail or system file icon, used by the thumbnail
    /// strip; for files this is `NSWorkspace.shared.icon(forFile:)`.
    let thumbnail: NSImage
    /// Display name for the file row (and tooltip for image rows).
    let filename: String

    init(id: UUID = UUID(), kind: Kind, thumbnail: NSImage, filename: String) {
        self.id = id
        self.kind = kind
        self.thumbnail = thumbnail
        self.filename = filename
    }

    static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.filename == rhs.filename
    }
}

/// Payload handed to `onSubmit`. Any combination of `text`, `images`,
/// and `filePaths` can be non-empty (at least one is, by `canSend`).
/// The shared `submitSessionInput(_:sessionId:…)` helper composes them
/// into one or more `Session.send(...)` calls.
struct Submission {
    let text: String
    let images: [(data: Data, mediaType: String)]
    let filePaths: [String]
}
