import AppKit

extension NSLayoutConstraint.Priority {
    /// A size a view would like but that never sizes the window: just under
    /// `.windowSizeStayPut`, so the window's size and every required limit win
    /// over it, while it still beats hugging and compression resistance. A
    /// "this wide, unless the tab is narrower" constraint at `.defaultHigh`
    /// would instead pin the window to it.
    static let wishUnderWindowSize = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
}
