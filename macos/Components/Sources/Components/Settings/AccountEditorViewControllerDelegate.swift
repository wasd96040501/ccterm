import DisplayModels
import Foundation

/// What the account sheet reports: each edit, as it is made, and the
/// buttons. It changes nothing itself; the next presentation shows the
/// edit. The presenter dismisses it.
@MainActor
public protocol AccountEditorViewControllerDelegate: AnyObject {
    /// A keystroke in one of its texts: the field's whole text now.
    func accountEditor(
        _ editor: AccountEditorViewController, didEdit field: AccountEditorViewController.Field, to value: String)
    /// A choice in the Authentication menu.
    func accountEditor(
        _ editor: AccountEditorViewController, didChoose authentication: AccountEditorPresentation.Authentication)
    /// ⌘V outside a field: the text to fill the draft from. Answered with
    /// ``AccountEditorViewController/say(_:)``.
    func accountEditor(_ editor: AccountEditorViewController, didPaste text: String)

    /// A variable's checkbox.
    func accountEditor(_ editor: AccountEditorViewController, didToggleVariableAt index: Int)
    func accountEditor(_ editor: AccountEditorViewController, didSetVariableName name: String, at index: Int)
    func accountEditor(_ editor: AccountEditorViewController, didSetVariableValue value: String, at index: Int)
    /// + under the variables: an empty row appended; its index.
    func accountEditorDidAddVariable(_ editor: AccountEditorViewController) -> Int
    /// − under the variables.
    func accountEditor(_ editor: AccountEditorViewController, didRemoveVariableAt index: Int)
    /// The value a variable row edits — unmasked, unlike its display.
    func accountEditor(_ editor: AccountEditorViewController, valueOfVariableAt index: Int) -> String

    /// Manage, beside the subscription's plan.
    func accountEditorDidRequestManage(_ editor: AccountEditorViewController)
    /// Save or Add, once an edit in progress has ended.
    func accountEditorDidRequestSave(_ editor: AccountEditorViewController)
    /// Cancel, Escape or ⌘.
    func accountEditorDidCancel(_ editor: AccountEditorViewController)
    /// Delete… on a provider, or Sign Out… on the subscription — to confirm.
    func accountEditorDidRequestRemoval(_ editor: AccountEditorViewController)
}
