import Foundation

/// What the CLI reports once a ``Session`` has started.
public struct InitializationResult: Sendable, Equatable {
    public struct Model: Sendable, Equatable {
        /// The id to set as ``SettingsKey/model``.
        public var value: String
        public var displayName: String
        public var description: String
        public var supportsEffort: Bool
        public var supportedEffortLevels: [String]
        public var supportsAdaptiveThinking: Bool
        public var supportsFastMode: Bool
        public var supportsAutoMode: Bool
        /// The model id an alias resolves to (`opus` → `claude-opus-5-5`).
        public var resolvedModel: String?
        /// Listed but not choosable; the reason is folded into ``description``.
        public var isDisabled: Bool = false

        public init(
            value: String, displayName: String? = nil, description: String = "", supportsEffort: Bool = false,
            supportedEffortLevels: [String] = [], supportsAdaptiveThinking: Bool = false,
            supportsFastMode: Bool = false, supportsAutoMode: Bool = false
        ) {
            self.value = value
            self.displayName = displayName ?? value
            self.description = description
            self.supportsEffort = supportsEffort
            self.supportedEffortLevels = supportedEffortLevels
            self.supportsAdaptiveThinking = supportsAdaptiveThinking
            self.supportsFastMode = supportsFastMode
            self.supportsAutoMode = supportsAutoMode
        }
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
    /// The model the session runs on now (`current_model`).
    public var currentModel: String?
    /// The permission mode in effect (`current_permission_mode`).
    public var currentPermissionMode: PermissionMode?
    /// Whether Fast Mode is on, off or unavailable (`fast_mode_state`).
    public var fastModeState: String?
    /// Why Fast Mode can't be used, when it can't (`fast_mode_disabled_reason`).
    public var fastModeDisabledReason: String?
    /// Models the account can see but not select (`unavailable_models`, with
    /// ``Model/isDisabled`` set). Disjoint from ``models``; the CLI sends them
    /// only to hosts it allowlists, so for most it is empty.
    public var unavailableModels: [Model] = []
    /// Whether a turn is running when the host attaches (`session_state`:
    /// `idle`, `running`, `requires_action`); `nil` on an older CLI.
    public var sessionState: String?
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
        self.unavailableModels = (c.lenientArray(Model.self, "unavailable_models") ?? []).map {
            var model = $0
            model.isDisabled = true
            return model
        }
        self.sessionState = c.lenient(String.self, "session_state")
        self.currentModel = c.lenient(String.self, "current_model")
        self.currentPermissionMode = c.lenient(String.self, "current_permission_mode").flatMap(PermissionMode.init)
        self.fastModeState = c.lenient(String.self, "fast_mode_state")
        self.fastModeDisabledReason = c.lenient(String.self, "fast_mode_disabled_reason")
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
        self.resolvedModel = c.lenient(String.self, "resolvedModel")
        self.isDisabled = c.lenient(Bool.self, "disabled") ?? false
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
