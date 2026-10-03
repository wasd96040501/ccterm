import AppKit
import Components
import DisplayModels

/// The About window's content: the app's icon, its name over its version and
/// build, the commit. The window has no resize bit, so the content is its size.
enum AboutSpecimen {
    static func section() -> DesignPageViewController.Section {
        let controller = AboutViewController(
            content: AboutContent(
                name: "ccterm", windowTitle: "About ccterm", version: "1.4.0", build: "212", commit: "0cdbf2d"),
            icon: NSImage(named: NSImage.applicationIconName))
        // Where the content is hosted: one place, for the shared window frame.
        let host = CentredHost(controller.view, size: controller.preferredContentSize, owner: controller)
        return DesignPageViewController.Section(
            title: "About",
            note:
                "A title-less window, as wide as its content and no taller: the app's icon, its name over "
                + "\"Version\" and the build, and the commit it was built from, selectable.",
            specimens: [.init(title: "The window's content", view: host)])
    }
}
