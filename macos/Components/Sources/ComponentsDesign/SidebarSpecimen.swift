import AppKit
import Components

/// The main window's sidebar (design 08, *The sidebar*): the session library
/// as a source list, and the state it shows until the library is first read.
/// The fixture is two projects' worth of sessions with a worktree session,
/// subagents and a workflow run, and every state a live session shows.
enum SidebarSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Sidebar",
            note:
                "The library as an Xcode-style source list, 260 wide: projects, their sessions, and under each "
                + "session its subagents and workflow runs, every row an icon and a title. A live session ends in "
                + "a mark — a quiet dot while idle, a turning arc while responding, coral when it needs the reader, "
                + "red when it failed — and a collapsed group shows its most urgent session's. A worktree "
                + "session's branch glyph follows its title. Click selects, double-click opens, a live session's "
                + "context menu ends it.",
            specimens: [
                .init(title: "The library", view: SidebarHost(library: true), height: 440),
                .init(title: "Loading", view: SidebarHost(library: false), height: 120),
            ])
    }

    private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/dev/\(name).jsonl") }

    private static func session(
        _ title: String, worktree: String? = nil, children: [SidebarNode] = []
    ) -> SidebarNode {
        let url = url(title)
        return SidebarNode(
            id: url.path, title: title, toolTip: title, glyph: .session, transcriptURL: url,
            worktreeCaption: worktree.map { "\($0) · worktree" }, children: children)
    }

    private static func side(_ title: String, glyph: SidebarNode.Glyph, in session: String) -> SidebarNode {
        let url = url("\(session)/\(title)")
        return SidebarNode(id: url.path, title: title, toolTip: title, glyph: glyph, transcriptURL: url)
    }

    private static func group(
        _ title: String, glyph: SidebarNode.Glyph = .folder, id: String, toolTip: String? = nil,
        _ children: [SidebarNode]
    ) -> SidebarNode {
        SidebarNode(id: id, title: title, toolTip: toolTip ?? title, glyph: glyph, children: children)
    }

    private static let selected = url("Row gap and tool rows/explore")

    private static let library: [SidebarNode] = [
        group(
            "ccterm", id: "/dev/ccterm", toolTip: "/dev/ccterm",
            [
                session("Smaller run-row summary"),
                session(
                    "Row gap and tool rows", worktree: "worktree-quiet-otter",
                    children: [
                        group(
                            "Subagents", id: "/dev/Row gap/subagents",
                            [
                                side("review", glyph: .agent, in: "Row gap and tool rows"),
                                side("explore", glyph: .agent, in: "Row gap and tool rows"),
                            ]),
                        group(
                            "release-checklist", glyph: .workflow, id: "/dev/Row gap/workflow",
                            [side("build", glyph: .agent, in: "Row gap and tool rows")]),
                    ]),
                session("Review the diff"),
                session("Nightly build"),
                session("A session whose title is far too long to fit the row"),
            ]),
        group(
            "ghostty", id: "/dev/ghostty", toolTip: "/dev/ghostty",
            [session("Tab bar accessory"), session("Fix the split resize")]),
        group("notes", id: "/dev/notes", toolTip: "/dev/notes", [session("Weekly summary")]),
    ]

    private static let activities: [URL: SidebarActivity] = [
        url("Smaller run-row summary"): .responding,
        url("Row gap and tool rows"): .idle,
        url("Review the diff"): .needsInput,
        url("Nightly build"): .failed(message: "The CLI exited"),
        url("Fix the split resize"): .responding,
        url("Tab bar accessory"): .needsInput,
    ]

    /// A sidebar 260 wide at the card's leading edge, the way a window's
    /// source list is.
    private final class SidebarHost: NSView {
        private let sidebar = SidebarViewController()

        init(library: Bool) {
            super.init(frame: .zero)
            let content = sidebar.view
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.widthAnchor.constraint(equalToConstant: 260),
            ])
            guard library else { return }
            sidebar.show(SidebarSpecimen.library)
            sidebar.show(SidebarSpecimen.activities)
            sidebar.select(transcriptAt: SidebarSpecimen.selected)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    }
}
