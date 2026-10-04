import AppKit
import DisplayModels
import XCTest

@testable import Components

/// The New view's geometry and its folder menu, as the design's stylesheet
/// gives them (`preview-live.css` *New view*: line boxes of the sheet's 1.45,
/// the composer `min(640, 100%)` inside 24 pt of padding, the optical centre).
@MainActor
final class NewSessionViewControllerTests: XCTestCase {
    private let folder = URL(fileURLWithPath: NSHomeDirectory() + "/dev/ccterm")
    private let ghostty = URL(fileURLWithPath: NSHomeDirectory() + "/dev/ghostty")

    private var content: NewSessionContent {
        NewSessionContent(
            folderTitle: "ccterm", folderPath: "~/dev/ccterm",
            recentFolders: [
                .init(url: folder, title: "ccterm", path: "~/dev/ccterm", isChosen: true),
                .init(url: ghostty, title: "ghostty", path: "~/dev/ghostty"),
            ],
            branchRow: .repository(branchTitle: "main", usesWorktree: false))
    }

    private func controller(width: CGFloat, height: CGFloat = 720) -> NewSessionViewController {
        let controller = NewSessionViewController()
        controller.loadViewIfNeeded()
        controller.configure(with: content)
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

    /// The slot's width is a wish of its own, never one on the view's: held
    /// at a split item's holding priority, the view keeps its width.
    func testTheSlotNeverPullsItsHostNarrower() {
        let controller = NewSessionViewController()
        controller.loadViewIfNeeded()
        controller.configure(with: content)
        controller.composerGuide.heightAnchor.constraint(equalToConstant: 78).isActive = true
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        let held = view.widthAnchor.constraint(equalToConstant: 900)
        held.priority = .defaultLow
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor),
            held,
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.width, 900)
        XCTAssertEqual(controller.composerGuide.frame.width, 640)
    }

    // MARK: - The stack

    /// Icon, 16, the folder's 34-pt line, 2, the path's 16, 8, the 24-pt row,
    /// 2, the note's 15, 20, the composer; each button centred in its line.
    func testTheStackKeepsTheDesignsLines() throws {
        let controller = controller(width: 900)
        let root = controller.view
        let icon = try XCTUnwrap(root.subviews.first { $0 is NewSessionIconView })
        let folder = try view("newSession.folder", in: root)
        let branch = try view("newSession.branch", in: root)
        let iconTop = top(icon, in: root)

        let folderTop = iconTop + 64 + 16
        XCTAssertEqual(top(folder, in: root) + folder.frame.height / 2, folderTop + 17)
        // The row's top: the folder's line, 2, the path's 16, 8.
        let rowTop = folderTop + 34 + 2 + 16 + 8
        XCTAssertEqual(top(branch, in: root) + branch.frame.height / 2, rowTop + 12)
        let slotTop = root.bounds.maxY - controller.composerGuide.frame.maxY
        XCTAssertEqual(slotTop, rowTop + 24 + 2 + 15 + 20)
    }

    /// The free space above the content is 0.62 of the space below it.
    func testTheContentSitsAtTheOpticalCentre() throws {
        let controller = controller(width: 900, height: 900)
        let root = controller.view
        let icon = try XCTUnwrap(root.subviews.first { $0 is NewSessionIconView })
        let above = top(icon, in: root)
        let below = controller.composerGuide.frame.minY
        XCTAssertEqual(above / below, 0.62, accuracy: 0.005)
    }

    // MARK: - The folder menu

    /// *Recent*: each project with its path in the key column, the draft's
    /// checked; then *Choose Folder…* ⌘O.
    func testTheFolderMenuListsRecentFoldersWithTheirPaths() throws {
        let rows = NewSessionViewController.folderMenu(of: content).rows
        XCTAssertEqual(rows.count, 5)
        guard case .header(let recent, _) = rows[0] else { return XCTFail("no Recent head") }
        XCTAssertEqual(recent, String(localized: "Recent", bundle: .module))
        func item(_ index: Int) throws -> MenuContent.Item {
            guard case .item(let item) = rows[index] else { return try XCTUnwrap(nil, "row \(index) is not an item") }
            return item
        }
        for (index, (title, path, isChecked)) in [
            ("ccterm", "~/dev/ccterm", true), ("ghostty", "~/dev/ghostty", false),
        ]
        .enumerated() {
            let folder = try item(index + 1)
            XCTAssertEqual(folder.title, title)
            XCTAssertEqual(folder.isChecked, isChecked)
            XCTAssertNotNil(folder.glyph, "the folder glyph")
            guard case .key(let key) = folder.trailing else { return XCTFail("\(title) has no path") }
            XCTAssertEqual(key, path)
        }
        guard case .separator = rows[3] else { return XCTFail("no hairline before Choose Folder…") }
        let choose = try item(4)
        XCTAssertEqual(choose.title, String(localized: "Choose Folder…", bundle: .module))
        XCTAssertEqual(choose.id, AnyHashable(NewSessionViewController.FolderChoice.chooseFolder))
        guard case .key(let key) = choose.trailing else { return XCTFail("Choose Folder… has no key") }
        XCTAssertEqual(key, "⌘O")
    }

    // MARK: - The row under the path

    /// A folder with no repository says so where the row is; while it is read
    /// the row is empty. Either way the branch pop-up and Worktree are gone.
    func testTheRowShowsOnlyWhatItIsGiven() throws {
        let controller = controller(width: 900)
        let branch = try view("newSession.branch", in: controller.view)
        let worktree = try view("newSession.worktree", in: controller.view)
        XCTAssertFalse(branch.isHidden)
        XCTAssertFalse(worktree.isHidden)

        var shown = content
        shown.branchRow = .notARepository("Not a git repository")
        controller.configure(with: shown)
        XCTAssertTrue(branch.isHidden)
        XCTAssertTrue(worktree.isHidden)
        func words(in view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(words)
        }
        XCTAssertTrue(words(in: controller.view).contains("Not a git repository"))

        shown.branchRow = .loading
        controller.configure(with: shown)
        XCTAssertTrue(branch.isHidden)
        XCTAssertTrue(worktree.isHidden)
    }

    // MARK: - What it reports

    func testWorktreeIsReportedAsAnIntent() throws {
        let controller = controller(width: 900)
        let delegate = Delegate()
        controller.delegate = delegate
        let button = try XCTUnwrap(try view("newSession.worktree", in: controller.view) as? NSControl)
        _ = button.sendAction(button.action, to: button.target)
        XCTAssertEqual(delegate.toggles, 1)
    }

    /// The branch menu is the owner's to word and filter: the view asks for it
    /// by what is typed and hands a chosen item back by its id.
    func testTheBranchMenuIsAskedForByWhatIsTyped() throws {
        let controller = controller(width: 900)
        let delegate = Delegate()
        controller.delegate = delegate
        let button = try XCTUnwrap(try view("newSession.branch", in: controller.view) as? NSControl)
        _ = button.sendAction(button.action, to: button.target)
        XCTAssertEqual(delegate.queries, [""])
        controller.viewDidDisappear()
    }
}

@MainActor
private final class Delegate: NewSessionViewControllerDelegate {
    var toggles = 0
    var queries: [String] = []
    var folders: [URL] = []
    var items: [AnyHashable] = []

    func newSessionViewController(_ newSessionViewController: NewSessionViewController, didChooseFolder url: URL) {
        folders.append(url)
    }

    func newSessionViewControllerDidToggleWorktree(_ newSessionViewController: NewSessionViewController) {
        toggles += 1
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, branchMenuMatching query: String
    ) -> NewSessionBranchMenu? {
        queries.append(query)
        return nil
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, didChooseBranchItem id: AnyHashable
    ) {
        items.append(id)
    }
}
