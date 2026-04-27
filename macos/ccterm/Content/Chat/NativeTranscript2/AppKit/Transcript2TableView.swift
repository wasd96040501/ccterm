import AppKit

/// NSTableView subclass with two responsibilities:
///
/// 1. **Negative-width clamp.** AppKit briefly calls `setFrameSize` with
///    negative widths during scroller layout (e.g. `0 - 17` when the
///    vertical scroller appears before the clip width is finalized).
///    Clamping to ≥ 0 silences the "Invalid view geometry" warning.
/// 2. **Live-resize hook.** During live resize the coordinator runs the
///    cheap visible-only relayout each frame; once resize ends, we trigger
///    the (potentially expensive) full background relayout to bring
///    off-screen rows back in sync with the final width.
final class Transcript2TableView: NSTableView {
    weak var coordinator: Transcript2Coordinator?
    private var liveResizeStartWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        let safe = NSSize(
            width: max(0, newSize.width),
            height: max(0, newSize.height))
        super.setFrameSize(safe)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeStartWidth = frame.width
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if abs(liveResizeStartWidth - frame.width) > 0.5 {
            coordinator?.rebuildAllInBackground()
        }
    }
}
