import AppKit

/// What an `UnmountedRowElement` asks of the list (SPEC X3).
@MainActor
protocol UnmountedRowElementOwner: AnyObject {

    /// The row's current frame on screen (X2).
    func screenFrame(ofAccessibilityRow row: Int) -> NSRect

    /// Scroll the row into view as S1 does, which mounts it (X3).
    func scrollAccessibilityRowToVisible(_ row: Int)
}
