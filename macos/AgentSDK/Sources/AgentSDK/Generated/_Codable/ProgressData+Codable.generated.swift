import Foundation

extension ProgressData {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["type"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "agent_progress":
            let _v: AgentProgress = try _jp(dict)
            self = .agentProgress(_v)
        case "bash_progress":
            let _v: BashProgress = try _jp(dict)
            self = .bashProgress(_v)
        case "hook_progress":
            let _v: HookProgress = try _jp(dict)
            self = .hookProgress(_v)
        case "query_update":
            let _v: QueryUpdate = try _jp(dict)
            self = .queryUpdate(_v)
        case "search_results_received":
            let _v: SearchResultsReceived = try _jp(dict)
            self = .searchResultsReceived(_v)
        case "waiting_for_task":
            let _v: WaitingForTask = try _jp(dict)
            self = .waitingForTask(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .agentProgress(let v): return v.toJSON()
        case .bashProgress(let v): return v.toJSON()
        case .hookProgress(let v): return v.toJSON()
        case .queryUpdate(let v): return v.toJSON()
        case .searchResultsReceived(let v): return v.toJSON()
        case .waitingForTask(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension ProgressData {
    public func strippingUnknown() -> ProgressData? {
        switch self {
        case .unknown: return nil
        case .agentProgress(let v): return v.strippingUnknown().map { .agentProgress($0) }
        case .bashProgress(let v): return v.strippingUnknown().map { .bashProgress($0) }
        case .hookProgress(let v): return v.strippingUnknown().map { .hookProgress($0) }
        case .queryUpdate(let v): return v.strippingUnknown().map { .queryUpdate($0) }
        case .searchResultsReceived(let v): return v.strippingUnknown().map { .searchResultsReceived($0) }
        case .waitingForTask(let v): return v.strippingUnknown().map { .waitingForTask($0) }
        }
    }
}

extension ProgressData {
    public func toTypedJSON() -> Any {
        switch self {
        case .agentProgress(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "agent_progress"
            return d
        case .bashProgress(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "bash_progress"
            return d
        case .hookProgress(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "hook_progress"
            return d
        case .queryUpdate(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "query_update"
            return d
        case .searchResultsReceived(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "search_results_received"
            return d
        case .waitingForTask(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "waiting_for_task"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
