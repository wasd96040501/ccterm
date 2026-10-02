import Foundation

/// A prompt written here and not yet in the transcript: drawn at Send under
/// its uuid, so it shows at once, and replaced in place by the transcript's
/// own message when the CLI's replay with the same uuid arrives (design 08
/// *A prompt, from Send to the transcript*). Prompts the CLI makes itself
/// are never local.
nonisolated struct LocalPrompt: Sendable, Equatable, Identifiable {
    /// The uuid sent as `UserInput.uuid` — the replay's, the lifecycle's.
    let id: String
    var text: String
    var delivery: Delivery

    enum Delivery: Sendable, Equatable {
        /// The CLI is starting; sent once `initialize` answers. Dimmed, *Sent
        /// when Claude is ready*.
        case held
        /// Sent while a turn runs (`queued`). Dimmed at the end, *Queued ·
        /// Withdraw*.
        case queued
        /// Started, no replay yet: an ordinary bubble.
        case sent
        /// Refused, discarded, or the process ended before the replay: red
        /// mark, the reason, *Resend*.
        case notSent(reason: String)
        /// Stopped before the CLI read it (`cancelled` before the replay):
        /// nothing reached the transcript, and the words go back to the field.
        /// Stays until the tab takes them (`SessionStore.dismiss(prompt:at:)`).
        case returned
    }
}
