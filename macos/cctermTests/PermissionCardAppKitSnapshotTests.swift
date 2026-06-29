import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshots (NOT a CI gate — `*SnapshotTests` are skipped on the
/// unfiltered suite) of the AppKit permission-card spine: the
/// `PermissionCardContentView` chrome (header + STUB body + Deny/Allow row) on
/// its opaque `OpaqueCardBackgroundView`, plus the three
/// `PermissionDecisionButton` roles. The per-kind bodies are empty STUBs
/// this phase (the 11 real bodies arrive in the parallel fan-out), so the body
/// slot renders blank — these snapshots exist to eyeball the chrome / surface /
/// button parity against the SwiftUI original now, and will fill in as the
/// bodies land.
///
/// Renders via `ViewSnapshot.renderViewController` (wrap a bare `NSView` in a
/// throwaway VC) per the migration plan's snapshot migration note.
@MainActor
final class PermissionCardAppKitSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A throwaway VC that pins one content view, bottom-aligned, mirroring the
    /// card's bottom-pinned float so the chrome reads in context.
    private final class HostVC: NSViewController {
        let content: NSView
        init(content: NSView) {
            self.content = content
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        nonisolated deinit {}
        override func loadView() {
            let root = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                content.leadingAnchor.constraint(
                    greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -36),
            ])
            view = root
        }
    }

    func testCardChromeSnapshot() throws {
        let request = PermissionRequest.makePreview(
            requestId: "snap-bash",
            toolName: "Bash",
            input: ["command": "git push --force origin main"])
        let card = PermissionCardContentView(
            request: request,
            engine: nil,
            onAllowOnce: {}, onAllowAlways: {}, onDeny: {})

        let size = CGSize(width: 560, height: 200)
        let image = ViewSnapshot.renderViewController(HostVC(content: card), size: size)
        let url = ViewSnapshot.writePNG(image, name: "PermissionCardAppKit-Chrome")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "PermissionCardAppKit-Chrome.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    func testDecisionButtonsSnapshot() throws {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(
            PermissionDecisionButton(title: "Deny", role: .destructive))
        row.addArrangedSubview(
            PermissionDecisionButton(title: "Allow once", role: .secondary))
        row.addArrangedSubview(
            PermissionDecisionButton(title: "Allow always", role: .primary))

        let size = CGSize(width: 360, height: 48)
        let image = ViewSnapshot.renderViewController(HostVC(content: row), size: size)
        let url = ViewSnapshot.writePNG(image, name: "PermissionCardAppKit-Buttons")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "PermissionCardAppKit-Buttons.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }
}
