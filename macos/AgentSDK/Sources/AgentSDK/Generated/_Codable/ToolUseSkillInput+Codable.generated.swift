import Foundation

extension ToolUseSkillInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseSkillInput")
        self._raw = r.dict
        self.args = r.string("args")
        self.skill = r.string("skill")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseSkillInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = args { d["args"] = v }
        if let v = skill { d["skill"] = v }
        return d
    }
}
