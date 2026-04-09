import Foundation

extension System {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["subtype"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "api_error":
            let _v: ApiError = try _jp(dict)
            self = .apiError(_v)
        case "compact_boundary":
            let _v: CompactBoundary = try _jp(dict)
            self = .compactBoundary(_v)
        case "informational":
            let _v: Informational = try _jp(dict)
            self = .informational(_v)
        case "init":
            let _v: Init = try _jp(dict)
            self = .`init`(_v)
        case "local_command":
            let _v: LocalCommand = try _jp(dict)
            self = .localCommand(_v)
        case "microcompact_boundary":
            let _v: MicrocompactBoundary = try _jp(dict)
            self = .microcompactBoundary(_v)
        case "status":
            let _v: SystemStatus = try _jp(dict)
            self = .status(_v)
        case "task_notification":
            let _v: TaskNotification = try _jp(dict)
            self = .taskNotification(_v)
        case "task_progress":
            let _v: TaskProgress = try _jp(dict)
            self = .taskProgress(_v)
        case "task_started":
            let _v: TaskStarted = try _jp(dict)
            self = .taskStarted(_v)
        case "turn_duration":
            let _v: TurnDuration = try _jp(dict)
            self = .turnDuration(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .apiError(let v): return v.toJSON()
        case .compactBoundary(let v): return v.toJSON()
        case .informational(let v): return v.toJSON()
        case .`init`(let v): return v.toJSON()
        case .localCommand(let v): return v.toJSON()
        case .microcompactBoundary(let v): return v.toJSON()
        case .status(let v): return v.toJSON()
        case .taskNotification(let v): return v.toJSON()
        case .taskProgress(let v): return v.toJSON()
        case .taskStarted(let v): return v.toJSON()
        case .turnDuration(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension System {
    public func strippingUnknown() -> System? {
        switch self {
        case .unknown: return nil
        case .apiError(let v): return v.strippingUnknown().map { .apiError($0) }
        case .compactBoundary(let v): return v.strippingUnknown().map { .compactBoundary($0) }
        case .informational(let v): return v.strippingUnknown().map { .informational($0) }
        case .`init`(let v): return v.strippingUnknown().map { .`init`($0) }
        case .localCommand(let v): return v.strippingUnknown().map { .localCommand($0) }
        case .microcompactBoundary(let v): return v.strippingUnknown().map { .microcompactBoundary($0) }
        case .status(let v): return v.strippingUnknown().map { .status($0) }
        case .taskNotification(let v): return v.strippingUnknown().map { .taskNotification($0) }
        case .taskProgress(let v): return v.strippingUnknown().map { .taskProgress($0) }
        case .taskStarted(let v): return v.strippingUnknown().map { .taskStarted($0) }
        case .turnDuration(let v): return v.strippingUnknown().map { .turnDuration($0) }
        }
    }
}

extension System {
    public func toTypedJSON() -> Any {
        switch self {
        case .apiError(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "api_error"
            return d
        case .compactBoundary(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "compact_boundary"
            return d
        case .informational(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "informational"
            return d
        case .`init`(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "init"
            return d
        case .localCommand(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "local_command"
            return d
        case .microcompactBoundary(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "microcompact_boundary"
            return d
        case .status(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "status"
            return d
        case .taskNotification(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "task_notification"
            return d
        case .taskProgress(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "task_progress"
            return d
        case .taskStarted(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "task_started"
            return d
        case .turnDuration(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["subtype"] = "turn_duration"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
