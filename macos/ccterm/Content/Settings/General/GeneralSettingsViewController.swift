import AgentSDK
import AppKit
import Combine

/// General: the command that starts Claude Code. Empty runs the `claude`
/// found on this Mac, whose path the empty field shows. The command is
/// checked as it is typed and reaches ``LaunchStore`` only once it runs.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let launch: LaunchStore
    private let validation: LaunchCommandValidation
    private var cancellables = Set<AnyCancellable>()

    /// `debounce`: how long typing pauses before the command is checked.
    init(launch: LaunchStore, launchCheck: LaunchCheckService, debounce: Duration = .milliseconds(500)) {
        self.launch = launch
        validation = LaunchCommandValidation(
            check: launchCheck,
            configuration: { [launch] in launch.configuration(generalCommand: $0) },
            text: launch.preferences.command, debounce: debounce)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var launchCommandField = FormTextField(placeholder: "claude", monospaced: true)
    private lazy var launchCommandRow = FormRowView(
        title: String(localized: "Launch command"), accessory: launchCommandField)

    override func loadView() {
        view = FormView(sections: [
            FormSectionView(
                title: String(localized: "Claude Code"),
                content: FormGroupView(rows: [launchCommandRow]))
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        launchCommandField.stringValue = launch.preferences.command
        launchCommandField.delegate = self
        launchCommandField.target = self
        launchCommandField.action = #selector(commitLaunchCommand(_:))
        // The validation delivers on the main actor and its current state
        // arrives on subscribing, so the first frame is already right.
        validation.$state
            .sink { [weak self] state in self?.show(state) }
            .store(in: &cancellables)
    }

    /// What the command's check found under the row and, while the field is
    /// empty, where `claude` is.
    private func show(_ state: LaunchCommandValidation.State) {
        let applied = launch.preferences.command
        let detail = state.detail(fallback: applied.isEmpty ? "claude" : applied)
        launchCommandRow.detail = detail.text
        launchCommandRow.isDetailError = detail.isError
        if case .valid(let version) = state, launchCommandField.stringValue.isEmpty {
            launchCommandField.placeholderString = (version.executable as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc private func commitLaunchCommand(_ sender: NSTextField) {
        validation.commit(sender.stringValue) { [launch] command in launch.setCommand(command) }
    }
}

extension GeneralSettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        validation.textDidChange(launchCommandField.stringValue)
    }
}
