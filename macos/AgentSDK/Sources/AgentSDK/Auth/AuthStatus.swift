import Foundation

/// What `claude auth status --json` reports: whether the CLI holds a login,
/// and for a claude.ai login, whose. Values the CLI may extend stay raw
/// strings (`authMethod` is `"claude.ai"`, `subscriptionType` is `"max"`).
public struct AuthStatus: Decodable, Sendable, Equatable {
    public var isLoggedIn: Bool
    /// How the login was made — `"claude.ai"`, `"console"`, …
    public var authMethod: String?
    /// Who serves the API — `"firstParty"`, `"bedrock"`, …
    public var apiProvider: String?
    public var email: String?
    public var organizationID: String?
    public var organizationName: String?
    /// The claude.ai plan — `"pro"`, `"max"`, …
    public var subscriptionType: String?

    public init(
        isLoggedIn: Bool, authMethod: String? = nil, apiProvider: String? = nil, email: String? = nil,
        organizationID: String? = nil, organizationName: String? = nil, subscriptionType: String? = nil
    ) {
        self.isLoggedIn = isLoggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
    }

    private enum CodingKeys: String, CodingKey {
        case isLoggedIn = "loggedIn"
        case authMethod, apiProvider, email
        case organizationID = "orgId"
        case organizationName = "orgName"
        case subscriptionType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isLoggedIn = try c.decode(Bool.self, forKey: .isLoggedIn)
        authMethod = try? c.decodeIfPresent(String.self, forKey: .authMethod)
        apiProvider = try? c.decodeIfPresent(String.self, forKey: .apiProvider)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        organizationID = try? c.decodeIfPresent(String.self, forKey: .organizationID)
        organizationName = try? c.decodeIfPresent(String.self, forKey: .organizationName)
        subscriptionType = try? c.decodeIfPresent(String.self, forKey: .subscriptionType)
    }
}
