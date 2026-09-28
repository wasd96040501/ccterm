import Foundation

/// What the main split tells the window it is in.
@MainActor
protocol MainSplitViewControllerDelegate: AnyObject {
    /// The transcript the reader is working in now belongs to the project at
    /// `url` — its folder in the sidebar — or to none, once no editor shows one.
    /// Reported when the project changes, not on every tab switch.
    func mainSplitViewController(_ split: MainSplitViewController, didShowProjectAt url: URL?)
}
