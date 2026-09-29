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

    private lazy var launchCommandField: NSTextField = {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "claude"
        return field
    }()

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
        locateTask = Task { [weak self, launch] in
            let path = await Task.detached { launch.locateCLI() }.value
            guard let path else { return }
            self?.launchCommandField.placeholderString = (path as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc private func commitLaunchCommand(_ sender: NSTextField) {
        launch.command = sender.stringValue
    }
}
