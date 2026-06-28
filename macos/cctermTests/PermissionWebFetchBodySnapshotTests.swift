import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT a CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit `.webFetch`
/// permission-card body. Renders the real `PermissionWebFetchCardBodyView`
/// (built via the production dispatch) so the prominent URL line + inline domain
/// chip + dimmed prompt parity can be eyeballed against the SwiftUI
/// `PermissionWebFetchCardBody` original. The CI gate is the non-snapshot
/// `PermissionWebFetchBodyTests`.
///
/// Run: `make test-unit FILTER=PermissionWebFetchBodySnapshotTests`, then open
/// the PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionWebFetchBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap a bare NSView (pinned, padded, fixed width) in a throwaway VC over a
    /// window-tinted backdrop, mirroring the card's leading-aligned column.
    private func host(
        _ view: NSView, appearance: NSAppearance.Name, width: CGFloat = 460,
        padding: CGFloat = 14
    ) -> NSViewController {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: appearance)
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            view.bottomAnchor.constraint(
                lessThanOrEqualTo: root.bottomAnchor, constant: -padding),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func makeBody(input: [String: Any]) -> NSView {
        let req = PermissionRequest.makePreview(
            requestId: "wf-preview", toolName: "WebFetch", input: input)
        return permissionCardBodyBuilder(for: .webFetch).makeBody(request: req, engine: nil)
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testURLWithPromptSnapshot() throws {
        let body = makeBody(input: [
            "url": "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/",
            "prompt": "Summarise the section on optionals and protocol extensions.",
        ])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 200))
        attach(image, "PermissionWebFetchBody-url-prompt")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testURLNoPromptDarkSnapshot() throws {
        let body = makeBody(input: ["url": "https://example.com/release-notes"])
        let vc = host(body, appearance: .darkAqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 140))
        attach(image, "PermissionWebFetchBody-url-only-dark")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testMissingURLSnapshot() throws {
        let body = makeBody(input: [:])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 100))
        attach(image, "PermissionWebFetchBody-missing-url")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }
}
