import AppKit
import Components
import DisplayModels

/// The composer (design/transcript, section 8 *The composer, state by state*)
/// at the transcript's column: 720 wide, every state the sheet shows — idle
/// with words, running with Stop, waiting for you, starting, at rest, failed,
/// a model with no effort in Bypass, Fast with the context ring, a refusal, a
/// command token, the New tab's with its key hints, nothing known yet.
enum ComposerSpecimen {
    /// The transcript's column, where a session's composer floats.
    static let columnWidth: CGFloat = 720

    static func section() -> DesignPageViewController.Section {
        typealias F = ComposerFixtures
        let states: [(String, ComposerPresentation, String)] = [
            ("Idle — words in the field, the arrow accent", F.idle, "Now run the snapshot tests"),
            (
                "Responding — Stop; the arrow beside it with words; a model change waits for the turn", F.responding,
                "Also update the docs"
            ),
            ("Waiting — the coral status scrolls to the request", F.waiting, ""),
            ("Starting — the arc, and Stop to cancel", F.starting, ""),
            ("At rest — will resume when you send", F.atRest, ""),
            ("Failed — the reason at the card's top, Show Log and Restart", F.failed, ""),
            ("Haiku in Bypass — no effort level; the mode in red", F.haikuBypass, ""),
            ("Fast, Max, the context ring at 72 %", F.fastRing, ""),
            ("Refused — the red line under the card", F.refused, ""),
            ("A command token", F.idle, "/review #327"),
            ("A New tab — the key hints under the card", F.newTab, ""),
            ("Nothing known yet", F.loading, ""),
        ]
        var specimens = states.map { title, state, text in
            composer(title, state, text: text)
        }
        specimens.append(
            MenuRow([
                ComposerMenu.content(of: ComposerFixtures.idle.effortMenu),
                ComposerMenu.content(of: ComposerFixtures.idle.modeMenu),
                ComposerMenu.modelContent(of: ComposerFixtures.responding, expanded: []),
            ]).specimen("Menus — Effort, Permission mode, and the Model panel with Fast Mode under the scroll"))
        specimens.append(slashList("Slash commands — the list a `/` opens"))
        return DesignPageViewController.Section(
            title: "Composer",
            note:
                "One card: an optional failure section, the growing field, the Model / Effort / Mode pull-downs, "
                + "the status slot and the action button. In a page the key hints sit under it while the field is "
                + "empty. The pull-downs open the one menu; `/` at the start completes a command into a token. It "
                + "is shown at the transcript's column, 720 wide.",
            specimens: specimens)
    }

    /// `state` as the controller draws it at the column's width, its height
    /// the card's own, scaled down whole in a narrower column.
    private static func composer(
        _ title: String, _ state: ComposerPresentation, text: String
    ) -> DesignPageViewController.Specimen {
        let controller = ComposerViewController()
        controller.configure(with: state)
        controller.text = text
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 400)
        view.layoutSubtreeIfNeeded()
        let height = ceil(view.fittingSize.height)
        return .init(
            title: title, view: CentredHost(view, size: NSSize(width: columnWidth, height: height), owner: controller),
            width: columnWidth, height: height)
    }

    private static func slashList(_ title: String) -> DesignPageViewController.Specimen {
        let list = SlashListViewController()
        list.loadViewIfNeeded()
        list.configure(commands: ComposerFixtures.commands, width: columnWidth)
        let size = list.preferredSize
        return .init(
            title: title, view: CentredHost(list.view, size: size, owner: list), width: size.width,
            height: size.height)
    }
}
