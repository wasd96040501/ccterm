import Foundation

extension Message2 {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["type"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "assistant":
            let _v: Message2Assistant = try _jp(dict)
            self = .assistant(_v)
        case "custom-title":
            let _v: CustomTitle = try _jp(dict)
            self = .customTitle(_v)
        case "file-history-snapshot":
            let _v: FileHistorySnapshot = try _jp(dict)
            self = .fileHistorySnapshot(_v)
        case "last-prompt":
            let _v: LastPrompt = try _jp(dict)
            self = .lastPrompt(_v)
        case "progress":
            let _v: Message2Progress = try _jp(dict)
            self = .progress(_v)
        case "prompt_suggestion":
            let _v: PromptSuggestion = try _jp(dict)
            self = .promptSuggestion(_v)
        case "queue-operation":
            let _v: QueueOperation = try _jp(dict)
            self = .queueOperation(_v)
        case "rate_limit_event":
            let _v: RateLimitEvent = try _jp(dict)
            self = .rateLimitEvent(_v)
        case "result":
            let _v: Message2Result = try _jp(dict)
            self = .result(_v)
        case "system":
            let _v: System = try _jp(dict)
            self = .system(_v)
        case "user":
            let _v: Message2User = try _jp(dict)
            self = .user(_v)
        case "worktree-state":
            let _v: WorktreeState = try _jp(dict)
            self = .worktreeState(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .assistant(let v): return v.toJSON()
        case .customTitle(let v): return v.toJSON()
        case .fileHistorySnapshot(let v): return v.toJSON()
        case .lastPrompt(let v): return v.toJSON()
        case .progress(let v): return v.toJSON()
        case .promptSuggestion(let v): return v.toJSON()
        case .queueOperation(let v): return v.toJSON()
        case .rateLimitEvent(let v): return v.toJSON()
        case .result(let v): return v.toJSON()
        case .system(let v): return v.toJSON()
        case .user(let v): return v.toJSON()
        case .worktreeState(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension Message2 {
    public func strippingUnknown() -> Message2? {
        switch self {
        case .unknown: return nil
        case .assistant(let v): return v.strippingUnknown().map { .assistant($0) }
        case .customTitle(let v): return v.strippingUnknown().map { .customTitle($0) }
        case .fileHistorySnapshot(let v): return v.strippingUnknown().map { .fileHistorySnapshot($0) }
        case .lastPrompt(let v): return v.strippingUnknown().map { .lastPrompt($0) }
        case .progress(let v): return v.strippingUnknown().map { .progress($0) }
        case .promptSuggestion(let v): return v.strippingUnknown().map { .promptSuggestion($0) }
        case .queueOperation(let v): return v.strippingUnknown().map { .queueOperation($0) }
        case .rateLimitEvent(let v): return v.strippingUnknown().map { .rateLimitEvent($0) }
        case .result(let v): return v.strippingUnknown().map { .result($0) }
        case .system(let v): return v.strippingUnknown().map { .system($0) }
        case .user(let v): return v.strippingUnknown().map { .user($0) }
        case .worktreeState(let v): return v.strippingUnknown().map { .worktreeState($0) }
        }
    }
}

extension Message2 {
    public func toTypedJSON() -> Any {
        switch self {
        case .assistant(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "assistant"
            return d
        case .customTitle(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "custom-title"
            return d
        case .fileHistorySnapshot(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "file-history-snapshot"
            return d
        case .lastPrompt(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "last-prompt"
            return d
        case .progress(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "progress"
            return d
        case .promptSuggestion(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "prompt_suggestion"
            return d
        case .queueOperation(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "queue-operation"
            return d
        case .rateLimitEvent(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "rate_limit_event"
            return d
        case .result(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "result"
            return d
        case .system(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "system"
            return d
        case .user(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "user"
            return d
        case .worktreeState(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "worktree-state"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
