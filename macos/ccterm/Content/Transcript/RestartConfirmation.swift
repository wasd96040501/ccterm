import Foundation

/// The sheet that confirms a restart into another account (design 08
/// *Another account restarts the session*): the CLI reads its account when it
/// starts, so choosing another account's model while a process runs ends the
/// process and resumes the conversation in the new one. While Claude works the
/// restart also stops the turn, so the words say so and the button reads *Stop
/// and Restart*, destructive and not the default — Return must not throw a
/// turn away.
/// Pure: the tab builds the `NSAlert` from these words.
nonisolated struct RestartConfirmation: Equatable, Sendable {
    var title: String
    var message: String
    /// The first button, which confirms.
    var confirmTitle: String
    var cancelTitle: String
    /// Whether confirming throws a turn away: the button is destructive and
    /// Return doesn't press it.
    var confirmIsDestructive: Bool

    /// `accountName`, `modelName`: where the session resumes. `isWorking`: a
    /// turn runs, or a prompt waits for one.
    init(accountName: String, modelName: String, isWorking: Bool) {
        title = String(localized: "Restart this session as \(accountName)?")
        var message = String(
            localized:
                "Claude Code reads its account when it starts. ccterm ends this session’s process and resumes the conversation as \(accountName), on \(modelName)."
        )
        if isWorking { message += " " + String(localized: "Claude stops what it’s doing now.") }
        self.message = message
        confirmTitle = isWorking ? String(localized: "Stop and Restart") : String(localized: "Restart")
        cancelTitle = String(localized: "Cancel")
        confirmIsDestructive = isWorking
    }
}
