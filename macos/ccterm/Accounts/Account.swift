import Foundation

/// What a session runs as: the claude.ai subscription the CLI is signed in
/// with, or an API provider — a base URL and a credential. Either kind also
/// carries how the CLI is started for it. Secrets — the credential and the
/// environment variables — are not part of it; they live in the keychain as
/// ``AccountSecrets``.
nonisolated struct Account: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: Kind
    /// What runs instead of `claude`; empty runs `claude`.
    var command: String
    /// Arguments added to every launch, as typed at a shell prompt.
    var arguments: String

    enum Kind: Codable, Equatable, Sendable {
        /// The CLI's own claude.ai login. There is at most one.
        case subscription
        case provider(Provider)
    }

    /// An endpoint that speaks the Anthropic API — Anthropic's own, a gateway
    /// or a local proxy.
    struct Provider: Codable, Equatable, Sendable {
        var name: String
        var baseURL: String
        var authentication: Authentication
        var models: Models

        /// The base URL's host and port — what tells providers apart; the
        /// text as typed when it isn't a URL, `nil` when it's empty.
        var baseURLHost: String? {
            guard let url = URL(string: baseURL), let host = url.host() else { return baseURL.isEmpty ? nil : baseURL }
            return url.port.map { "\(host):\($0)" } ?? host
        }
    }

    /// How the credential is sent.
    enum Authentication: String, Codable, CaseIterable, Sendable {
        /// `Authorization: Bearer`, from `ANTHROPIC_AUTH_TOKEN`.
        case authToken
        /// `x-api-key`, from `ANTHROPIC_API_KEY`.
        case apiKey

        /// The variable the CLI reads the credential from.
        var variable: String {
            switch self {
            case .authToken: "ANTHROPIC_AUTH_TOKEN"
            case .apiKey: "ANTHROPIC_API_KEY"
            }
        }
    }

    /// Model names the provider serves; empty leaves the CLI's default.
    struct Models: Codable, Equatable, Sendable {
        var main = ""
        var opus = ""
        var sonnet = ""
        var haiku = ""
    }

    var provider: Provider? {
        if case .provider(let provider) = kind { return provider }
        return nil
    }

    /// The subscription's settings, before anyone has changed them.
    static func subscription(id: UUID = UUID()) -> Account {
        Account(id: id, kind: .subscription, command: "", arguments: "")
    }

    /// A provider nobody has filled in yet.
    static func newProvider() -> Account {
        Account(
            id: UUID(),
            kind: .provider(Provider(name: "", baseURL: "", authentication: .authToken, models: Models())),
            command: "", arguments: "")
    }
}
