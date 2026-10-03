import Components
import Foundation

/// Everything the account sheet shows, derived from its draft.
///
/// Field values reach the controls only when something other than typing
/// changed them — a paste — which `fieldsRevision` counts; rewriting the
/// field being typed in would move its caret.
struct AccountEditorPresentation: Equatable {
    var canSave: Bool
    /// Under Base URL, in red; `nil` hides it.
    var baseURLError: String?
    /// The credential row's title: “Token” or “API key”.
    var credentialTitle: String
    /// The credential as shown at rest, `sk-••••••••7c1e`.
    var maskedCredential: String
    /// The subscription's account, for its sheet; `nil` for a provider.
    var subscription: SubscriptionDetails?
    var fields: Fields
    var fieldsRevision: Int
    var environmentRows: [EnvironmentRow]
    /// Under Command: what the launch command's check found.
    var commandDetail: ValidationDetail

    struct Fields: Equatable {
        var name = ""
        var baseURL = ""
        var authentication = Account.Authentication.authToken
        var credential = ""
        var model = ""
        var opus = ""
        var sonnet = ""
        var haiku = ""
        var fable = ""
        var command = ""
        var arguments = ""
    }

    /// The subscription sheet's Account section, ready to display.
    struct SubscriptionDetails: Equatable {
        var email: String
        var organization: String
        var plan: String
    }
}
