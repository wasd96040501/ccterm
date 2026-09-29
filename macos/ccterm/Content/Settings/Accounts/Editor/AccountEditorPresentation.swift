import Foundation

/// Everything the account sheet shows, derived from its draft.
///
/// Field values reach the controls only when something other than typing
/// changed them — a paste — which `fieldsRevision` counts; rewriting the
/// field being typed in would move its caret.
struct AccountEditorPresentation: Equatable {
    var title: String
    var subtitle: String
    var canSave: Bool
    /// Under Base URL, in red; `nil` hides it.
    var baseURLError: String?
    var fields: Fields
    var fieldsRevision: Int
    var environmentRows: [EnvironmentRow]

    struct Fields: Equatable {
        var name = ""
        var baseURL = ""
        var authentication = Account.Authentication.authToken
        var credential = ""
        var model = ""
        var opus = ""
        var sonnet = ""
        var haiku = ""
        var command = ""
        var arguments = ""
    }
}
