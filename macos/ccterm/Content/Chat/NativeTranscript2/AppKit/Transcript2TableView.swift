import AppKit

/// NSTableView subclass with a single guard: AppKit briefly calls
/// `setFrameSize` with negative widths during scroller layout (e.g. `0 - 17`
/// when the vertical scroller appears before the clip width is finalized).
/// Clamping to ≥ 0 silences the "Invalid view geometry" warning.
final class Transcript2TableView: NSTableView {
    override func setFrameSize(_ newSize: NSSize) {
        let safe = NSSize(
            width: max(0, newSize.width),
            height: max(0, newSize.height))
        super.setFrameSize(safe)
    }
}
