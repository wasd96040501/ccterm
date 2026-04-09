import Foundation

extension Snapshot {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "Snapshot")
        self._raw = r.dict
        self.messageId = r.string("message_id", alt: "messageId")
        self.timestamp = r.string("timestamp")
        self.trackedFileBackups = try? r.decodeMap("tracked_file_backups", alt: "trackedFileBackups")
    }

    public func toJSON() -> Any { _raw }
}

extension Snapshot {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = messageId { d["message_id"] = v }
        if let v = timestamp { d["timestamp"] = v }
        if let v = trackedFileBackups { d["tracked_file_backups"] = v.mapValues { $0.toTypedJSON() } }
        return d
    }
}
