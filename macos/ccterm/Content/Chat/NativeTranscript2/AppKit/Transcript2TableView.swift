import AppKit

/// NSTableView subclass with two responsibilities:
///
/// 1. **Negative-width clamp.** AppKit briefly calls `setFrameSize` with
///    negative widths during scroller layout (e.g. `0 - 17` when the
///    vertical scroller appears before the clip width is finalized).
///    Clamping to ≥ 0 silences the "Invalid view geometry" warning.
/// 2. **Live-resize hook.** During live resize the coordinator only
///    invalidates visible rows' heights (lazy lookup recomputes them at
///    the new width on demand). Once resize ends, we kick off a background
///    prefetch to fill the layout cache for off-screen rows at the final
///    width, with scroll-anchor compensation when stale heights get
///    corrected.
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
        coordinator?.pushScrollerHidden()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Order matters: kick off refillLayoutCache first (it pushes its
        // own scroller-hidden token) before popping ours. Otherwise count
        // would briefly hit zero between the two and the scroller would
        // flicker visible.
        if abs(liveResizeStartWidth - frame.width) > 0.5 {
            coordinator?.refillLayoutCache()
        }
        coordinator?.popScrollerHidden()
    }
}
