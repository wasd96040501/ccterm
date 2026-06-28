import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot (opt-in; NOT the CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit
/// `InputBarView` / `InputBarController` spine. Renders the bar idle and
/// multi-line so the glass pill + send button + attach circle layout can be
/// eyeballed against the SwiftUI `InputBarView2` it replaces.
///
/// The CI gate for this component is the non-snapshot `InputBarControllerTests`
/// (canSend / draft-clear-order / height-tracking / sendKeyBehavior / send-stop
/// / scrim-rect). This file is purely for visual parity review.
@MainActor
final class InputBarViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeController(text: String) -> (InputBarController, NSWindow) {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(sessionId: sid, title: "Snap", cwd: "/tmp/snap", status: .created))
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-inputbar-snap-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let store = InputDraftStore(directory: draftDir, debounceInterval: 0.05)
        let suite = "ccterm-inputbar-snap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let controller = InputBarController(
            sessionManager: manager, inputDraftStore: store, userDefaults: defaults,
            notificationCenter: NotificationCenter(), onSubmit: { _, _ in })
        controller.loadViewIfNeeded()
        controller.rebind(sessionId: sid)
        if !text.isEmpty {
            controller.barView.textView.string = text
            controller.barView.textScrollView.updateIntrinsicHeight()
            controller.barView.relayout()
        }

        // Park the controller in a throwaway window so the host frames + the
        // glass surface composite.
        let size = CGSize(width: 600, height: 220)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        return (controller, window)
    }

    func testIdleSnapshot() throws {
        let (controller, window) = makeController(text: "")
        defer { window.close() }
        // Wrap the bar in a host VC so renderViewController gives it a frame.
        let host = HostVC(child: controller)
        let image = ViewSnapshot.renderViewController(
            host, size: CGSize(width: 600, height: 140), settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "InputBarView-Idle")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "InputBarView-Idle.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, 599)
    }

    func testMultiLineSnapshot() throws {
        let (controller, window) = makeController(text: "line 1\nline 2\nline 3\nline 4")
        defer { window.close() }
        let host = HostVC(child: controller)
        let image = ViewSnapshot.renderViewController(
            host, size: CGSize(width: 600, height: 220), settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "InputBarView-MultiLine")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "InputBarView-MultiLine.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, 599)
    }

    /// Tiny container VC that bottom-anchors the bar (regime-B) so the
    /// snapshot frames it like production.
    private final class HostVC: NSViewController {
        let child: InputBarController
        init(child: InputBarController) {
            self.child = child
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        nonisolated deinit {}
        override func loadView() {
            view = NSView()
            addChild(child)
            let bar = child.view
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -36),
            ])
        }
    }
}
