import AppKit
import ExactList

/// What the demo shows: a sidebar beside the list, and the scenarios that
/// change them. The demo app puts it in a titled window with a bar of buttons;
/// a recording puts it in a stage off screen and runs the same scenarios.
@MainActor
public final class DemoContentViewController: NSSplitViewController {

    /// The list in the right pane.
    public let list: ExactListView

    public init() {
        let feed = DemoFeed()
        let list = ExactListView(dataSource: feed, delegate: feed)
        list.rowSpacing = 6
        list.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        list.automaticallyFollowsTail = true
        self.feed = feed
        self.list = list
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
        content.view = list
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: content))
    }

    /// Runs one scenario. `toggleSidebar` animates the split view here, the
    /// way `NSSplitViewController` does it (through `animator()`), so the
    /// list's width changes on every frame; the others change the feed.
    public func run(_ scenario: DemoScenario) {
        if scenario == .toggleSidebar {
            toggleSidebar(nil)
        } else {
            feed.run(scenario, on: list)
        }
    }

    // MARK: - Private

    /// Strong: the list holds its data source and delegate weakly.
    private let feed: DemoFeed
}
