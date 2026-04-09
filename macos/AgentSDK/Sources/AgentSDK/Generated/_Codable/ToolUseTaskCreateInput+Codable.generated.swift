import Foundation

extension ToolUseTaskCreateInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseTaskCreateInput")
        self._raw = r.dict
        self.activeForm = r.string("active_form", alt: "activeForm")
        self.description = r.string("description")
        self.subject = r.string("subject")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseTaskCreateInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = activeForm { d["active_form"] = v }
        if let v = description { d["description"] = v }
        if let v = subject { d["subject"] = v }
        return d
    }
}
