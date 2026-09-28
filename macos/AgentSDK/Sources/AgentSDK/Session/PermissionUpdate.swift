import Foundation

/// A change to permission rules or mode.
///
/// The CLI offers these as ``PermissionRequest/suggestions`` ("always allow
/// `git status` in this project"); pass one back in
/// ``PermissionDecision/allow(updatedInput:updatedPermissions:)`` to apply it.
public enum PermissionUpdate: Sendable, Equatable {
    case addRules([PermissionRule], behavior: PermissionBehavior, destination: Destination)
    case replaceRules([PermissionRule], behavior: PermissionBehavior, destination: Destination)
    case removeRules([PermissionRule], behavior: PermissionBehavior, destination: Destination)
    case setMode(PermissionMode, destination: Destination)
    case addDirectories([String], destination: Destination)
    case removeDirectories([String], destination: Destination)
    /// A kind this SDK does not model; echoed back verbatim.
    case unknown(JSONValue)

    /// Where an update is persisted.
    public struct Destination: RawRepresentable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// `~/.claude/settings.json`
        public static let userSettings = Destination(rawValue: "userSettings")
        /// `.claude/settings.json`
        public static let projectSettings = Destination(rawValue: "projectSettings")
        /// `.claude/settings.local.json`
        public static let localSettings = Destination(rawValue: "localSettings")
        /// This session only.
        public static let session = Destination(rawValue: "session")
        public static let cliArg = Destination(rawValue: "cliArg")
    }
}

/// A permission rule: a tool, optionally narrowed by a pattern
/// (`Bash(git status:*)` is `toolName: "Bash", ruleContent: "git status:*"`).
public struct PermissionRule: Sendable, Equatable, Codable {
    public var toolName: String
    public var ruleContent: String?

    public init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }
}

public enum PermissionBehavior: String, Sendable, Codable {
    case allow, deny, ask
}

// MARK: - Codable

extension PermissionUpdate: Codable {
    public init(from decoder: Decoder) throws {
        let raw = decoder.rawValue()
        self = (try? Self.typed(decoder)) ?? .unknown(raw)
    }

    private static func typed(_ decoder: Decoder) throws -> PermissionUpdate {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let destination = Destination(rawValue: try c.required(String.self, "destination"))
        switch try c.required(String.self, "type") {
        case "addRules":
            return .addRules(
                try c.required([PermissionRule].self, "rules"),
                behavior: try c.required(PermissionBehavior.self, "behavior"),
                destination: destination)
        case "replaceRules":
            return .replaceRules(
                try c.required([PermissionRule].self, "rules"),
                behavior: try c.required(PermissionBehavior.self, "behavior"),
                destination: destination)
        case "removeRules":
            return .removeRules(
                try c.required([PermissionRule].self, "rules"),
                behavior: try c.required(PermissionBehavior.self, "behavior"),
                destination: destination)
        case "setMode":
            guard let mode = PermissionMode(rawValue: try c.required(String.self, "mode")) else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unknown mode"))
            }
            return .setMode(mode, destination: destination)
        case "addDirectories":
            return .addDirectories(try c.required([String].self, "directories"), destination: destination)
        case "removeDirectories":
            return .removeDirectories(try c.required([String].self, "directories"), destination: destination)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unknown type"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    var jsonValue: JSONValue {
        func rules(
            _ type: String, _ rules: [PermissionRule], _ behavior: PermissionBehavior, _ d: Destination
        )
            -> JSONValue
        {
            let values: [JSONValue] = rules.map { rule in
                var o: [String: JSONValue] = ["toolName": .string(rule.toolName)]
                if let content = rule.ruleContent { o["ruleContent"] = .string(content) }
                return .object(o)
            }
            return [
                "type": .string(type), "rules": .array(values), "behavior": .string(behavior.rawValue),
                "destination": .string(d.rawValue),
            ]
        }
        switch self {
        case .addRules(let r, let b, let d): return rules("addRules", r, b, d)
        case .replaceRules(let r, let b, let d): return rules("replaceRules", r, b, d)
        case .removeRules(let r, let b, let d): return rules("removeRules", r, b, d)
        case .setMode(let mode, let d):
            return ["type": "setMode", "mode": .string(mode.rawValue), "destination": .string(d.rawValue)]
        case .addDirectories(let dirs, let d):
            return [
                "type": "addDirectories", "directories": .array(dirs.map(JSONValue.string)),
                "destination": .string(d.rawValue),
            ]
        case .removeDirectories(let dirs, let d):
            return [
                "type": "removeDirectories", "directories": .array(dirs.map(JSONValue.string)),
                "destination": .string(d.rawValue),
            ]
        case .unknown(let raw):
            return raw
        }
    }
}
