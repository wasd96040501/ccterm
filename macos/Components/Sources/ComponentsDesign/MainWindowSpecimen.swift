import AppKit
import Components

/// The main window's title (design/transcript, the Playground's title bar): the
/// project's folder and name, and under it the branch.
enum MainWindowSpecimen {
    /// The toolbar slot the main window gives its title item.
    private static let slot = NSSize(width: 240, height: 30)

    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Main window title",
            note:
                "Xcode's toolbar title: the project's folder icon and name, and under the name the project's "
                + "branch, in the fonts AppKit uses for a title over a subtitle. Without a branch the name is "
                + "centred; a branch arriving raises it and fades in under it.",
            specimens: [
                .init(title: "Name over branch", view: host(branch: "transcript-views-design")),
                .init(title: "Name alone", view: host(branch: nil)),
            ])
    }

    private static func host(branch: String?) -> NSView {
        let title = MainWindowTitleView()
        title.title = "ccterm"
        title.subtitle = branch
        return CentredHost(title, size: slot)
    }
}
