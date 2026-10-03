import AppKit
import Components

/// The Settings window's content (design/settings, the window): the pane list
/// beside the shown pane, the panes General's and Accounts' live specimens.
enum SettingsWindowSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Settings window",
            note:
                "880 × 680 and not resizable: a 180-wide source list of panes — a 17-point glyph in the accent colour, "
                + "white with a semibold title when selected — beside the shown pane, and a toolbar with back and "
                + "forward and the pane's title. Click a pane; back and forward walk the panes visited.",
            specimens: [
                .init(title: "General and Accounts — click a pane", view: SplitHost(), height: 628)
            ])
    }
}

/// The real split, holding the two panes the app's window holds.
private final class SplitHost: NSView {
    private let split = SettingsSplitViewController(
        panes: [
            .init(
                title: "General", glyph: .settingsGear,
                viewController: PaneViewController(
                    LaunchHost(
                        command: GeneralSpecimen.found, folder: GeneralSpecimen.inEffect,
                        allowsBypassPermissions: false))),
            .init(
                title: "Accounts", glyph: .settingsPerson,
                viewController: PaneViewController(
                    AccountsHost(
                        subscription: .signedIn(AccountsSpecimen.subscription),
                        providers: AccountsSpecimen.providers))),
        ], initial: 1)

    init() {
        super.init(frame: .zero)
        let content = split.view
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
}

/// A specimen as a pane: at the pane's top, as wide as the pane.
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
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
        self.view = view
    }
}
