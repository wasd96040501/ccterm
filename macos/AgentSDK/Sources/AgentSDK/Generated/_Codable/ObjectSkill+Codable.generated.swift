import Foundation

extension ObjectSkill {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ObjectSkill")
        self._raw = r.dict
        self.allowedTools = r.stringArray("allowed_tools", alt: "allowedTools")
        self.commandName = r.string("command_name", alt: "commandName")
        self.success = r.bool("success")
    }

    public func toJSON() -> Any { _raw }
}

extension ObjectSkill {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = allowedTools { d["allowed_tools"] = v }
        if let v = commandName { d["command_name"] = v }
        if let v = success { d["success"] = v }
        return d
    }
}
