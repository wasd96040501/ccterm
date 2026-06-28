import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import ccterm

/// CI-gate logic test (NOT a `*SnapshotTests` file → runs on the default suite
/// as the merge gate) for the attachment + image-preview surfaces wired into
/// the AppKit `InputBarController` (migration plan §4.1, §4.7-1, §9). Every
/// test drives the REAL controller through its production surface:
///
/// - a programmatic attach via the real `attachPickedURL(_:)` dispatch,
/// - a synthetic drop via the real `handleDrop(providers:)` + the verbatim
///   `loadAsURL` / `loadAsImageData` loaders,
/// - the real `handleSend` so the emitted `Submission` partitions images /
///   filePaths,
/// - the owned `ImagePreviewPresenter` mounted on a real window, dismissed by
///   the real `prepareForRemoval()`.
///
/// No test-only production seams: the controller's secondary-`init`-style
/// dependency injection (fresh in-memory `SessionManager` / temp-dir
/// `InputDraftStore` / `UserDefaults(suiteName:)`) is the allowed seam; the
/// default init + production behavior are unchanged.
@MainActor
final class InputBarAttachmentsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture

    private struct Fixture {
        let controller: InputBarController
        let manager: SessionManager
        let inputDraftStore: InputDraftStore
        let activeSessionId: String
        let recorder: SubmitRecorder
    }

    private final class SubmitRecorder {
        var submissions: [Submission] = []
        var lastSessionId: String?
        var onSubmitProbe: (() -> Void)?
    }

    private func makeFixture() -> Fixture {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid, title: "Attach", cwd: "/tmp/attach", status: .created))
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-attach-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let store = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let suite = "ccterm-attach-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let recorder = SubmitRecorder()
        let controller = InputBarController(
            sessionManager: manager,
            inputDraftStore: store,
            userDefaults: defaults,
            notificationCenter: NotificationCenter(),
            onSubmit: { submission, sessionId in
                recorder.onSubmitProbe?()
                recorder.submissions.append(submission)
                recorder.lastSessionId = sessionId
            })

        return Fixture(
            controller: controller, manager: manager, inputDraftStore: store,
            activeSessionId: sid, recorder: recorder)
    }

    // MARK: - Runloop pump

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func settle(iterations: Int = 12) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(30))
            drainMainLoop(seconds: 0.02)
        }
    }

    @discardableResult
    private func mount(_ fx: Fixture, width: CGFloat = 600) -> NSWindow {
        let size = CGSize(width: width, height: 220)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        let barView = fx.controller.view
        barView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(barView)
        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            barView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            barView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -36),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    /// Write a tiny on-disk file with `ext` so a programmatic / drop attach can
    /// read it. Cleaned up on teardown.
    private func makeTempFile(ext: String, bytes: Data = Data([0x1, 0x2, 0x3])) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-attach-\(UUID().uuidString).\(ext)")
        try? bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A 1×1 PNG so `NSImage(data:)` decodes and the image attach path produces
    /// a real thumbnail.
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

    // MARK: - Programmatic attach → controller state + strip render

    func testProgrammaticAttachUpdatesStateAndStrip() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        XCTAssertTrue(fx.controller.attachments.isEmpty, "Starts with no attachments.")
        XCTAssertTrue(
            fx.controller.barView.attachmentStrip.cardViews.isEmpty,
            "Empty attachments → no cards rendered.")

        // Attach an image file + a text file through the REAL dispatch.
        let png = makeTempFile(ext: "png", bytes: Self.pngData())
        let txt = makeTempFile(ext: "txt", bytes: Data("hello".utf8))
        fx.controller.attachPickedURL(png)
        fx.controller.attachPickedURL(txt)
        await settle()

        XCTAssertEqual(fx.controller.attachments.count, 2, "Two attachments accumulated.")
        // The strip is a pure render of the array.
        XCTAssertEqual(
            fx.controller.barView.attachmentStrip.cardViews.count, 2,
            "Strip renders one card per attachment.")
        // The image went down the image flow, the .txt down the file flow.
        guard case .image(_, let mediaType) = fx.controller.attachments[0].kind else {
            return XCTFail("First attachment should be an image (kind .image).")
        }
        XCTAssertEqual(mediaType, "image/png", "PNG media type derived from the extension.")
        guard case .file(let path) = fx.controller.attachments[1].kind else {
            return XCTFail("Second attachment should be a file (kind .file).")
        }
        XCTAssertEqual(path, txt.path, "File attachment carries the absolute path for @\"…\".")

        // An attachment alone makes the bar sendable.
        XCTAssertTrue(fx.controller.canSend, "An attachment alone should be sendable.")

        // Remove one by id → strip + state shrink.
        fx.controller.remove(attachmentId: fx.controller.attachments[0].id)
        await settle()
        XCTAssertEqual(fx.controller.attachments.count, 1, "One attachment removed.")
        XCTAssertEqual(
            fx.controller.barView.attachmentStrip.cardViews.count, 1, "Strip shrank to one card.")
    }

    // MARK: - Synthetic drop → image attachment (screenshot-HUD public.png path)

    func testSyntheticPngOnlyDropProducesImageAttachment() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        // Build a provider that advertises ONLY public.png data with NO
        // suggestedName — the screenshot-HUD shape (no file URL). Drive it
        // through the REAL handleDrop → loadAsImageData verbatim loader.
        let provider = NSItemProvider()
        let png = Self.pngData()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier, visibility: .all
        ) { completion in
            completion(png, nil)
            return nil
        }

        let consumed = fx.controller.handleDrop(providers: [provider])
        XCTAssertTrue(consumed, "A public.png provider should be consumed by handleDrop.")
        // The loader hops back to main asynchronously; wait for it.
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !fx.controller.attachments.isEmpty }, object: nil)
        await fulfillment(of: [exp], timeout: 5)

        XCTAssertEqual(fx.controller.attachments.count, 1, "One image attachment landed.")
        guard case .image(let data, let mediaType) = fx.controller.attachments[0].kind else {
            return XCTFail("Drop of public.png data should produce an .image attachment.")
        }
        XCTAssertEqual(mediaType, "image/png", "media type is image/png for a public.png drop.")
        XCTAssertEqual(data, png, "The dropped bytes are carried verbatim.")
        // With no suggestedName the filename is the synthesized screenshot-* one.
        XCTAssertTrue(
            fx.controller.attachments[0].filename.hasPrefix("screenshot-"),
            "A nil suggestedName synthesizes a screenshot-<ISO8601>.png filename.")
        XCTAssertTrue(
            fx.controller.attachments[0].filename.hasSuffix(".png"),
            "The synthesized filename carries the matched .png extension.")
    }

    // MARK: - Synthetic drop → file-URL attachment (.txt → @path file flow)

    func testSyntheticFileUrlDropProducesFileAttachment() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        let txt = makeTempFile(ext: "txt", bytes: Data("dropped".utf8))
        // A provider that loads a URL — the Finder / editor drag shape.
        let provider = NSItemProvider(object: txt as NSURL)

        let consumed = fx.controller.handleDrop(providers: [provider])
        XCTAssertTrue(consumed, "A file-URL provider should be consumed by handleDrop.")
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !fx.controller.attachments.isEmpty }, object: nil)
        await fulfillment(of: [exp], timeout: 5)

        XCTAssertEqual(fx.controller.attachments.count, 1, "One file attachment landed.")
        guard case .file(let path) = fx.controller.attachments[0].kind else {
            return XCTFail("A dropped .txt URL should produce a .file attachment (@path flow).")
        }
        XCTAssertEqual(path, txt.path, "The file attachment carries the dropped absolute path.")
    }

    // MARK: - handleSend packs the Submission (images + filePaths) (§4.1-4)

    func testHandleSendPacksSubmissionAndClearsBeforeOnSubmit() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        // Attach one image + one file, type a caption.
        let png = makeTempFile(ext: "png", bytes: Self.pngData())
        let txt = makeTempFile(ext: "txt", bytes: Data("notes".utf8))
        fx.controller.attachPickedURL(png)
        fx.controller.attachPickedURL(txt)
        await settle()
        let tv = fx.controller.barView.textView
        tv.insertText("caption text", replacementRange: tv.selectedRange())

        // Capture the controller's already-cleared state at the instant onSubmit
        // fires (clear-before-submit ordering, §4.1-4).
        var attachmentsAtSubmit: Int?
        fx.recorder.onSubmitProbe = { [weak controller = fx.controller] in
            attachmentsAtSubmit = controller?.attachments.count
        }

        fx.controller.handleSend()

        XCTAssertEqual(fx.recorder.submissions.count, 1, "onSubmit fired exactly once.")
        let submission = try XCTUnwrap(fx.recorder.submissions.first)
        XCTAssertEqual(submission.text, "caption text", "The trimmed caption text.")
        XCTAssertEqual(submission.images.count, 1, "One image partitioned from .image.")
        XCTAssertEqual(submission.images.first?.mediaType, "image/png")
        XCTAssertEqual(submission.filePaths, [txt.path], "One file path partitioned from .file.")
        XCTAssertEqual(fx.recorder.lastSessionId, fx.activeSessionId, "Submitted the bound id.")

        // The attachments array was cleared BEFORE onSubmit fired (the strip
        // empties in the same source phase).
        XCTAssertEqual(
            attachmentsAtSubmit, 0,
            "By onSubmit time the attachments must already be cleared (clear-before-submit).")
        XCTAssertTrue(fx.controller.attachments.isEmpty, "Attachments cleared after send.")
        XCTAssertTrue(
            fx.controller.barView.attachmentStrip.cardViews.isEmpty,
            "Strip emptied after send.")
    }

    // MARK: - Image preview presenter dismissed on prepareForRemoval (R5)

    func testImagePreviewDismissedOnPrepareForRemoval() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        // Present a preview through the owned presenter on the windowed bar.
        let image = NSImage(size: NSSize(width: 40, height: 40))
        fx.controller.presentImagePreview(image)
        await settle()
        XCTAssertFalse(
            window.sheets.isEmpty,
            "Presenting a preview begins a sheet on the bar's window.")

        // prepareForRemoval must dismiss the sheet — no orphan that wedges the
        // window (R5).
        fx.controller.prepareForRemoval()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.sheets.isEmpty }, object: nil)
        await fulfillment(of: [dismissed], timeout: 5)
        XCTAssertTrue(
            window.sheets.isEmpty, "prepareForRemoval dismisses the open preview sheet.")

        // Idempotent: a second dismiss must not crash / wedge.
        fx.controller.prepareForRemoval()
        XCTAssertTrue(window.sheets.isEmpty, "A second teardown stays a no-op (idempotent).")
    }

    // MARK: - Preview present is window-guarded (no crash with no window)

    func testImagePreviewPresentWindowGuarded() async throws {
        let fx = makeFixture()
        // Do NOT mount — the bar has no window.
        fx.controller.loadViewIfNeeded()
        // Presenting with no window is a no-op, never a crash.
        fx.controller.presentImagePreview(NSImage(size: NSSize(width: 10, height: 10)))
        // Teardown must also be safe with nothing open.
        fx.controller.prepareForRemoval()
        XCTAssertTrue(true, "presentImagePreview / prepareForRemoval are window-guarded no-ops.")
    }

    // MARK: - Draft restore rehydrates .file cards into the strip on rebind

    /// The inverse of clear-before-send: a persisted draft carrying `filePaths`
    /// must rehydrate `.file` attachment cards into the strip on `rebind`. Drives
    /// the real `startDraftLoad → restoreFileAttachment → setAttachmentStrip`
    /// path through the injected in-memory `InputDraftStore` (no test-only hook).
    func testRebindRestoresFileAttachmentsFromDraft() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }

        // Seed a persisted draft with a real on-disk file path, keyed on the
        // session id (chat mode draftKey == sessionId). Save through the
        // production surface, then wait for the debounced off-main write to land
        // by reading it back via the real async `load`.
        let txt = makeTempFile(ext: "txt", bytes: Data("persisted".utf8))
        fx.inputDraftStore.save(
            InputDraft(text: "carried over", filePaths: [txt.path], updatedAt: Date()),
            for: fx.activeSessionId)
        var seeded: InputDraft?
        let savedExp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in seeded != nil }, object: nil)
        let poll = Task { @MainActor in
            while seeded == nil {
                seeded = await fx.inputDraftStore.load(sessionId: fx.activeSessionId)
                if seeded == nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
        }
        await fulfillment(of: [savedExp], timeout: 5)
        poll.cancel()

        // Rebind — the async draft load restores the text + .file card.
        fx.controller.rebind(sessionId: fx.activeSessionId)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                fx.controller.attachments.count == 1
                    && fx.controller.barView.attachmentStrip.cardViews.count == 1
            }, object: nil)
        await fulfillment(of: [restored], timeout: 5)

        XCTAssertEqual(fx.controller.attachments.count, 1, "The persisted .file path restored.")
        guard case .file(let path) = fx.controller.attachments[0].kind else {
            return XCTFail("A persisted filePath restores as a .file attachment.")
        }
        XCTAssertEqual(path, txt.path, "The restored card carries the persisted absolute path.")
        XCTAssertEqual(
            fx.controller.barView.attachmentStrip.cardViews.count, 1,
            "The strip re-rendered the restored card on rebind.")
        XCTAssertEqual(
            fx.controller.barView.textView.string, "carried over",
            "The persisted draft text is restored alongside the attachment.")
    }
}
