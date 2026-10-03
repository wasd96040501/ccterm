import AppKit
import Components

/// The Settings window (design/settings, the window): the pane list beside the
/// shown pane, the panes General's and Accounts' live specimens, inside the
/// design's window with its toolbar row.
enum SettingsWindowSpecimen {
    static func section() -> DesignPageViewController.Section {
        let frame = window(initial: 1)
        return DesignPageViewController.Section(
            title: "Settings window",
            note:
                "880 × 680 and not resizable: a 180-wide source list of panes — a 17-point glyph in the accent colour, "
                + "white with a semibold title when selected — beside the shown pane, and a toolbar with back and "
                + "forward and the pane's title. Click a pane; back and forward walk the panes visited.",
            specimens: [
                .init(
                    title: "General and Accounts — click a pane", view: frame, width: frame.size.width,
                    height: frame.size.height, isWindow: true)
            ])
    }

    /// The window around the real split, at the Accounts pane or General's;
    /// `overlay` a sheet over it.
    static func window(initial: Int, overlay: NSView? = nil) -> WindowFrame {
        let content = SettingsContent(initial: initial)
        let frame = WindowFrame(
            content: content, contentSize: Host.settingsWindow,
            chrome: .settings(detailLeading: Host.settingsSidebarWidth), overlay: overlay)
        content.attach(to: frame)
        return frame
    }
}

/// The real split, holding the two panes the app's window holds; it drives
/// its window's toolbar row, as the window controller drives the toolbar.
private final class SettingsContent: NSView, SettingsSplitViewControllerDelegate {
    private let split: SettingsSplitViewController
    private let initial: Int
    private weak var chromeFrame: WindowFrame?

    init(initial: Int) {
        self.initial = initial
        split = SettingsSplitViewController(
            panes: [
                .init(
                    title: "General", symbolName: "gearshape",
                    viewController: PaneViewController(
                        LaunchHost(
                            command: GeneralSpecimen.found, folder: GeneralSpecimen.inEffect,
                            allowsBypassPermissions: false))),
                .init(
                    title: "Accounts", symbolName: "person.crop.circle",
                    viewController: PaneViewController(
                        AccountsHost(
                            subscription: .signedIn(AccountsSpecimen.subscription),
                            providers: AccountsSpecimen.providers))),
            ], initial: initial)
        super.init(frame: .zero)
        split.delegate = self
        let content = split.view
        // The source list starts under the traffic lights, 52 down: the room a
        // real title bar gives it as a safe area.
        split.splitViewItems.first?.viewController.view.additionalSafeAreaInsets =
            NSEdgeInsets(top: Host.settingsToolbarHeight, left: 0, bottom: 0, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Wires the toolbar row to the split: back and forward act on it, and
    /// the title and the buttons follow the pane shown.
    func attach(to frame: WindowFrame) {
        chromeFrame = frame
        frame.onBack = { [weak split] in split?.goBack(nil) }
        frame.onForward = { [weak split] in split?.goForward(nil) }
        // The first pane was shown as the content loaded, before there was
        // a frame to tell.
        frame.title = ["General", "Accounts"][initial]
        frame.setHistory(canGoBack: split.canGoBack, canGoForward: split.canGoForward)
    }

    func settingsSplitViewController(
        _ split: SettingsSplitViewController, didShow pane: SettingsSplitViewController.Pane
    ) {
        chromeFrame?.title = pane.title
        chromeFrame?.setHistory(canGoBack: split.canGoBack, canGoForward: split.canGoForward)
    }
}

/// A specimen as a pane: under the toolbar row, as wide as the pane.
private final class PaneViewController: NSViewController {
    private let content: NSView

    init(_ content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let view = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: Host.settingsToolbarHeight),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
        self.view = view
    }
}
