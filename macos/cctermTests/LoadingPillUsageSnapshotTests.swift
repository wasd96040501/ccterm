import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Visual self-check (opt-in, skipped on CI) for the running pill with a live
/// turn-usage counter: renders a real `BlockCellView` carrying the
/// `.loadingPill` layout at a non-zero `turnUsage`, and confirms the `↑in ↓out`
/// label paints in its dedicated `LoadingPillUsageView` subview to the right of
/// the dots (not double-drawn into the cell bitmap).
///
///   make test-unit FILTER=LoadingPillUsageSnapshotTests
///   then Read /tmp/ccterm-screenshots/LoadingPillUsage.png
@MainActor
final class LoadingPillUsageSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Bare container so the cell renders against an opaque background (the
    /// pill bitmap is otherwise transparent — dots + usage are subviews).
    private final class PillHostViewController: NSViewController {
        let cell: BlockCellView
        init(cell: BlockCellView) {
            self.cell = cell
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        override func loadView() {
            let container = NSView(frame: cell.frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            container.addSubview(cell)
            view = container
        }
    }

    func testLoadingPillWithUsageSnapshot() throws {
        let width: CGFloat = 720
        let layout = Transcript2Coordinator.makeLayout(
            for: Block(id: UUID(), kind: .loadingPill),
            width: width,
            turnUsage: TurnTokenUsage(inputTokens: 1234, outputTokens: 340))

        let cell = BlockCellView(frame: CGRect(x: 0, y: 0, width: width, height: 40))
        cell.padTop = 12
        cell.layout = layout

        let vc = PillHostViewController(cell: cell)
        let image = ViewSnapshot.renderViewController(
            vc, size: CGSize(width: width, height: 40), settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "LoadingPillUsage")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "LoadingPillUsage.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 700)
    }
}
