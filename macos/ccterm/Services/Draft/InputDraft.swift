import Foundation

/// On-disk snapshot of an in-progress input bar message.
///
/// Only what survives an app restart goes here: the typed text and the
/// absolute paths of any `.file` attachments. In-memory image bytes
/// (screenshot drag, `.image` kind) are NOT persisted — they can't be
/// reconstructed without the raw bytes anyway.
struct InputDraft: Codable, Equatable {
    var text: String
    var filePaths: [String]
    var updatedAt: Date

    static let empty = InputDraft(text: "", filePaths: [], updatedAt: .distantPast)

    var isEmpty: Bool { text.isEmpty && filePaths.isEmpty }
}
