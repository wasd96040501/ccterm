import Foundation

/// The settings a running session sees (``Session/settings()``): each
/// source's layer, their merge, and what the session actually runs with.
public struct SettingsSnapshot: Sendable, Equatable {
    /// All layers merged — the values in force.
    public var effective: Settings
    /// The non-empty layers, lowest precedence first (user, project, local,
    /// the session's own layer, managed policy).
    public var layers: [Layer]
    /// Values the session resolved at runtime, which can differ from the
    /// settings (a model allowlist, an effort level the model lacks).
    public var applied: Applied
    /// Validation failures. A settings file, or the session's runtime
    /// values, holding an invalid value is ignored as a whole.
    public var errors: [Issue]

    public init(effective: Settings, layers: [Layer], applied: Applied, errors: [Issue]) {
        self.effective = effective
        self.layers = layers
        self.applied = applied
        self.errors = errors
    }

    /// The layer from `source`; `nil` when it is empty.
    public func layer(_ source: Source) -> Settings? {
        layers.first { $0.source == source }?.settings
    }

    public struct Layer: Sendable, Equatable {
        public var source: Source
        public var settings: Settings

        public init(source: Source, settings: Settings) {
            self.source = source
            self.settings = settings
        }
    }

    /// Where a layer comes from.
    public enum Source: Sendable, Hashable {
        /// `~/.claude/settings.json`.
        case user
        /// `.claude/settings.json` in the project.
        case project
        /// `.claude/settings.local.json` in the project.
        case local
        /// The session's own layer: ``SessionConfiguration/settings`` with
        /// the runtime values of ``Session/applySettings(_:)`` on top.
        case session
        /// Managed (organization) settings.
        case policy
        case other(String)

        init(wireName: String) {
            switch wireName {
            case "userSettings": self = .user
            case "projectSettings": self = .project
            case "localSettings": self = .local
            case "flagSettings": self = .session
            case "policySettings": self = .policy
            default: self = .other(wireName)
            }
        }
    }

    public struct Applied: Sendable, Equatable {
        public var model: String?
        /// The effort level requests are sent with; `nil` when the model has
        /// no effort control.
        public var effort: String?
        public var advisorModel: String?
        public var ultracode: Bool

        public init(model: String? = nil, effort: String? = nil, advisorModel: String? = nil, ultracode: Bool = false) {
            self.model = model
            self.effort = effort
            self.advisorModel = advisorModel
            self.ultracode = ultracode
        }
    }

    /// A value a settings source got wrong.
    public struct Issue: Sendable, Equatable {
        /// The settings file, or a label such as `SDK inline settings`.
        public var file: String?
        /// The key path of the bad value (`permissions.allow`).
        public var path: String
        public var message: String

        public init(file: String?, path: String, message: String) {
            self.file = file
            self.path = path
            self.message = message
        }
    }
}

// MARK: - Wire

extension SettingsSnapshot {
    /// Reads a `get_settings` response. Tolerates missing parts.
    init(response: JSONValue) {
        func settings(_ value: JSONValue?) -> Settings { Settings(json: value?.objectValue ?? [:]) }
        self.effective = settings(response["effective"])
        self.layers = (response["sources"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["source"]?.stringValue else { return nil }
            return Layer(source: Source(wireName: name), settings: settings(entry["settings"]))
        }
        let applied = response["applied"]
        self.applied = Applied(
            model: applied?["model"]?.stringValue, effort: applied?["effort"]?.stringValue,
            advisorModel: applied?["advisor"]?.stringValue, ultracode: applied?["ultracode"]?.boolValue ?? false)
        self.errors = (response["errors"]?.arrayValue ?? []).compactMap { entry in
            guard let message = entry["message"]?.stringValue else { return nil }
            return Issue(file: entry["file"]?.stringValue, path: entry["path"]?.stringValue ?? "", message: message)
        }
    }
}
