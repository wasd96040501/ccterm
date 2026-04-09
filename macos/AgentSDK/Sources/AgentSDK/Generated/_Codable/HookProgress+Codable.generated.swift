import Foundation

extension HookProgress {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "HookProgress")
        self._raw = r.dict
        self.command = r.string("command")
        self.hookEvent = r.string("hook_event", alt: "hookEvent")
        self.hookName = r.string("hook_name", alt: "hookName")
    }

    public func toJSON() -> Any { _raw }
}

extension HookProgress {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = command { d["command"] = v }
        if let v = hookEvent { d["hook_event"] = v }
        if let v = hookName { d["hook_name"] = v }
        return d
    }
}
