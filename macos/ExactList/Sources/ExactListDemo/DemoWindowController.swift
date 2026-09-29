import AppKit
import ExactList

/// The demo window: a sidebar that animates open and closed beside the list (an
/// animated width change), and a toolbar with one button per scenario in
/// `DemoScenario`.
@MainActor
final class DemoWindowController: NSWindowController {

    init() {
        let feed = DemoFeed()
        let list = ExactListView(dataSource: feed, delegate: feed)
        list.rowSpacing = 6
        list.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        list.automaticallyFollowsTail = true
        self.feed = feed
        self.list = list

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ExactList"
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)

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
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 900, height: 640))

        let buttons = DemoScenario.allCases.enumerated().map { index, scenario in
            let button = NSButton(title: String(describing: scenario), target: self, action: #selector(run(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = index
            return button
        }
        let bar = NSStackView(views: buttons)
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    // MARK: - Private

    /// Strong: the list holds its data source and delegate weakly.
    private let feed: DemoFeed

    private let list: ExactListView

    private let split = NSSplitViewController()

    @objc private func run(_ sender: NSButton) {
        let scenario = DemoScenario.allCases[sender.tag]
        if scenario == .toggleSidebar {
            // NSSplitViewController animates the collapse through animator():
            // the list's width changes on every frame of it.
            split.toggleSidebar(nil)
        } else {
            feed.run(scenario, on: list)
        }
    }
}
