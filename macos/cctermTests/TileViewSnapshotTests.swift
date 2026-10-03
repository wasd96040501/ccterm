import AppKit
import DisplayModels
import XCTest

@testable import ccterm

/// Every tile glyph in every state, in light and dark
/// (design/transcript/README.md "Tile"): a row per state, a column per glyph.
/// Review only — `make test-unit FILTER=TileViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/TileView.png`.
@MainActor
final class TileViewSnapshotTests: XCTestCase {
    private static let glyphs: [Tile.Glyph] =
        [ToolKind.change, .create, .command, .agent, .web, .search, .read, .tasks, .schedule, .message, .other]
        .map { .tool($0) } + [.workflow, .monitor, .question, .plan]

    private static let states: [Tile.State] = [.done, .preparing, .running, .background, .waiting, .failed, .stopped]

    private static let pitch: CGFloat = 28

    private func panel(_ appearance: NSAppearance.Name) -> NSView {
        let size = NSSize(
            width: Self.pitch * CGFloat(Self.glyphs.count) + 12, height: Self.pitch * CGFloat(Self.states.count) + 12)
        let panel = NSView(frame: NSRect(origin: .zero, size: size))
        panel.appearance = NSAppearance(named: appearance)
        panel.wantsLayer = true
        panel.appearance?.performAsCurrentDrawingAppearance {
            panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        for (row, state) in Self.states.enumerated() {
            for (column, glyph) in Self.glyphs.enumerated() {
                let tile = TileView()
                tile.tile = Tile(glyph: glyph, state: state)
                tile.setFrameOrigin(NSPoint(x: 12 + CGFloat(column) * Self.pitch, y: 12 + CGFloat(row) * Self.pitch))
                panel.addSubview(tile)
            }
        }
        return panel
    }

    func testEveryGlyphInEveryState() {
        let light = panel(.aqua)
        let dark = panel(.darkAqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: light.frame.width, height: light.frame.height * 2))
        dark.setFrameOrigin(NSPoint(x: 0, y: light.frame.height))
        root.addSubview(light)
        root.addSubview(dark)
        let controller = NSViewController()
        controller.view = root

        let image = ViewSnapshot.renderViewController(controller, size: root.frame.size)
        let url = ViewSnapshot.writePNG(image, name: "TileView")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(image.size, root.frame.size)
    }
}
