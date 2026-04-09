import Foundation

extension TrackedFileBackupsValue {
    public init(json: Any) throws {
        let r = try JSONReader(json, context: "TrackedFileBackupsValue")
        self._raw = r.dict
        self.backupFileName = r.string("backup_file_name", alt: "backupFileName")
        self.backupTime = r.string("backup_time", alt: "backupTime")
        self.version = r.int("version")
    }

    public func toJSON() -> Any { _raw }
}

extension TrackedFileBackupsValue {
    public func toTypedJSON() -> Any {
        var d: [String: Any] = [:]
        if let v = backupFileName { d["backup_file_name"] = v }
        if let v = backupTime { d["backup_time"] = v }
        if let v = version { d["version"] = v }
        return d
    }
}
