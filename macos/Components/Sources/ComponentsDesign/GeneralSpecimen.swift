import AppKit
import Components
import DisplayModels

/// General's Claude Code section (design/settings, *General*) in each state
/// its checks leave it in. The sample data is the design's.
enum GeneralSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "General",
            note:
                "Where Claude Code comes from: the command that starts it and the folder it keeps its settings, "
                + "sign-in and sessions in — each checked as it is typed and saved only once it passes, what the check "
                + "found in the row's description line — and whether its sessions may enter Bypass Permissions. An "
                + "empty field runs what its placeholder shows; a failing one says why in red, then what stays in use.",
            specimens: [
                .init(
                    title: "Found on this Mac — type a command, Return to check it",
                    view: LaunchHost(
                        command: found, folder: inEffect, allowsBypassPermissions: false, inset: 0),
                    width: Host.paneForm),
                .init(
                    title: "A command that doesn't run, a folder that isn't there",
                    view: LaunchHost(
                        command: .init(
                            text: "claude-nope", placeholder: "~/.local/bin/claude",
                            detail: .problem("Not found", fallback: "~/.local/bin/claude"),
                            reason: .problem("Not found", fallback: nil),
                            fallback: "~/.local/bin/claude"),
                        folder: .init(
                            text: "~/.claude-nope", placeholder: "~/.claude",
                            detail: .problem("Folder doesn’t exist", fallback: "~/.claude"),
                            reason: .problem("Folder doesn’t exist", fallback: nil),
                            fallback: "~/.claude"),
                        allowsBypassPermissions: true, inset: 0),
                    width: Host.paneForm),
                .init(
                    title: "Checking",
                    view: LaunchHost(
                        command: .init(
                            text: "~/bin/claude-relay", placeholder: "claude", detail: .checking, reason: .checking,
                            fallback: nil),
                        folder: inEffect, allowsBypassPermissions: false, inset: 0),
                    width: Host.paneForm),
            ])
    }

    /// The `claude` on this Mac, its version under it.
    static let found = LaunchSectionViewController.FieldState(
        text: "", placeholder: "~/.local/bin/claude", detail: version, reason: version, fallback: nil)
    static let version = ValidationDetail(text: "Claude Code 2.1.284", isError: false)
    /// The CLI's own folder, in effect while the field is empty.
    static let inEffect = LaunchSectionViewController.FieldState(
        text: "", placeholder: "~/.claude", detail: holds, reason: holds, fallback: nil)
    /// What a folder that passes holds.
    static let holds = ValidationDetail(text: "Claude Code’s settings, sign-in and sessions", isError: false)
}

/// The section as General shows it, driven by a stand-in for the app: a
/// field being typed in is checked, Return finds what it names, and the
/// checkbox sets itself.
final class LaunchHost: NSView, ControllerHost, LaunchSectionViewControllerDelegate {
    private let section = LaunchSectionViewController()
    var controllers: [NSViewController] { [section] }
    private var state: LaunchSectionViewController.State

    init(
        command: LaunchSectionViewController.FieldState, folder: LaunchSectionViewController.FieldState,
        allowsBypassPermissions: Bool, inset amount: CGFloat = Host.formInset
    ) {
        state = .init(
            command: command, folder: folder, allowsBypassPermissions: allowsBypassPermissions, textsRevision: 0)
        super.init(frame: .zero)
        section.delegate = self
        section.show(state)
        let content = AccountsSpecimen.inset(section.view, by: amount)
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

    func launchSection(
        _ section: LaunchSectionViewController, didEdit field: LaunchSectionViewController.Field, text: String
    ) {
        update(field) {
            $0.text = text
            $0.detail = .checking
            $0.reason = .checking
            $0.fallback = nil
        }
    }

    func launchSection(
        _ section: LaunchSectionViewController, didCommit field: LaunchSectionViewController.Field, text: String
    ) {
        update(field) {
            $0.detail = field == .command ? GeneralSpecimen.version : GeneralSpecimen.holds
            $0.reason = $0.detail
        }
    }

    func launchSection(_ section: LaunchSectionViewController, didSetAllowsBypassPermissions allows: Bool) {
        state.allowsBypassPermissions = allows
        section.show(state)
    }

    private func update(
        _ field: LaunchSectionViewController.Field, _ change: (inout LaunchSectionViewController.FieldState) -> Void
    ) {
        switch field {
        case .command: change(&state.command)
        case .folder: change(&state.folder)
        }
        section.show(state)
    }
}
