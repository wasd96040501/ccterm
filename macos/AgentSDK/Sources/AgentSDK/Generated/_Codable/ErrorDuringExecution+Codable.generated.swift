import Foundation

extension ErrorDuringExecution {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ErrorDuringExecution")
        self._raw = r.dict
        self.durationApiMs = r.int("duration_api_ms")
        self.durationMs = r.int("duration_ms", alt: "durationMs")
        self.errors = r.stringArray("errors")
        self.fastModeState = r.string("fast_mode_state")
        self.isError = r.bool("is_error")
        self.modelUsage = try? r.decodeMap("model_usage", alt: "modelUsage")
        self.numTurns = r.int("num_turns")
        self.permissionDenials = try? r.decodeArrayIfPresent("permission_denials")
        self.sessionId = r.string("session_id", alt: "sessionId")
        self.stopReason = r.string("stop_reason")
        self.totalCostUsd = r.double("total_cost_usd")
        self.usage = r.decodeIfPresent("usage")
        self.uuid = r.string("uuid")
    }

    public func toJSON() -> Any { _raw }
}

extension ErrorDuringExecution {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = durationApiMs { d["duration_api_ms"] = v }
        if let v = durationMs { d["duration_ms"] = v }
        if let v = errors { d["errors"] = v }
        if let v = fastModeState { d["fast_mode_state"] = v }
        if let v = isError { d["is_error"] = v }
        if let v = modelUsage { d["model_usage"] = v.mapValues { $0.toTypedJSON() } }
        if let v = numTurns { d["num_turns"] = v }
        if let v = permissionDenials { d["permission_denials"] = v.map { $0.toTypedJSON() } }
        if let v = sessionId { d["session_id"] = v }
        if let v = stopReason { d["stop_reason"] = v }
        if let v = totalCostUsd { d["total_cost_usd"] = v }
        if let v = usage { d["usage"] = v.toTypedJSON() }
        if let v = uuid { d["uuid"] = v }
        return d
    }
}
