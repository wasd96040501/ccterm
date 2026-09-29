import AppKit

/// General: the command that starts Claude Code. Empty runs the `claude`
/// found on this Mac, whose path the empty field shows.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let launch: LaunchSettings
    private var locateTask: Task<Void, Never>?

    init(launch: LaunchSettings) {
        self.launch = launch
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var launchCommandField = FormTextField(placeholder: "claude", monospaced: true)

    override func loadView() {
        view = FormView(sections: [
            FormSectionView(
                title: String(localized: "Claude Code"),
                content: FormGroupView(rows: [
                    FormRowView(title: String(localized: "Launch command"), accessory: launchCommandField)
                ]))
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        launchCommandField.stringValue = launch.command
        launchCommandField.target = self
        launchCommandField.action = #selector(commitLaunchCommand(_:))
        // The path is looked up at launch; only if that hasn't finished does
        // the placeholder change under the person.
        if let located = launch.locatedCLI {
            showLocated(located)
        } else {
            locateTask = Task { [weak self, launch] in
                let path = await Task.detached { launch.locateCLI() }.value
                self?.showLocated(path)
            }
        }
    }

    private func showLocated(_ path: String?) {
        guard let path else { return }
        launchCommandField.placeholderString = (path as NSString).abbreviatingWithTildeInPath
    }

    @objc private func commitLaunchCommand(_ sender: NSTextField) {
        launch.command = sender.stringValue
    }
}
