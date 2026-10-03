import AppKit
import DisplayModels

/// General's Claude Code section: where Claude Code comes from — the command
/// that starts it and the folder it keeps its settings, sign-in and sessions
/// in — and whether its sessions may enter Bypass Permissions. Shows what it
/// is given (``show(_:)``): each field's placeholder — what an empty field
/// runs — and what its check found, in the row's description line. Reports
/// each keystroke, each commit (Return, or leaving the field) and the
/// checkbox to its delegate; what is saved is the app's to decide.
public final class LaunchSectionViewController: NSViewController {
    /// What the section shows.
    public struct State: Equatable {
        public var command: FieldState
        public var folder: FieldState
        public var allowsBypassPermissions: Bool
        /// Counts changes to the fields' texts that didn't come from typing in
        /// them: the texts are written into the fields only when it changes,
        /// as rewriting the field being typed in would move its caret.
        public var textsRevision: Int

        public init(command: FieldState, folder: FieldState, allowsBypassPermissions: Bool, textsRevision: Int) {
            self.command = command
            self.folder = folder
            self.allowsBypassPermissions = allowsBypassPermissions
            self.textsRevision = textsRevision
        }
    }

    /// One field and its description line.
    public struct FieldState: Equatable {
        public var text: String
        /// What an empty field runs.
        public var placeholder: String
        /// What its check found — when it failed, ending with ``fallback``.
        public var detail: ValidationDetail
        /// The same without the fallback: the part that is red.
        public var reason: ValidationDetail
        /// What keeps running while the field fails, named at the end of
        /// ``detail`` in the monospaced face; `nil` when nothing else runs.
        public var fallback: String?

        public init(
            text: String, placeholder: String, detail: ValidationDetail, reason: ValidationDetail, fallback: String?
        ) {
            self.text = text
            self.placeholder = placeholder
            self.detail = detail
            self.reason = reason
            self.fallback = fallback
        }
    }

    /// A field, as the delegate is told of it.
    public enum Field: Equatable {
        case command, folder
    }

    public weak var delegate: LaunchSectionViewControllerDelegate?
    /// The texts' revision last written into the fields.
    private var shownTextsRevision: Int?

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var launchCommandField = FormTextField(placeholder: "claude", monospaced: true)
    private lazy var launchCommandRow = FormRowView(
        title: String(localized: "Launch Command", bundle: .module), accessory: launchCommandField)
    private lazy var configDirectoryField = FormTextField(placeholder: "~/.claude", monospaced: true)
    private lazy var configDirectoryRow = FormRowView(
        title: String(localized: "Configuration Folder", bundle: .module), accessory: configDirectoryField)

    private lazy var bypassCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private lazy var bypassRow: FormRowView = {
        let row = FormRowView(
            title: String(localized: "Allow Bypass Permissions", bundle: .module), accessory: bypassCheckbox)
        row.detail = String(
            localized:
                "Lets a session switch to Bypass Permissions, which skips every permission check. Applies to sessions started after this.",
            bundle: .module
        )
        return row
    }()

    public override func loadView() {
        view = FormSectionView(
            title: String(localized: "Claude Code", bundle: .module),
            content: FormGroupView(rows: [launchCommandRow, configDirectoryRow, bypassRow]))
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        for field in [launchCommandField, configDirectoryField] {
            field.delegate = self
            field.target = self
        }
        launchCommandField.action = #selector(commitLaunchCommand(_:))
        configDirectoryField.action = #selector(commitConfigDirectory(_:))
        bypassCheckbox.target = self
        bypassCheckbox.action = #selector(commitBypass(_:))
        bypassCheckbox.setAccessibilityLabel(String(localized: "Allow Bypass Permissions", bundle: .module))
    }

    /// Opens with nothing focused, as System Settings does, rather than with
    /// the first field's text selected.
    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    /// Shows `state`: placeholders, descriptions and the checkbox every time;
    /// the texts only when ``State/textsRevision`` changed.
    public func show(_ state: State) {
        loadViewIfNeeded()
        bypassCheckbox.state = state.allowsBypassPermissions ? .on : .off
        for (field, row, shown) in [
            (launchCommandField, launchCommandRow, state.command),
            (configDirectoryField, configDirectoryRow, state.folder),
        ] {
            field.placeholderString = shown.placeholder
            present(shown.detail, reason: shown.reason, fallback: shown.fallback, in: row)
            if state.textsRevision != shownTextsRevision { field.stringValue = shown.text }
        }
        shownTextsRevision = state.textsRevision
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
        delegate?.launchSection(self, didCommit: .command, text: sender.stringValue)
    }

    @objc private func commitBypass(_ sender: NSButton) {
        delegate?.launchSection(self, didSetAllowsBypassPermissions: sender.state == .on)
    }

    @objc private func commitConfigDirectory(_ sender: NSTextField) {
        delegate?.launchSection(self, didCommit: .folder, text: sender.stringValue)
    }
}

extension LaunchSectionViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === launchCommandField {
            delegate?.launchSection(self, didEdit: .command, text: field.stringValue)
        } else if field === configDirectoryField {
            delegate?.launchSection(self, didEdit: .folder, text: field.stringValue)
        }
    }

    /// Leaving a field — Return, Tab or a click elsewhere — commits it.
    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === launchCommandField {
            commitLaunchCommand(field)
        } else if field === configDirectoryField {
            commitConfigDirectory(field)
        }
    }
}
