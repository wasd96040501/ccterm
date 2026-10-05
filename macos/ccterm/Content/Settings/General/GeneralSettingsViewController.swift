import AgentSDK
import AppKit
import Combine
import Components
import DisplayModels

/// General: the Claude Code section — where Claude Code comes from and whether
/// its sessions may enter Bypass Permissions. This container checks each
/// field as it is typed and saves it to ``LaunchStore`` only once it passes,
/// and shows the section what the checks found. Empty fields run the `claude`
/// found on this Mac and the CLI's own folder, which the placeholders show.
/// *Allow Bypass Permissions* takes effect at once: sessions started after it
/// carry the flag.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let launch: LaunchStore
    private let commandValidation: LaunchCommandValidation
    private let folderValidation: FolderValidation
    private let section = LaunchSectionViewController()
    private var cancellables = Set<AnyCancellable>()

    // The latest of each, as its publisher sent it — a subscriber hears a
    // change before the publisher's property holds it.
    private var preferences: LaunchPreferences
    private var commandState: LaunchCommandValidation.State
    private var folderState: FolderValidation.State
    /// The folder the CLI's sessions are in, abbreviated.
    private var folderInEffect = ""
    /// What an empty command field runs: `claude`, then where the check
    /// found it.
    private var commandPlaceholder = "claude"
    /// The fields' texts as typed.
    private var typedCommand: String
    private var typedFolder: String

    /// `debounce`: how long typing pauses before a field is checked.
    init(launch: LaunchStore, launchCheck: LaunchCheckService, debounce: Duration = .milliseconds(500)) {
        self.launch = launch
        commandValidation = LaunchCommandValidation(
            check: launchCheck,
            configuration: { [launch] in launch.configuration(generalCommand: $0) },
            text: launch.preferences.command, debounce: debounce)
        folderValidation = FolderValidation(text: launch.preferences.configDirectory, debounce: debounce)
        preferences = launch.preferences
        commandState = commandValidation.state
        folderState = folderValidation.state
        typedCommand = launch.preferences.command
        typedFolder = launch.preferences.configDirectory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = FormView(sections: [section.view])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(section)
        section.delegate = self
        // Each state and the folder in effect arrive on subscribing, on the
        // main actor, so the first frame is already right.
        launch.$preferences
            .sink { [weak self] preferences in
                self?.preferences = preferences
                self?.show()
            }
            .store(in: &cancellables)
        launch.$sessionDirectory
            .sink { [weak self] directory in
                self?.folderInEffect = (directory.configDirectory.path as NSString).abbreviatingWithTildeInPath
                self?.show()
            }
            .store(in: &cancellables)
        commandValidation.$state
            .sink { [weak self] state in
                guard let self else { return }
                commandState = state
                // While the field is empty, its placeholder says where `claude` is.
                if case .valid(let version) = state, typedCommand.isEmpty {
                    commandPlaceholder = (version.executable as NSString).abbreviatingWithTildeInPath
                }
                show()
            }
            .store(in: &cancellables)
        folderValidation.$state
            .sink { [weak self] state in
                self?.folderState = state
                self?.show()
            }
            .store(in: &cancellables)
    }

    /// The section, from the latest of everything. A failing field names what
    /// keeps running — unless the value that fails is the one in effect.
    private func show() {
        let applied = preferences.command
        let typed = typedCommand.trimmingCharacters(in: .whitespaces)
        let commandFallback = typed == applied ? nil : applied.isEmpty ? commandPlaceholder : applied
        let folderTyped = typedFolder.trimmingCharacters(in: .whitespaces)
        let folderFallback = folderTyped == preferences.configDirectory ? nil : folderInEffect
        section.show(
            LaunchSectionViewController.State(
                command: .init(
                    text: preferences.command, placeholder: commandPlaceholder,
                    detail: commandState.detail(fallback: commandFallback),
                    reason: commandState.detail(fallback: nil), fallback: commandFallback),
                folder: .init(
                    text: preferences.configDirectory,
                    placeholder: folderInEffect.isEmpty ? "~/.claude" : folderInEffect,
                    detail: folderState.detail(fallback: folderFallback), reason: folderState.detail(fallback: nil),
                    fallback: folderFallback),
                allowsBypassPermissions: preferences.allowsBypassPermissions, textsRevision: 0))
    }
}

extension GeneralSettingsViewController: LaunchSectionViewControllerDelegate {
    func launchSection(
        _ section: LaunchSectionViewController, didEdit field: LaunchSectionViewController.Field, text: String
    ) {
        switch field {
        case .command:
            typedCommand = text
            commandValidation.textDidChange(text)
        case .folder:
            typedFolder = text
            folderValidation.textDidChange(text)
        }
        show()
    }

    /// Saved once its check passes; a value that fails never is.
    func launchSection(
        _ section: LaunchSectionViewController, didCommit field: LaunchSectionViewController.Field, text: String
    ) {
        switch field {
        case .command: commandValidation.commit(text) { [launch] command in launch.setCommand(command) }
        case .folder: folderValidation.commit(text) { [launch] path in launch.setConfigDirectory(path) }
        }
    }

    func launchSection(_ section: LaunchSectionViewController, didSetAllowsBypassPermissions allows: Bool) {
        launch.setAllowsBypassPermissions(allows)
    }
}
