import AgentSDK
import AppKit
import Combine

/// General: where Claude Code comes from — the command that starts it and the
/// folder it keeps its settings, sign-in and sessions in. Each field is
/// checked as it is typed and reaches ``LaunchStore`` only once it passes;
/// what the check found shows in the row's description line. Empty fields run
/// the `claude` found on this Mac and the CLI's own folder, which the
/// placeholders show.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let launch: LaunchStore
    private let commandValidation: LaunchCommandValidation
    private let folderValidation: FolderValidation
    private var cancellables = Set<AnyCancellable>()

    /// `debounce`: how long typing pauses before a field is checked.
    init(launch: LaunchStore, launchCheck: LaunchCheckService, debounce: Duration = .milliseconds(500)) {
        self.launch = launch
        commandValidation = LaunchCommandValidation(
            check: launchCheck,
            configuration: { [launch] in launch.configuration(generalCommand: $0) },
            text: launch.preferences.command, debounce: debounce)
        folderValidation = FolderValidation(text: launch.preferences.configDirectory, debounce: debounce)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var launchCommandField = FormTextField(placeholder: "claude", monospaced: true)
    private lazy var launchCommandRow = FormRowView(
        title: String(localized: "Launch Command"), accessory: launchCommandField)
    private lazy var configDirectoryField = FormTextField(placeholder: "~/.claude", monospaced: true)
    private lazy var configDirectoryRow = FormRowView(
        title: String(localized: "Configuration Folder"), accessory: configDirectoryField)

    override func loadView() {
        view = FormView(sections: [
            FormSectionView(
                title: String(localized: "Claude Code"),
                content: FormGroupView(rows: [launchCommandRow, configDirectoryRow]))
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for field in [launchCommandField, configDirectoryField] {
            field.delegate = self
            field.target = self
        }
        launchCommandField.stringValue = launch.preferences.command
        launchCommandField.action = #selector(commitLaunchCommand(_:))
        configDirectoryField.stringValue = launch.preferences.configDirectory
        configDirectoryField.action = #selector(commitConfigDirectory(_:))
        // Each state and the folder in effect arrive on subscribing, on the
        // main actor, so the first frame is already right.
        launch.$sessionDirectory
            .sink { [weak self] directory in self?.showFolderInEffect(directory) }
            .store(in: &cancellables)
        commandValidation.$state
            .sink { [weak self] state in self?.show(state) }
            .store(in: &cancellables)
        folderValidation.$state
            .sink { [weak self] state in self?.show(state) }
            .store(in: &cancellables)
    }

    /// Opens with nothing focused, as System Settings does, rather than with
    /// the first field's text selected.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    /// The command's description, and while its field is empty, where `claude` is.
    private func show(_ state: LaunchCommandValidation.State) {
        let applied = launch.preferences.command
        // A failing value that is the one in effect leaves nothing else running.
        let typed = launchCommandField.stringValue.trimmingCharacters(in: .whitespaces)
        let fallback =
            typed == applied ? nil : applied.isEmpty ? launchCommandField.placeholderString ?? "claude" : applied
        present(
            state.detail(fallback: fallback), reason: state.detail(fallback: nil), fallback: fallback,
            in: launchCommandRow)
        if case .valid(let version) = state, launchCommandField.stringValue.isEmpty {
            launchCommandField.placeholderString = (version.executable as NSString).abbreviatingWithTildeInPath
        }
    }

    private func show(_ state: FolderValidation.State) {
        let typed = configDirectoryField.stringValue.trimmingCharacters(in: .whitespaces)
        let fallback = typed == launch.preferences.configDirectory ? nil : folderInEffect
        present(
            state.detail(fallback: fallback), reason: state.detail(fallback: nil), fallback: fallback,
            in: configDirectoryRow)
    }

    /// The folder the CLI's sessions are in, as the store last published it —
    /// a subscriber hears a change before the store's property holds it.
    private var folderInEffect = ""

    private func showFolderInEffect(_ directory: SessionDirectory) {
        folderInEffect = (directory.configDirectory.path as NSString).abbreviatingWithTildeInPath
        configDirectoryField.placeholderString = folderInEffect
        // A failing check names the folder that stays in use.
        show(folderValidation.state)
    }

    /// Puts `detail` under `row`: a problem's reason in red, then `fallback`
    /// — what keeps running — in the secondary ink and the monospaced face.
    /// `reason`: the same detail without the fallback.
    private func present(_ detail: ValidationDetail, reason: ValidationDetail, fallback: String?, in row: FormRowView) {
        guard let text = detail.text else {
            row.detail = nil
            return
        }
        let attributed = NSMutableAttributedString(string: text)
        if detail.isError, let fallback {
            let path = (text as NSString).range(of: fallback, options: .backwards)
            if path.location != NSNotFound {
                attributed.addAttribute(
                    .font, value: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), range: path)
            }
        }
        row.attributedDetail = attributed
        row.isDetailError = detail.isError
        row.detailErrorLength = detail.isError ? (reason.text as NSString?)?.length : nil
    }

    @objc private func commitLaunchCommand(_ sender: NSTextField) {
        commandValidation.commit(sender.stringValue) { [launch] command in launch.setCommand(command) }
    }

    @objc private func commitConfigDirectory(_ sender: NSTextField) {
        folderValidation.commit(sender.stringValue) { [launch] path in launch.setConfigDirectory(path) }
    }
}

extension GeneralSettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === launchCommandField {
            commandValidation.textDidChange(field.stringValue)
        } else if field === configDirectoryField {
            folderValidation.textDidChange(field.stringValue)
        }
    }

    /// Leaving a field — Return, Tab or a click elsewhere — commits it.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === launchCommandField {
            commitLaunchCommand(field)
        } else if field === configDirectoryField {
            commitConfigDirectory(field)
        }
    }
}
