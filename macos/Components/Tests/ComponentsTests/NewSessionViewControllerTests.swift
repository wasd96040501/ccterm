import AppKit
import DisplayModels
import XCTest

@testable import Components

/// The New view's geometry and its folder menu, as the design's stylesheet
/// gives them (`preview-live.css` *New view*: the block the page centres, the
/// composer `min(640, 100%)` inside 24 pt of padding, the row under it).
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

    /// The slot in the page's coordinates: it is the column's guide.
    private func slot(_ controller: NewSessionViewController) -> NSRect {
        let guide = controller.composerGuide
        return guide.owningView?.convert(guide.frame, to: controller.view) ?? .zero
    }

    /// The icon, wherever in the page it is.
    private func icon(in root: NSView) throws -> NSView {
        func find(_ view: NSView) -> NSView? {
            view is NewSessionIconView ? view : view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(root), "no icon")
    }

    /// Top of `frame` measured down from the top of `root`.
    private func top(_ view: NSView, in root: NSView) -> CGFloat {
        root.bounds.maxY - view.convert(view.bounds, to: root).maxY
    }

    // MARK: - The composer's slot

    func testTheComposerIs640WideAtMostAnd24InFromEachSide() {
        XCTAssertEqual(slot(controller(width: 900)).width, 640)
        XCTAssertEqual(slot(controller(width: 600)).width, 552)
        XCTAssertEqual(slot(controller(width: 600)).minX, 24)
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
        XCTAssertEqual(slot(controller).width, 640)
    }

    // MARK: - The page

    /// The icon, 24, the slot; the row's line 8 under the slot, 28 tall, its
    /// controls centred in it and starting 8 in from the slot's edge.
    func testTheRowSitsUnderTheSlotOnTheCardsInnerLine() throws {
        let controller = controller(width: 900)
        let root = controller.view
        let icon = try icon(in: root)
        let folder = try view("newSession.folder", in: root)
        let worktree = try view("newSession.worktree", in: root)
        let slot = slot(controller)
        let slotTop = root.bounds.maxY - slot.maxY
        XCTAssertEqual(slotTop, top(icon, in: root) + 64 + 24)

        let rowMiddle = slotTop + slot.height + 8 + 14
        for control in [folder, worktree] {
            XCTAssertEqual(top(control, in: root) + control.frame.height / 2, rowMiddle, accuracy: 0.5)
        }
        XCTAssertEqual(folder.convert(folder.bounds, to: root).minX, slot.minX + 8)
        XCTAssertLessThan(folder.frame.maxX, worktree.frame.minX, "the folder leads the row")
    }

    /// The card's top sits at the optical centre: the space above it is 0.62
    /// of the space below it.
    func testTheCardsTopSitsAtTheOpticalCentre() throws {
        let controller = controller(width: 900, height: 900)
        let root = controller.view
        let above = root.bounds.maxY - slot(controller).maxY
        let below = slot(controller).maxY
        XCTAssertEqual(above / below, 0.62, accuracy: 0.005)
    }

    /// The note is an overlay and the card grows down: as either comes,
    /// the card's top holds still.
    func testTheSlotsTopHoldsWhileWhatIsUnderItGrows() throws {
        let controller = NewSessionViewController()
        controller.loadViewIfNeeded()
        controller.configure(with: content)
        let height = controller.composerGuide.heightAnchor.constraint(equalToConstant: 78)
        height.isActive = true
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 720)
        controller.view.layoutSubtreeIfNeeded()
        let slotTop = slot(controller).maxY
        let checkbox = try view("newSession.worktree", in: controller.view)
        let checkboxFrame = checkbox.frame

        var draft = content
        draft.branchRow = .repository(branchTitle: "main", usesWorktree: true)
        draft.explanation = "Starts a new branch from main"
        controller.configure(with: draft)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(slot(controller).maxY, slotTop)
        XCTAssertEqual(checkbox.frame, checkboxFrame, "the checkbox holds still as the note comes")

        height.constant = 140
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(slot(controller).maxY, slotTop)
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

    // MARK: - The row

    /// A folder with no repository says so where the row is; while it is read
    /// the row holds the folder alone. Either way the branch pop-up and the
    /// checkbox are gone.
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

    /// A click on the checkbox asks for the other choice; it goes on showing
    /// the draft's until the draft changes.
    func testWorktreeIsReportedAsAnIntentAndShowsTheDraft() throws {
        let controller = controller(width: 900)
        let delegate = Delegate()
        controller.delegate = delegate
        let button = try XCTUnwrap(try view("newSession.worktree", in: controller.view) as? NSButton)
        button.performClick(nil)
        XCTAssertEqual(delegate.toggles, 1)
        XCTAssertEqual(button.state, .off, "the draft still works in place")
        var draft = content
        draft.branchRow = .repository(branchTitle: "main", usesWorktree: true)
        controller.configure(with: draft)
        XCTAssertEqual(button.state, .on)
    }

    /// The folder's button opens its menu and is on while it is open; the
    /// next press on it closes the menu.
    func testTheFolderButtonOpensItsMenuAndClosesIt() throws {
        let controller = controller(width: 900)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 720), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(controller.view)
        window.orderFrontRegardless()
        defer {
            controller.viewDidDisappear()
            window.close()
        }
        func popoverIsOpen() -> Bool {
            NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        }
        let button = try XCTUnwrap(try view("newSession.folder", in: controller.view) as? NSButton)
        button.performClick(nil)
        XCTAssertEqual(button.state, .on)
        XCTAssertTrue(popoverIsOpen())
        button.performClick(nil)
        XCTAssertEqual(button.state, .off)
        wait { !popoverIsOpen() }
        XCTAssertFalse(popoverIsOpen())
    }

    /// Runs the run loop until `condition` holds, two seconds at most: the
    /// popover fades out after it closes.
    private func wait(until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 2)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
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
