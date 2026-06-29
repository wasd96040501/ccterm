import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT the CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite). Renders the three shared
/// permission-card pieces so parity can be eyeballed. The real CI gates are the
/// non-snapshot `PermissionDecisionButtonTests` /
/// `PermissionCardSurfaceViewTests` / `PermissionBodyChipTests` /
/// `PermissionMonospaceScrollViewTests` / `PermissionBoundedDiffViewTests`.
///
/// Run: `make test-unit FILTER=PermissionCardPiecesSnapshotTests`, then open the
/// PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionCardPiecesSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap a bare NSView (pinned, padded) in a throwaway VC over a window-tinted
    /// backdrop, for a given appearance.
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
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -padding),
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

    // MARK: - Decision button: 3 roles × rest/hover × light/dark

    func testDecisionButtonRolesSnapshot() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let deny = PermissionDecisionButton(title: "Deny", role: .destructive)
            let once = PermissionDecisionButton(title: "Allow once", role: .secondary)
            let always = PermissionDecisionButton(title: "Allow always", role: .primary)
            // Force one button into hover so the snapshot shows the lift.
            once.mouseEntered(
                with: NSEvent.mouseEvent(
                    with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
            row.addArrangedSubview(deny)
            row.addArrangedSubview(once)
            row.addArrangedSubview(always)
            let vc = host(row, appearance: appearance)
            let image = ViewSnapshot.renderViewController(
                vc, size: CGSize(width: 360, height: 72))
            attach(image, "PermissionDecisionButton-\(appearance == .aqua ? "light" : "dark")")
            XCTAssertGreaterThanOrEqual(image.size.width, 300)
        }
    }

    // MARK: - Card surface: opaque panel both appearances (prove no bleed)

    func testCardSurfaceSnapshot() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let surface = PermissionCardSurfaceView()
            // Give it some content so it has a believable size.
            let label = NSTextField(labelWithString: "Opaque permission card panel")
            label.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
                surface.widthAnchor.constraint(equalToConstant: 320),
                surface.heightAnchor.constraint(equalToConstant: 140),
            ])
            let vc = host(surface, appearance: appearance, padding: 32)
            let image = ViewSnapshot.renderViewController(
                vc, size: CGSize(width: 400, height: 220))
            attach(image, "PermissionCardSurface-\(appearance == .aqua ? "light" : "dark")")
            XCTAssertGreaterThanOrEqual(image.size.width, 360)
        }
    }

    // MARK: - Body chip + monospace block

    func testBodyChipSnapshot() throws {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.addArrangedSubview(PermissionBodyChip(text: "linear"))
        row.addArrangedSubview(PermissionBodyChip(text: "ENG"))
        let vc = host(row, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 200, height: 60))
        attach(image, "PermissionBodyChip")
        XCTAssertGreaterThanOrEqual(image.size.width, 160)
    }

    func testMonospaceBlockSnapshot() throws {
        let block = PermissionMonospaceScrollView(
            text: "{\n  \"title\": \"hi\",\n  \"team\": \"ENG\"\n}", maxHeight: 200)
        let vc = host(block, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 360, height: 160))
        attach(image, "PermissionMonospaceScrollView")
        XCTAssertGreaterThanOrEqual(image.size.width, 320)
    }

    // MARK: - Bounded diff: short + capped/scrolling

    func testBoundedDiffSnapshot() throws {
        let engine = SyntaxHighlightEngine()
        // Short.
        let shortView = PermissionBoundedDiffView(
            diff: DiffBlock(filePath: "command.sh", oldString: nil, newString: "rm -rf build"),
            engine: engine)
        let shortVC = host(shortView, appearance: .aqua)
        let shortImage = ViewSnapshot.renderViewController(
            shortVC, size: CGSize(width: 420, height: 140))
        attach(shortImage, "PermissionBoundedDiff-short")

        // Tall → capped + scrolling.
        let body = (0..<60).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let tallView = PermissionBoundedDiffView(
            diff: DiffBlock(filePath: "Tall.swift", oldString: nil, newString: body),
            engine: engine)
        let tallVC = host(tallView, appearance: .aqua)
        let tallImage = ViewSnapshot.renderViewController(
            tallVC, size: CGSize(width: 420, height: 320))
        attach(tallImage, "PermissionBoundedDiff-capped")
        XCTAssertGreaterThanOrEqual(tallImage.size.width, 380)
    }
}
