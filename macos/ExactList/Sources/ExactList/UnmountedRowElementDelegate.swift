import AppKit

/// What an `UnmountedRowElement` asks of the list (SPEC X3).
@MainActor
protocol UnmountedRowElementDelegate: AnyObject {

    /// The row's current frame on screen (X2).
    func unmountedRowElement(_ element: UnmountedRowElement, screenFrameOfRow row: Int) -> NSRect

    /// Scroll the row into view as S1 does, which mounts it (X3).
    func unmountedRowElement(_ element: UnmountedRowElement, didRequestScrollRowToVisible row: Int)
}
