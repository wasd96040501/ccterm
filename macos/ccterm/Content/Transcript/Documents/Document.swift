import Foundation

/// A document as a tab beside the transcript receives it: what it is, where
/// it came from, and the session directory its paths are read against.
nonisolated struct Document: Sendable, Equatable {
    let reference: DocumentReference
    let content: DocumentContent
    let workingDirectory: String?
}
