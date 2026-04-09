import Foundation

extension ToolUseExitPlanModeInput {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ToolUseExitPlanModeInput")
        self._raw = r.dict
        self.allowedPrompts = try? r.decodeArrayIfPresent("allowed_prompts", alt: "allowedPrompts")
        self.plan = r.string("plan")
        self.planFilePath = r.string("plan_file_path", alt: "planFilePath")
    }

    public func toJSON() -> Any { _raw }
}

extension ToolUseExitPlanModeInput {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = allowedPrompts { d["allowed_prompts"] = v.map { $0.toTypedJSON() } }
        if let v = plan { d["plan"] = v }
        if let v = planFilePath { d["plan_file_path"] = v }
        return d
    }
}
