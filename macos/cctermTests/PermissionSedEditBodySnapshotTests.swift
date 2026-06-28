import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests for the AppKit `.sedEdit` permission-card body
/// (`PermissionSedEditCardBody.swift`, `InputBarControls/AppKit/`). Opt-in; NOT
/// the CI gate — the runner SKIPS `*SnapshotTests.swift` on the unfiltered
/// suite. The real gate is `PermissionSedEditBodyTests`.
///
/// Renders both arms so parity against the SwiftUI `PermissionSedEditCardBody`
/// can be eyeballed: the diff arm (`PermissionBoundedDiffView` against a real
/// temp file) and the nil arm (localized fallback + literal command).
///
/// Run: `make test-unit FILTER=PermissionSedEditBodySnapshotTests`, then open
/// the PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionSedEditBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap the body (pinned, padded, width-capped to the card column) in a
    /// throwaway VC over a window-tinted backdrop, for a given appearance.
    private func host(
        _ view: NSView, appearance: NSAppearance.Name, padding: CGFloat = 24
    )
        -> NSViewController
    {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: appearance)
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            // Pin top only; the body flows downward and sizes to its content.
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeBody(command: String) -> PermissionSedEditCardBodyView {
        let request = PermissionRequest.makePreview(
            requestId: "sed-snap-\(UUID().uuidString)",
            toolName: "Bash",
            input: ["command": command])
        let data = PermissionSedEditCardData(request: request)
        return PermissionSedEditCardBodyView(data: data, engine: nil)
    }

    // MARK: - Diff arm (substitution previews against a real file)

    func testDiffArmSnapshot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sed-snap-\(UUID().uuidString).txt")
        try "127.0.0.1 localhost\n::1 localhost\n# end\n"
            .write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let body = makeBody(command: "sed -i '' 's/localhost/local-host/g' \(url.path)")
            let vc = host(body, appearance: appearance)
            let image = ViewSnapshot.renderViewController(
                vc, size: CGSize(width: 560, height: 320))
            attach(image, "PermissionSedEditBody-diff-\(appearance.rawValue)")
            XCTAssertGreaterThanOrEqual(image.size.width, 500)
        }
    }

    // MARK: - Fallback arm (unparseable / piped command)

    func testFallbackArmSnapshot() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let body = makeBody(command: "sed 's/x/y/' a.txt | tee b.txt")
            let vc = host(body, appearance: appearance)
            let image = ViewSnapshot.renderViewController(
                vc, size: CGSize(width: 560, height: 160))
            attach(image, "PermissionSedEditBody-fallback-\(appearance.rawValue)")
            XCTAssertGreaterThanOrEqual(image.size.width, 500)
        }
    }
}
