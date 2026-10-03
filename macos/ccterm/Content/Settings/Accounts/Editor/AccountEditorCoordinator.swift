import AppKit
import Combine
import Components
import DisplayModels

/// An account's sheet joined to its draft: shows the view model's
/// presentation in the sheet, turns each edit the sheet reports into a
/// view-model call, and tells its delegate how the sheet ended. The
/// presenter presents ``viewController`` and holds this while it is up.
@MainActor
final class AccountEditorCoordinator {
    weak var delegate: AccountEditorCoordinatorDelegate?
    let viewController: AccountEditorViewController

    private let viewModel: AccountEditorViewModel
    private var cancellables = Set<AnyCancellable>()

    /// The page Manage opens: the plan's billing on claude.ai.
    static let manageURL = URL(string: "https://claude.ai/settings/billing")!

    /// Which account the sheet edits.
    var mode: AccountEditorMode { viewModel.mode }

    init(viewModel: AccountEditorViewModel) {
        self.viewModel = viewModel
        viewController = AccountEditorViewController(kind: .init(viewModel.mode))
        viewController.delegate = self
        // Said before the sheet is presented, so a sheet filled from a paste
        // opens to read rather than in Name.
        if let note = viewModel.openingNote { viewController.say(note) }
        // The view model delivers on the main actor and its current value on
        // subscribing, so the sheet's first frame shows the draft as it is.
        viewModel.$presentation
            .sink { [weak self] presentation in self?.viewController.show(presentation) }
            .store(in: &cancellables)
    }
}

extension AccountEditorCoordinator: AccountEditorViewControllerDelegate {
    func accountEditor(
        _ editor: AccountEditorViewController, didEdit field: AccountEditorViewController.Field, to value: String
    ) {
        switch field {
        case .name: viewModel.setName(value)
        case .baseURL: viewModel.setBaseURL(value)
        case .credential: viewModel.setCredential(value)
        case .model(let model): viewModel.setModel(model.keyPath, to: value)
        case .command: viewModel.setCommand(value)
        case .arguments: viewModel.setArguments(value)
        }
    }

    func accountEditor(
        _ editor: AccountEditorViewController, didChoose authentication: AccountEditorPresentation.Authentication
    ) {
        viewModel.setAuthentication(Account.Authentication(authentication))
    }

    func accountEditor(_ editor: AccountEditorViewController, didPaste text: String) {
        editor.say(viewModel.paste(text))
    }

    func accountEditor(_ editor: AccountEditorViewController, didToggleVariableAt index: Int) {
        viewModel.toggleVariable(at: index)
    }

    func accountEditor(_ editor: AccountEditorViewController, didSetVariableName name: String, at index: Int) {
        viewModel.setVariableName(name, at: index)
    }

    func accountEditor(_ editor: AccountEditorViewController, didSetVariableValue value: String, at index: Int) {
        viewModel.setVariableValue(value, at: index)
    }

    func accountEditorDidAddVariable(_ editor: AccountEditorViewController) -> Int {
        viewModel.addVariable()
    }

    func accountEditor(_ editor: AccountEditorViewController, didRemoveVariableAt index: Int) {
        viewModel.removeVariable(at: index)
    }

    func accountEditor(_ editor: AccountEditorViewController, valueOfVariableAt index: Int) -> String {
        viewModel.variableValue(at: index)
    }

    func accountEditorDidRequestManage(_ editor: AccountEditorViewController) {
        NSWorkspace.shared.open(Self.manageURL)
    }

    func accountEditorDidRequestSave(_ editor: AccountEditorViewController) {
        let result = viewModel.result
        delegate?.accountEditor(self, didSave: result.account, secrets: result.secrets)
    }

    func accountEditorDidCancel(_ editor: AccountEditorViewController) {
        delegate?.accountEditorDidCancel(self)
    }

    func accountEditorDidRequestRemoval(_ editor: AccountEditorViewController) {
        delegate?.accountEditorDidRequestRemoval(self)
    }
}

extension AccountEditorViewController.Kind {
    /// The sheet for `mode`.
    fileprivate init(_ mode: AccountEditorMode) {
        switch mode {
        case .subscription: self = .subscription
        case .newProvider: self = .newProvider
        case .provider: self = .provider
        }
    }
}

extension AccountEditorViewController.Model {
    /// Where the account keeps this model's name.
    fileprivate var keyPath: WritableKeyPath<Account.Models, String> {
        switch self {
        case .main: \.main
        case .opus: \.opus
        case .sonnet: \.sonnet
        case .haiku: \.haiku
        case .fable: \.fable
        }
    }
}
