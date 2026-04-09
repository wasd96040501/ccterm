import Foundation

extension ToolUseResultObject {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unresolved", raw: [:], origin: nil); return
        }
        self = .unknown(name: "unresolved", raw: dict, origin: nil)
    }

    public var isUnresolved: Bool {
        if case .unknown(let name, _, _) = self { return name == "unresolved" }
        return false
    }

    public mutating func resolve(from origin: ToolUse) throws {
        guard isUnresolved, case .unknown(_, let raw, _) = self else { return }
        switch origin {
        case .AskUserQuestion(let _originData):
            self = .AskUserQuestion(try _jp(raw), origin: _originData)
        case .Bash(let _originData):
            self = .Bash(try _jp(raw), origin: _originData)
        case .CronCreate(let _originData):
            self = .CronCreate(try _jp(raw), origin: _originData)
        case .Edit(let _originData):
            self = .Edit(try _jp(raw), origin: _originData)
        case .EnterPlanMode(let _originData):
            self = .EnterPlanMode(try _jp(raw), origin: _originData)
        case .EnterWorktree(let _originData):
            self = .EnterWorktree(try _jp(raw), origin: _originData)
        case .ExitPlanMode(let _originData):
            self = .ExitPlanMode(try _jp(raw), origin: _originData)
        case .ExitWorktree(let _originData):
            self = .ExitWorktree(try _jp(raw), origin: _originData)
        case .Glob(let _originData):
            self = .Glob(try _jp(raw), origin: _originData)
        case .Grep(let _originData):
            self = .Grep(try _jp(raw), origin: _originData)
        case .SendMessage(let _originData):
            self = .SendMessage(try _jp(raw), origin: _originData)
        case .Skill(let _originData):
            self = .Skill(try _jp(raw), origin: _originData)
        case .Task(let _originData):
            self = .Task(try _jp(raw), origin: _originData)
        case .TaskCreate(let _originData):
            self = .TaskCreate(try _jp(raw), origin: _originData)
        case .TaskOutput(let _originData):
            self = .TaskOutput(try _jp(raw), origin: _originData)
        case .TaskStop(let _originData):
            self = .TaskStop(try _jp(raw), origin: _originData)
        case .TaskUpdate(let _originData):
            self = .TaskUpdate(try _jp(raw), origin: _originData)
        case .TeamCreate(let _originData):
            self = .TeamCreate(try _jp(raw), origin: _originData)
        case .TodoWrite(let _originData):
            self = .TodoWrite(try _jp(raw), origin: _originData)
        case .ToolSearch(let _originData):
            self = .ToolSearch(try _jp(raw), origin: _originData)
        case .WebFetch(let _originData):
            self = .WebFetch(try _jp(raw), origin: _originData)
        case .WebSearch(let _originData):
            self = .WebSearch(try _jp(raw), origin: _originData)
        case .Write(let _originData):
            self = .Write(try _jp(raw), origin: _originData)
        default:
            self = .unknown(name: origin.caseName, raw: raw, origin: origin)
        }
    }

    public var toolUse: ToolUse? {
        switch self {
        case .AskUserQuestion(_, let o): return o.map { .AskUserQuestion($0) }
        case .Bash(_, let o): return o.map { .Bash($0) }
        case .CronCreate(_, let o): return o.map { .CronCreate($0) }
        case .Edit(_, let o): return o.map { .Edit($0) }
        case .EnterPlanMode(_, let o): return o.map { .EnterPlanMode($0) }
        case .EnterWorktree(_, let o): return o.map { .EnterWorktree($0) }
        case .ExitPlanMode(_, let o): return o.map { .ExitPlanMode($0) }
        case .ExitWorktree(_, let o): return o.map { .ExitWorktree($0) }
        case .Glob(_, let o): return o.map { .Glob($0) }
        case .Grep(_, let o): return o.map { .Grep($0) }
        case .SendMessage(_, let o): return o.map { .SendMessage($0) }
        case .Skill(_, let o): return o.map { .Skill($0) }
        case .Task(_, let o): return o.map { .Task($0) }
        case .TaskCreate(_, let o): return o.map { .TaskCreate($0) }
        case .TaskOutput(_, let o): return o.map { .TaskOutput($0) }
        case .TaskStop(_, let o): return o.map { .TaskStop($0) }
        case .TaskUpdate(_, let o): return o.map { .TaskUpdate($0) }
        case .TeamCreate(_, let o): return o.map { .TeamCreate($0) }
        case .TodoWrite(_, let o): return o.map { .TodoWrite($0) }
        case .ToolSearch(_, let o): return o.map { .ToolSearch($0) }
        case .WebFetch(_, let o): return o.map { .WebFetch($0) }
        case .WebSearch(_, let o): return o.map { .WebSearch($0) }
        case .Write(_, let o): return o.map { .Write($0) }
        case .unknown(_, _, let o): return o
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .AskUserQuestion(let v, _): return v.toJSON()
        case .Bash(let v, _): return v.toJSON()
        case .CronCreate(let v, _): return v.toJSON()
        case .Edit(let v, _): return v.toJSON()
        case .EnterPlanMode(let v, _): return v.toJSON()
        case .EnterWorktree(let v, _): return v.toJSON()
        case .ExitPlanMode(let v, _): return v.toJSON()
        case .ExitWorktree(let v, _): return v.toJSON()
        case .Glob(let v, _): return v.toJSON()
        case .Grep(let v, _): return v.toJSON()
        case .SendMessage(let v, _): return v.toJSON()
        case .Skill(let v, _): return v.toJSON()
        case .Task(let v, _): return v.toJSON()
        case .TaskCreate(let v, _): return v.toJSON()
        case .TaskOutput(let v, _): return v.toJSON()
        case .TaskStop(let v, _): return v.toJSON()
        case .TaskUpdate(let v, _): return v.toJSON()
        case .TeamCreate(let v, _): return v.toJSON()
        case .TodoWrite(let v, _): return v.toJSON()
        case .ToolSearch(let v, _): return v.toJSON()
        case .WebFetch(let v, _): return v.toJSON()
        case .WebSearch(let v, _): return v.toJSON()
        case .Write(let v, _): return v.toJSON()
        case .unknown(_, let raw, _): return raw
        }
    }
}

