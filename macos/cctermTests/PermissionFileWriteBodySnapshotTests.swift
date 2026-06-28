import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT a CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit `.fileEdit` /
/// `.fileWrite` permission-card body. Renders the real
/// `PermissionFileWriteCardBodyView` (built via the production dispatch
/// conformer) so the subtitle + bounded-diff parity can be eyeballed against the
/// SwiftUI `PermissionFileWriteCardBody` original. The CI gate is the
/// non-snapshot `PermissionFileWriteBodyTests`.
///
/// Built through `PermissionFileWriteCardBodyBuilder()` directly (not the
/// `permissionCardBodyBuilder(for:)` dispatch) because the dispatch still returns
/// the STUB until the integration step repoints `.fileEdit` / `.fileWrite`.
///
/// Run: `make test-unit FILTER=PermissionFileWriteBodySnapshotTests`, then open
/// the PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionFileWriteBodySnapshotTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermFWBodySnap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
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
            view.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -padding),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func makeBody(tool: String, input: [String: Any]) -> NSView {
        let req = PermissionRequest.makePreview(
            requestId: "fw-snap-\(UUID().uuidString)", toolName: tool, input: input)
        return PermissionFileWriteCardBodyBuilder().makeBody(request: req, engine: nil)
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Edit · snippet diff

    func testEditSnippetDiffSnapshot() throws {
        let body = makeBody(
            tool: "Edit",
            input: [
                "file_path": tempDir.appendingPathComponent("Greeter.swift").path,
                "old_string": "print(\"hello\")",
                "new_string": "print(\"hello, world\")",
            ])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 200))
        attach(image, "PermissionFileWriteBody-edit")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    // MARK: - Write · create new file (dark)

    func testWriteCreateSnapshot() throws {
        let body = makeBody(
            tool: "Write",
            input: [
                "file_path": tempDir.appendingPathComponent("BrandNew.txt").path,
                "content": "Hello\nThis is a brand new file.\n",
            ])
        let vc = host(body, appearance: .darkAqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 200))
        attach(image, "PermissionFileWriteBody-create-dark")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    // MARK: - Write · overwrite existing (capped/scrolling)

    func testWriteOverwriteCappedSnapshot() throws {
        let path = tempDir.appendingPathComponent("Existing.swift").path
        let old = (0..<60).map { "let old\($0) = \($0)" }.joined(separator: "\n")
        try old.write(toFile: path, atomically: true, encoding: .utf8)
        let new = (0..<60).map { "let new\($0) = \($0) * 2" }.joined(separator: "\n")

        let body = makeBody(
            tool: "Write", input: ["file_path": path, "content": new])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 320))
        attach(image, "PermissionFileWriteBody-overwrite-capped")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    // MARK: - Fallback hint (no file_path)

    func testFallbackHintSnapshot() throws {
        let body = makeBody(tool: "Edit", input: ["old_string": "a", "new_string": "b"])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 100))
        attach(image, "PermissionFileWriteBody-fallback")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }
}
