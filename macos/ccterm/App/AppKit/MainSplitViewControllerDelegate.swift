import Foundation

/// What the main split tells the window it is in.
@MainActor
protocol MainSplitViewControllerDelegate: AnyObject {
    /// The reader is now in the transcript at `url` — the active editor's
    /// selected tab — or in none, once no editor shows one. Reported when it
    /// changes, not on every activation.
    func mainSplitViewController(_ split: MainSplitViewController, didShowTranscriptAt url: URL?)
}
