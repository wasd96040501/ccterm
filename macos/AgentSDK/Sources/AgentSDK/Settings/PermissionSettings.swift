import Foundation

/// The `permissions` setting (``SettingsKey/permissions``).
///
/// Written as one value: applying it replaces the layer's whole
/// `permissions` object, so fields left `nil` here are removed from the
/// layer. To change one field, read the layer, modify, and write it back;
/// fields this type does not model ride along in ``additionalFields``.
public struct PermissionSettings: SettingsValue, Equatable {
    /// Rules for tool calls that run without asking.
    public var allow: [PermissionRule]?
    /// Rules for tool calls that are refused.
    public var deny: [PermissionRule]?
    /// Rules for tool calls that always ask, even when another rule allows them.
    public var ask: [PermissionRule]?
    /// The permission mode a session starts in.
    public var defaultMode: PermissionMode?
    /// Directories outside the working directory that tools may use.
    public var additionalDirectories: [String]?
    /// When `true`, `bypassPermissions` mode cannot be entered.
    public var disablesBypassPermissionsMode: Bool?
    /// When `true`, file tools refuse reads outside the working directories
    /// in every mode.
    public var blocksReadsOutsideWorkingDirectories: Bool?
    /// Fields of the `permissions` object this type does not model, kept so
    /// a read-modify-write does not drop them.
    public var additionalFields: [String: JSONValue]

    public init(
        allow: [PermissionRule]? = nil, deny: [PermissionRule]? = nil, ask: [PermissionRule]? = nil,
        defaultMode: PermissionMode? = nil, additionalDirectories: [String]? = nil,
        disablesBypassPermissionsMode: Bool? = nil, blocksReadsOutsideWorkingDirectories: Bool? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.allow = allow
        self.deny = deny
        self.ask = ask
        self.defaultMode = defaultMode
        self.additionalDirectories = additionalDirectories
        self.disablesBypassPermissionsMode = disablesBypassPermissionsMode
        self.blocksReadsOutsideWorkingDirectories = blocksReadsOutsideWorkingDirectories
        self.additionalFields = additionalFields
    }

    private static let modeledFields: Set<String> = [
        "allow", "deny", "ask", "defaultMode", "additionalDirectories", "disableBypassPermissionsMode",
        "blockReadsOutsideWorkingDirectories",
    ]

    /// Reads a `permissions` object; a field of the wrong shape reads as `nil`.
    public init?(settingsJSON json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        self.init(
            allow: object["allow"].flatMap([PermissionRule].init(settingsJSON:)),
            deny: object["deny"].flatMap([PermissionRule].init(settingsJSON:)),
            ask: object["ask"].flatMap([PermissionRule].init(settingsJSON:)),
            // The CLI accepts `manual` for `default`.
            defaultMode: object["defaultMode"]?.stringValue.flatMap {
                PermissionMode(rawValue: $0 == "manual" ? "default" : $0)
            },
            additionalDirectories: object["additionalDirectories"].flatMap([String].init(settingsJSON:)),
            disablesBypassPermissionsMode: object["disableBypassPermissionsMode"].map { $0.stringValue == "disable" },
            blocksReadsOutsideWorkingDirectories: object["blockReadsOutsideWorkingDirectories"]?.boolValue,
            additionalFields: object.filter { !Self.modeledFields.contains($0.key) })
    }

    public var settingsJSON: JSONValue {
        var object = additionalFields
        object["allow"] = allow?.settingsJSON
        object["deny"] = deny?.settingsJSON
        object["ask"] = ask?.settingsJSON
        object["defaultMode"] = defaultMode?.settingsJSON
        object["additionalDirectories"] = additionalDirectories?.settingsJSON
        // The schema has no "enabled" spelling; off is expressed by absence.
        object["disableBypassPermissionsMode"] = disablesBypassPermissionsMode == true ? "disable" : nil
        object["blockReadsOutsideWorkingDirectories"] = blocksReadsOutsideWorkingDirectories?.settingsJSON
        return .object(object)
    }
}
