import Foundation

/// What the CLI reports once a ``Session`` has started.
public struct InitializationResult: Sendable, Equatable {
    public struct Model: Sendable, Equatable {
        /// The id to pass to ``Session/setModel(_:)``.
        public var value: String
        public var displayName: String
        public var description: String
        public var supportsEffort: Bool
        public var supportedEffortLevels: [String]
        public var supportsAdaptiveThinking: Bool
        public var supportsFastMode: Bool
        public var supportsAutoMode: Bool
    }

    public struct Agent: Sendable, Equatable {
        public var name: String
        public var description: String
        public var model: String?
    }

    public struct Account: Sendable, Equatable {
        public var email: String?
        public var organization: String?
        public var subscriptionType: String?
        public var apiProvider: String?
    }

    public var commands: [SlashCommand]
    public var agents: [Agent]
    public var models: [Model]
    public var account: Account?
    public var outputStyle: String
    public var availableOutputStyles: [String]
}

// MARK: - Decodable

extension InitializationResult: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.commands = c.lenientArray(SlashCommand.self, "commands") ?? []
        self.agents = c.lenientArray(Agent.self, "agents") ?? []
        self.models = c.lenientArray(Model.self, "models") ?? []
        self.account = c.lenient(Account.self, "account")
        self.outputStyle = c.lenient(String.self, "output_style") ?? ""
        self.availableOutputStyles = c.lenient([String].self, "available_output_styles") ?? []
    }
}

extension InitializationResult.Model: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.value = try c.required(String.self, "value")
        self.displayName = c.lenient(String.self, "displayName") ?? value
        self.description = c.lenient(String.self, "description") ?? ""
        self.supportsEffort = c.lenient(Bool.self, "supportsEffort") ?? false
        self.supportedEffortLevels = c.lenient([String].self, "supportedEffortLevels") ?? []
        self.supportsAdaptiveThinking = c.lenient(Bool.self, "supportsAdaptiveThinking") ?? false
        self.supportsFastMode = c.lenient(Bool.self, "supportsFastMode") ?? false
        self.supportsAutoMode = c.lenient(Bool.self, "supportsAutoMode") ?? false
    }
}

extension InitializationResult.Agent: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.name = try c.required(String.self, "name")
        self.description = c.lenient(String.self, "description") ?? ""
        self.model = c.lenient(String.self, "model")
    }
}

extension InitializationResult.Account: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.email = c.lenient(String.self, "email")
        self.organization = c.lenient(String.self, "organization")
        self.subscriptionType = c.lenient(String.self, "subscriptionType")
        self.apiProvider = c.lenient(String.self, "apiProvider")
    }
}
