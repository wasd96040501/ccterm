import Foundation

/// Everything the account sheet shows, derived from its draft.
///
/// Field values reach the controls only when something other than typing
/// changed them — a paste — which `fieldsRevision` counts; rewriting the
/// field being typed in would move its caret.
public struct AccountEditorPresentation: Equatable {
    public var canSave: Bool
    /// Under Base URL, in red; `nil` hides it.
    public var baseURLError: String?
    /// The credential as shown at rest, `sk-••••••••7c1e`.
    public var maskedCredential: String
    /// The subscription's account, for its sheet; `nil` for a provider.
    public var subscription: SubscriptionDetails?
    public var fields: Fields
    public var fieldsRevision: Int
    public var environmentRows: [EnvironmentRow]
    /// Under Command: what the launch command's check found.
    public var commandDetail: ValidationDetail

    public struct Fields: Equatable {
        public var name: String
        public var baseURL: String
        public var authentication: Authentication
        public var credential: String
        public var model: String
        public var opus: String
        public var sonnet: String
        public var haiku: String
        public var fable: String
        public var command: String
        public var arguments: String

        public init(
            name: String = "", baseURL: String = "", authentication: Authentication = .authToken,
            credential: String = "", model: String = "", opus: String = "", sonnet: String = "", haiku: String = "",
            fable: String = "", command: String = "", arguments: String = ""
        ) {
            self.name = name
            self.baseURL = baseURL
            self.authentication = authentication
            self.credential = credential
            self.model = model
            self.opus = opus
            self.sonnet = sonnet
            self.haiku = haiku
            self.fable = fable
            self.command = command
            self.arguments = arguments
        }
    }

    /// How a provider's credential is sent: the Authentication menu's choice.
    public enum Authentication: Equatable, CaseIterable {
        /// `Authorization: Bearer`.
        case authToken
        /// `x-api-key`.
        case apiKey
    }

    /// The subscription sheet's Account section, ready to display.
    public struct SubscriptionDetails: Equatable {
        public var email: String
        public var organization: String
        public var plan: String

        public init(email: String, organization: String, plan: String) {
            self.email = email
            self.organization = organization
            self.plan = plan
        }
    }

    public init(
        canSave: Bool, baseURLError: String?, maskedCredential: String, subscription: SubscriptionDetails?,
        fields: Fields, fieldsRevision: Int, environmentRows: [EnvironmentRow], commandDetail: ValidationDetail
    ) {
        self.canSave = canSave
        self.baseURLError = baseURLError
        self.maskedCredential = maskedCredential
        self.subscription = subscription
        self.fields = fields
        self.fieldsRevision = fieldsRevision
        self.environmentRows = environmentRows
        self.commandDetail = commandDetail
    }
}