extension ToolUseResultObject {
    public func strippingUnknown() -> ToolUseResultObject? {
        switch self {
        case .unknown: return nil
        case .AskUserQuestion(let v, let o): return v.strippingUnknown().map { .AskUserQuestion($0, origin: o) }
        case .Bash(let v, let o): return v.strippingUnknown().map { .Bash($0, origin: o) }
        case .CronCreate(let v, let o): return v.strippingUnknown().map { .CronCreate($0, origin: o) }
        case .Edit(let v, let o): return v.strippingUnknown().map { .Edit($0, origin: o) }
        case .EnterPlanMode(let v, let o): return v.strippingUnknown().map { .EnterPlanMode($0, origin: o) }
        case .EnterWorktree(let v, let o): return v.strippingUnknown().map { .EnterWorktree($0, origin: o) }
        case .ExitPlanMode(let v, let o): return v.strippingUnknown().map { .ExitPlanMode($0, origin: o) }
        case .ExitWorktree(let v, let o): return v.strippingUnknown().map { .ExitWorktree($0, origin: o) }
        case .Glob(let v, let o): return v.strippingUnknown().map { .Glob($0, origin: o) }
        case .Grep(let v, let o): return v.strippingUnknown().map { .Grep($0, origin: o) }
        case .SendMessage(let v, let o): return v.strippingUnknown().map { .SendMessage($0, origin: o) }
        case .Skill(let v, let o): return v.strippingUnknown().map { .Skill($0, origin: o) }
        case .Task(let v, let o): return v.strippingUnknown().map { .Task($0, origin: o) }
        case .TaskCreate(let v, let o): return v.strippingUnknown().map { .TaskCreate($0, origin: o) }
        case .TaskOutput(let v, let o): return v.strippingUnknown().map { .TaskOutput($0, origin: o) }
        case .TaskStop(let v, let o): return v.strippingUnknown().map { .TaskStop($0, origin: o) }
        case .TaskUpdate(let v, let o): return v.strippingUnknown().map { .TaskUpdate($0, origin: o) }
        case .TeamCreate(let v, let o): return v.strippingUnknown().map { .TeamCreate($0, origin: o) }
        case .TodoWrite(let v, let o): return v.strippingUnknown().map { .TodoWrite($0, origin: o) }
        case .ToolSearch(let v, let o): return v.strippingUnknown().map { .ToolSearch($0, origin: o) }
        case .WebFetch(let v, let o): return v.strippingUnknown().map { .WebFetch($0, origin: o) }
        case .WebSearch(let v, let o): return v.strippingUnknown().map { .WebSearch($0, origin: o) }
        case .Write(let v, let o): return v.strippingUnknown().map { .Write($0, origin: o) }
        }
    }
}

extension ToolUseResultObject {
    public func toTypedJSON() -> Any {
        switch self {
        case .AskUserQuestion(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "AskUserQuestion"
            return d
        case .Bash(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "Bash"
            return d
        case .CronCreate(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "CronCreate"
            return d
        case .Edit(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "Edit"
            return d
        case .EnterPlanMode(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "EnterPlanMode"
            return d
        case .EnterWorktree(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "EnterWorktree"
            return d
        case .ExitPlanMode(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "ExitPlanMode"
            return d
        case .ExitWorktree(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "ExitWorktree"
            return d
        case .Glob(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "Glob"
            return d
        case .Grep(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "Grep"
            return d
        case .SendMessage(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "SendMessage"
            return d
        case .Skill(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "Skill"
            return d
        case .Task(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "Task"
            return d
        case .TaskCreate(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "TaskCreate"
            return d
        case .TaskOutput(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "TaskOutput"
            return d
        case .TaskStop(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "TaskStop"
            return d
        case .TaskUpdate(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "TaskUpdate"
            return d
        case .TeamCreate(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "TeamCreate"
            return d
        case .TodoWrite(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "TodoWrite"
            return d
        case .ToolSearch(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "ToolSearch"
            return d
        case .WebFetch(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "WebFetch"
            return d
        case .WebSearch(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "WebSearch"
            return d
        case .Write(let v, _):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["_resolved_tool"] = "Write"
            return d
        case .unknown(_, let raw, _): return raw
        }
    }
}
