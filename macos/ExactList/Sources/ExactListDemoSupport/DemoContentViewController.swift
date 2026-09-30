import AppKit
import ExactList

/// What the demo shows: a sidebar beside the list, and the scenarios that
/// change them. The demo app puts it in a titled window with a bar of buttons;
/// a recording puts it in a stage off screen and runs the same scenarios.
@MainActor
public final class DemoContentViewController: NSSplitViewController {

    /// The list in the right pane.
    public let list: ExactListView

    /// `comparing`: the right pane holds the list beside the same rows in a
    /// plain `NSTableView`, and every scenario runs on both.
    public init(comparing: Bool = false) {
        let feed = DemoFeed()
        let list = ExactListView(dataSource: feed, delegate: feed)
        list.rowSpacing = 6
        list.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        list.automaticallyFollowsTail = true
        self.feed = feed
        self.list = list
        tableFeed = comparing ? DemoTableFeed() : nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        let sidebar = NSViewController()
        let label = NSTextField(labelWithString: "Sidebar")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view = NSView()
        sidebar.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: sidebar.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: sidebar.view.centerYAnchor),
        ])
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320

        let content = NSViewController()
        if let tableFeed {
            let panes = NSStackView(views: [
                Self.titled("ExactList", list), Self.titled("NSTableView", tableFeed.scrollView),
            ])
            panes.orientation = .horizontal
            panes.distribution = .fillEqually
            panes.spacing = 1
            content.view = panes
        } else {
            content.view = list
        }
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: content))
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        guard let tableFeed, !tableAtEnd else { return }
        tableAtEnd = true
        view.layoutSubtreeIfNeeded()
        tableFeed.scrollToEnd()
    }

    /// Runs one scenario. `toggleSidebar` animates the split view here, the
    /// way `NSSplitViewController` does it (through `animator()`), so the
    /// list's width changes on every frame; the others change the feed.
    public func run(_ scenario: DemoScenario) {
        if scenario == .toggleSidebar {
            toggleSidebar(nil)
        } else {
            feed.run(scenario, on: list)
            tableFeed?.run(scenario)
        }
    }

    // MARK: - Private

    /// Strong: the list holds its data source and delegate weakly.
    private let feed: DemoFeed

    /// The `NSTableView` beside the list, when comparing.
    private let tableFeed: DemoTableFeed?

    /// The table was scrolled to its end once, as the list loads at its tail.
    private var tableAtEnd = false

    /// `view` under a small caption.
    private static func titled(_ title: String, _ view: NSView) -> NSView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        let pane = NSView()
        for subview in [caption, view] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: pane.topAnchor, constant: 6),
            caption.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            view.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4),
            view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }
}
