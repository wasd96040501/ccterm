import AppKit
import ExactListDemoSupport

/// The demo window: `DemoContentViewController` under a bar with one button per
/// scenario in `DemoScenario`.
@MainActor
final class DemoWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ExactList"
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)

        window.contentViewController = content
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

    private let content = DemoContentViewController()

    @objc private func run(_ sender: NSButton) {
        content.run(DemoScenario.allCases[sender.tag])
    }
}
