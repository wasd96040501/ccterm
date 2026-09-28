import Foundation

/// The `attribution` setting (``SettingsKey/attribution``): the text Claude
/// adds to the commits and pull requests it creates. A `nil` field keeps
/// the CLI's default; an empty string hides that attribution.
public struct AttributionSettings: SettingsValue, Equatable {
    /// Text for git commits, trailers included.
    public var commit: String?
    /// Text for pull request descriptions.
    public var pullRequest: String?
    /// Whether commits and PRs from web or Remote Control sessions link the
    /// claude.ai session.
    public var includesSessionURL: Bool?

    public init(commit: String? = nil, pullRequest: String? = nil, includesSessionURL: Bool? = nil) {
        self.commit = commit
        self.pullRequest = pullRequest
        self.includesSessionURL = includesSessionURL
    }

    /// No attribution anywhere.
    public static let hidden = AttributionSettings(commit: "", pullRequest: "", includesSessionURL: false)

    /// Reads the object form, or the `true` / `false` shorthand.
    public init?(settingsJSON json: JSONValue) {
        switch json {
        case .bool(let shown):
            self = shown ? AttributionSettings() : .hidden
        case .object(let object):
            self.init(
                commit: object["commit"]?.stringValue, pullRequest: object["pr"]?.stringValue,
                includesSessionURL: object["sessionUrl"]?.boolValue)
        default:
            return nil
        }
    }

    public var settingsJSON: JSONValue {
        var object: [String: JSONValue] = [:]
        object["commit"] = commit.map(JSONValue.string)
        object["pr"] = pullRequest.map(JSONValue.string)
        object["sessionUrl"] = includesSessionURL.map(JSONValue.bool)
        return .object(object)
    }
}
