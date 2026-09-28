import AppKit

/// A drag as a destination sees it: a source and a point, nothing else.
///
/// Why a stand-in rather than a real session: a real one cannot be started
/// from a test. Measured — `beginDraggingSession` from this process begins,
/// never ends, and stays attached to the real pointer until the person at the
/// machine next lets go of a button, dropping into whatever is under it. So a
/// test starts a drag on the source's own side (`EditorTabBar.dragWillBegin`)
/// and hands destinations this, through the same `NSDraggingDestination`
/// methods AppKit calls.
final class StubDraggingInfo: NSObject, NSDraggingInfo {

    let draggingSource: Any?
    /// In the destination window's coordinates, as AppKit reports it.
    var draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard

    /// `source` is `nil` for a drag from outside the window, whose content is
    /// on `pasteboard`.
    @MainActor
    init(
        source: NSView?, at point: NSPoint, in view: NSView, pasteboard: NSPasteboard = NSPasteboard(name: .drag)
    ) {
        draggingSource = source
        draggingLocation = view.convert(point, to: nil)
        draggingDestinationWindow = view.window
        draggingPasteboard = pasteboard
    }

    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
