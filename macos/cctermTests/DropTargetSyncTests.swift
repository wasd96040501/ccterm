import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the drop-target dashed-stroke
/// synchronization (migration plan §4.1-9): a single `InputBarView.setDropTargeted(_:)`
/// must flip BOTH the pill stroke AND the attach-button stroke together (one
/// source of truth drives both), and flip them back. Asserts the two controls'
/// `isDropTargeted` state (the resolved-stroke source of truth), not the
/// animation itself.
@MainActor
final class DropTargetSyncTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func mountedBar() -> (InputBarView, NSView) {
        let bar = InputBarView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return (bar, container)
    }

    func testSetDropTargetedFlipsBothStrokes() {
        let (bar, _) = mountedBar()

        XCTAssertFalse(bar.isDropTargeted, "Bar starts not drop-targeted.")
        XCTAssertFalse(bar.attachButton.isDropTargeted, "Attach button starts not drop-targeted.")

        // A single call must flip BOTH controls ON.
        bar.setDropTargeted(true)
        XCTAssertTrue(bar.isDropTargeted, "Pill stroke flips on.")
        XCTAssertTrue(
            bar.attachButton.isDropTargeted,
            "Attach-button stroke flips on in the SAME setDropTargeted call (synced).")

        // And flip BOTH back OFF.
        bar.setDropTargeted(false)
        XCTAssertFalse(bar.isDropTargeted, "Pill stroke flips off.")
        XCTAssertFalse(
            bar.attachButton.isDropTargeted,
            "Attach-button stroke flips off together (single source of truth).")
    }

    func testSetDropTargetedIdempotent() {
        let (bar, _) = mountedBar()
        bar.setDropTargeted(true)
        bar.setDropTargeted(true)  // no-op
        XCTAssertTrue(bar.isDropTargeted)
        XCTAssertTrue(bar.attachButton.isDropTargeted)
        bar.setDropTargeted(false)
        bar.setDropTargeted(false)  // no-op
        XCTAssertFalse(bar.isDropTargeted)
        XCTAssertFalse(bar.attachButton.isDropTargeted)
    }

    // MARK: - performDragOperation provider-reconstruction bridge (§4.1-9, §4.7-1)

    /// `performDragOperation` is the genuinely novel code: it reconstructs one
    /// `NSItemProvider` per pasteboard item via `registerDataRepresentation`, so
    /// the verbatim `loadAsURL` / `loadAsImageData` loaders run unchanged. These
    /// tests drive the REAL `NSDraggingDestination` entry points through an
    /// `NSDraggingInfo` double backed by a real pasteboard and assert the bound
    /// controller's attachments land — exercising the pasteboardItems →
    /// registerDataRepresentation bridge end to end.

    private final class DraggingInfoDouble: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        init(pasteboard: NSPasteboard) { self.draggingPasteboard = pasteboard }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        var draggingFormation: NSDraggingFormation {
            get { .default }
            set {}
        }
        var animatesToDestination: Bool {
            get { false }
            set {}
        }
        var numberOfValidItemsForDrop: Int {
            get { 1 }
            set {}
        }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            nil
        }
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        func resetSpringLoading() {}
    }

    /// A controller bound to an in-memory session whose `handleDrop` the bar
    /// routes the reconstructed providers into.
    private func makeBoundBar() -> (InputBarView, InputBarController) {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(SessionRecord(sessionId: sid, title: "Drop", cwd: "/tmp/drop", status: .created))
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-drop-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let store = InputDraftStore(directory: draftDir, debounceInterval: 0.05)
        let suite = "ccterm-drop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = InputBarController(
            sessionManager: manager, inputDraftStore: store, userDefaults: defaults,
            notificationCenter: NotificationCenter(), onSubmit: { _, _ in })
        controller.loadViewIfNeeded()
        controller.rebind(sessionId: sid)
        return (controller.barView, controller)
    }

    private func awaitAttachment(_ controller: InputBarController) async {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !controller.attachments.isEmpty }, object: nil)
        await fulfillment(of: [exp], timeout: 5)
    }

    /// A public.png-only pasteboard item (the screenshot-HUD shape) dropped via
    /// the real `performDragOperation` reconstructs a provider whose png bytes
    /// flow through `loadAsImageData`, producing an `.image` attachment.
    func testPerformDragOperationReconstructsPngImageProvider() async throws {
        let (bar, controller) = makeBoundBar()

        let png = Self.pngData()
        let item = NSPasteboardItem()
        item.setData(png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ccterm-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let info = DraggingInfoDouble(pasteboard: pasteboard)

        XCTAssertEqual(
            bar.draggingEntered(info), .copy,
            "An accepted-type drag entering the bar returns .copy.")
        let accepted = bar.performDragOperation(info)
        XCTAssertTrue(accepted, "performDragOperation consumes a reconstructed png provider.")
        await awaitAttachment(controller)

        XCTAssertEqual(controller.attachments.count, 1, "One image attachment landed.")
        guard case .image(let data, let mediaType) = controller.attachments[0].kind else {
            return XCTFail("A public.png drop must produce an .image attachment.")
        }
        XCTAssertEqual(mediaType, "image/png", "media type is image/png from the png item.")
        XCTAssertEqual(data, png, "The dropped png bytes survive the provider round-trip verbatim.")
    }

    /// A file-URL pasteboard item dropped via the real `performDragOperation`
    /// reconstructs a provider whose URL flows through `loadAsURL`, producing a
    /// `.file` attachment carrying the absolute path.
    func testPerformDragOperationReconstructsFileUrlProvider() async throws {
        let (bar, controller) = makeBoundBar()

        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-drop-\(UUID().uuidString).txt")
        try Data("dropped".utf8).write(to: txt)
        addTeardownBlock { try? FileManager.default.removeItem(at: txt) }

        let item = NSPasteboardItem()
        item.setData(
            txt.dataRepresentation, forType: NSPasteboard.PasteboardType(UTType.fileURL.identifier))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ccterm-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let info = DraggingInfoDouble(pasteboard: pasteboard)

        let accepted = bar.performDragOperation(info)
        XCTAssertTrue(accepted, "performDragOperation consumes a reconstructed file-URL provider.")
        await awaitAttachment(controller)

        XCTAssertEqual(controller.attachments.count, 1, "One file attachment landed.")
        guard case .file(let path) = controller.attachments[0].kind else {
            return XCTFail("A dropped file URL must produce a .file attachment.")
        }
        XCTAssertEqual(path, txt.path, "The .file attachment carries the dropped absolute path.")
    }

    /// `draggingEntered` / `draggingExited` drive the bar's `onDropTargetedChanged`
    /// callback (which the controller wires to `setDropTargeted`), so the dashed
    /// highlight flips on entry and off on exit.
    func testDraggingEnterExitFlipsDropTargeted() {
        let (bar, _) = mountedBar()
        var flips: [Bool] = []
        bar.onDropTargetedChanged = { flips.append($0) }

        let png = Self.pngData()
        let item = NSPasteboardItem()
        item.setData(png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ccterm-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let info = DraggingInfoDouble(pasteboard: pasteboard)

        _ = bar.draggingEntered(info)
        bar.draggingExited(info)
        XCTAssertEqual(flips, [true, false], "Entry targets the bar; exit clears it.")
    }

    /// A 4×4 PNG so the image drop produces a real decode.
    private static func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}
