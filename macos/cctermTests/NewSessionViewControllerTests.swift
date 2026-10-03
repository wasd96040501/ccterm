import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// The New view's geometry and its folder menu, as the design's stylesheet
/// gives them (`preview-live.css` *New view*: line boxes of the sheet's 1.45,
/// the composer `min(640, 100%)` inside 24 pt of padding, the optical centre).
@MainActor
final class NewSessionViewControllerTests: XCTestCase {
    private let folder = URL(fileURLWithPath: NSHomeDirectory() + "/dev/ccterm")
    private let ghostty = URL(fileURLWithPath: NSHomeDirectory() + "/dev/ghostty")

    private var repository: RepositoryState {
        RepositoryState(
            root: folder, branch: "main", localBranches: ["main"], remoteBranches: [],
            branchesCheckedOutElsewhere: [], hasUncommittedChanges: false, defaultBranch: "main")
    }

    private func controller(width: CGFloat, height: CGFloat = 720) -> NewSessionViewController {
        let settings = SessionSettings(
            model: .default(on: UUID()), effort: nil, permissionMode: .default, fastMode: false)
        let controller = NewSessionViewController()
        controller.loadViewIfNeeded()
        controller.configure(
            with: NewSessionModel(
                draft: NewSessionDraft(folder: folder, settings: settings), repository: .repository(repository),
                recentFolders: [folder, ghostty]))
        // The composer's height in the slot, as the session tab pins it.
        controller.composerGuide.heightAnchor.constraint(equalToConstant: 78).isActive = true
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func view(_ identifier: String, in root: NSView) throws -> NSView {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(root), "no \(identifier)")
    }

    /// Top of `frame` measured down from the top of `root`.
    private func top(_ view: NSView, in root: NSView) -> CGFloat {
        root.bounds.maxY - view.convert(view.bounds, to: root).maxY
    }

    // MARK: - The composer's slot

    func testTheComposerIs640WideAtMostAnd24InFromEachSide() {
        XCTAssertEqual(controller(width: 900).composerGuide.frame.width, 640)
        XCTAssertEqual(controller(width: 600).composerGuide.frame.width, 552)
        XCTAssertEqual(controller(width: 600).composerGuide.frame.minX, 24)
    }

    // MARK: - The stack

    /// Icon, 16, the folder's 34-pt line, 2, the path's 16, 8, the 24-pt row,
    /// 2, the note's 15, 20, the composer, 12, the hints' 16.
    func testTheStackKeepsTheDesignsLines() throws {
        let controller = controller(width: 900)
        let root = controller.view
        let icon = try XCTUnwrap(root.subviews.first { $0 is NewSessionIconView })
        let folder = try view("newSession.folder", in: root)
        let branch = try view("newSession.branch", in: root)
        let iconTop = top(icon, in: root)

        XCTAssertEqual(top(folder, in: root) - iconTop, 64 + 16)
        XCTAssertEqual(folder.frame.height, 34)
        // The row's top: the folder's line, 2, the path's 16, 8.
        let rowTop = top(folder, in: root) + 34 + 2 + 16 + 8
        XCTAssertEqual(top(branch, in: root), rowTop)
        let slotTop = root.bounds.maxY - controller.composerGuide.frame.maxY
        XCTAssertEqual(slotTop, rowTop + 24 + 2 + 15 + 20)
    }

    /// The free space above the content is 0.62 of the space below it.
    func testTheContentSitsAtTheOpticalCentre() throws {
        let controller = controller(width: 900, height: 900)
        let root = controller.view
        let icon = try XCTUnwrap(root.subviews.first { $0 is NewSessionIconView })
        let above = top(icon, in: root)
        let hintsBottom = root.bounds.maxY - (controller.composerGuide.frame.minY - 12 - 16)
        let below = root.bounds.height - hintsBottom
        XCTAssertEqual(above / below, 0.62, accuracy: 0.005)
    }

    // MARK: - The folder menu

    /// *Recent*: each project with its path in the key column, the draft's
    /// checked; then *Choose Folder…* ⌘O.
    func testTheFolderMenuListsRecentFoldersWithTheirPaths() throws {
        let menu = try XCTUnwrap(try view("newSession.folder", in: controller(width: 900).view).menu)
        let items = menu.items
        XCTAssertTrue(items[0].isSectionHeader)
        XCTAssertEqual(items[0].title, String(localized: "Recent"))
        XCTAssertEqual(items[1].attributedTitle?.string, "ccterm\t~/dev/ccterm")
        XCTAssertEqual(items[1].state, .on)
        XCTAssertEqual(items[2].attributedTitle?.string, "ghostty\t~/dev/ghostty")
        XCTAssertEqual(items[2].state, .off)
        XCTAssertTrue(items[3].isSeparatorItem)
        XCTAssertEqual(items[4].title, String(localized: "Choose Folder…"))
        XCTAssertEqual(items[4].keyEquivalent, "o")
        XCTAssertEqual(items[4].keyEquivalentModifierMask, .command)
        XCTAssertEqual(items.count, 5)
    }
}
