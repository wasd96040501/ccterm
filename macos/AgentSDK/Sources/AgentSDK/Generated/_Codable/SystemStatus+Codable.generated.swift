import Foundation

extension SystemStatus {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "SystemStatus")
        self._raw = r.dict
        self.permissionMode = r.string("permission_mode", alt: "permissionMode")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.status = r.raw("status")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension SystemStatus {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = permissionMode { d["permission_mode"] = v }
        if let v = sessionId { d["session_id"] = v }
        if let v = status { d["status"] = v }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}
