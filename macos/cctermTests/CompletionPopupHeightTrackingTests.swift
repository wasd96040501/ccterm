import AppKit
import XCTest

@testable import ccterm

/// CI-gate logic test (NOT a `*SnapshotTests` file) for the completion popup's
/// effect on the bar's reported height (migration plan §4.3-3/5, R12, §9).
/// Feeds completion items through the REAL async provider callback (the slash
/// known-commands path dispatches results back on the main queue — the genuine
/// arrival the popup observes), then asserts the bar's `fittingSize.height`
/// GROWS by the popup's `listHeight` and SHRINKS back to baseline the SAME
/// tick on `dismiss()` (imperative-now, §4.3-3). Mirrors the
/// `HostedComponentCenteringTests` / `InputBarControllerTests` height scaffold.
@MainActor
final class CompletionPopupHeightTrackingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func settle(iterations: Int = 14) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(30))
            let deadline = Date().addingTimeInterval(0.02)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
        }
    }

    func testBarHeightGrowsWithPopupAndShrinksOnDismiss() async throws {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid, title: "Height", cwd: "/tmp/height", status: .created))
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-height-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let store = InputDraftStore(directory: draftDir, debounceInterval: 0.05)
        let suite = "ccterm-height-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let controller = InputBarController(
            sessionManager: manager, inputDraftStore: store, userDefaults: defaults,
            notificationCenter: NotificationCenter(),
            onSubmit: { _, _ in })

        // Active session with a populated slashCommands list → the slash rule's
        // synchronous known-commands provider (no subprocess) returns matches
        // asynchronously on the main queue — the genuine arrival the popup
        // observes.
        let session = manager.prepareDraftSession(sid)
        session.runtime?.slashCommands = [
            SlashCommand(name: "commit", description: "Create a git commit"),
            SlashCommand(name: "review", description: "Review the diff"),
            SlashCommand(name: "compact", description: "Compact the context"),
        ]

        // Mount.
        let size = CGSize(width: 600, height: 320)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -36),
        ])
        container.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }

        controller.rebind(sessionId: sid)
        await settle()

        controller.view.layoutSubtreeIfNeeded()
        let baseline = controller.barView.fittingSize.height
        XCTAssertGreaterThan(baseline, 0, "Baseline bar height should be positive.")
        XCTAssertTrue(
            controller.barView.completionPopup.isHidden,
            "Popup hidden at baseline (no completion active).")

        // Type "/c" through the real delegate path → the slash session arms;
        // the synchronous provider dispatches matches back on main (the async
        // arrival). Wait for the popup to show.
        let tv = controller.barView.textView
        window.makeFirstResponder(tv)
        tv.insertText("/", replacementRange: tv.selectedRange())
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        tv.insertText("c", replacementRange: tv.selectedRange())
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))

        // Wait for items to arrive (provider callback → observation → reconcile).
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !controller.barView.completionPopup.isHidden
                    && !controller.completion.items.isEmpty
            }, object: nil)
        await fulfillment(of: [shown], timeout: 5)
        await settle()

        controller.view.layoutSubtreeIfNeeded()
        let grown = controller.barView.fittingSize.height
        let listHeight = controller.barView.completionPopup.currentListHeight
        XCTAssertGreaterThan(listHeight, 0, "Popup should have a positive listHeight when active.")
        // The bar grows by the popup's framed `listHeight` PLUS the 1pt
        // hairline divider the SwiftUI bar drew between the popup and the text
        // row (reserved outside `listHeight`, `InputBarView.completionDividerHeight`).
        let reserved = listHeight + InputBarView.completionDividerHeight
        XCTAssertEqual(
            grown, baseline + reserved, accuracy: 0.6,
            "The bar height must grow by exactly the popup's listHeight + divider "
                + "(grown \(grown) vs baseline \(baseline) + reserved \(reserved)).")

        // Dismiss the completion through the public surface (Esc) and assert
        // the height shrinks back to baseline IMMEDIATELY (imperative-now,
        // §4.3-3) — no async observation hop is needed for the shrink. Esc
        // routes through the text view's cancelOperation → doCommandBy (the
        // production Esc path).
        controller.textView(tv, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        controller.view.layoutSubtreeIfNeeded()
        let shrunk = controller.barView.fittingSize.height
        XCTAssertTrue(
            controller.barView.completionPopup.isHidden,
            "Popup hidden after Esc dismiss.")
        XCTAssertEqual(
            shrunk, baseline, accuracy: 0.6,
            "On dismiss the bar must shrink back to baseline the SAME tick "
                + "(shrunk \(shrunk) vs baseline \(baseline)).")
    }
}
