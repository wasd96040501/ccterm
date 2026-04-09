import Foundation

extension FileHistorySnapshot {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "FileHistorySnapshot")
        self._raw = r.dict
        self.isSnapshotUpdate = r.bool("is_snapshot_update", alt: "isSnapshotUpdate")
        self.messageId = r.string("message_id", alt: "messageId")
        self.snapshot = r.decodeIfPresent("snapshot")
    }

    public func toJSON() -> Any { _raw }
}

extension FileHistorySnapshot {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = isSnapshotUpdate { d["is_snapshot_update"] = v }
        if let v = messageId { d["message_id"] = v }
        if let v = snapshot { d["snapshot"] = v.toTypedJSON() }
        return d
    }
}
