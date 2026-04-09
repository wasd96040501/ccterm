import Foundation

extension ToolUse {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["name"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "Agent":
            let _v: Agent = try _jp(dict)
            self = .Agent(_v)
        case "AskUserQuestion":
            let _v: ToolUseAskUserQuestion = try _jp(dict)
            self = .AskUserQuestion(_v)
        case "Bash":
            let _v: ToolUseBash = try _jp(dict)
            self = .Bash(_v)
        case "CronCreate":
            let _v: ToolUseCronCreate = try _jp(dict)
            self = .CronCreate(_v)
        case "Edit":
            let _v: ToolUseEdit = try _jp(dict)
            self = .Edit(_v)
        case "EnterPlanMode":
            let _v: ToolUseEnterPlanMode = try _jp(dict)
            self = .EnterPlanMode(_v)
        case "EnterWorktree":
            let _v: ToolUseEnterWorktree = try _jp(dict)
            self = .EnterWorktree(_v)
        case "ExitPlanMode":
            let _v: ToolUseExitPlanMode = try _jp(dict)
            self = .ExitPlanMode(_v)
        case "ExitWorktree":
            let _v: ToolUseExitWorktree = try _jp(dict)
            self = .ExitWorktree(_v)
        case "Glob":
            let _v: ToolUseGlob = try _jp(dict)
            self = .Glob(_v)
        case "Grep":
            let _v: ToolUseGrep = try _jp(dict)
            self = .Grep(_v)
        case "Read":
            let _v: ToolUseRead = try _jp(dict)
            self = .Read(_v)
        case "SendMessage":
            let _v: ToolUseSendMessage = try _jp(dict)
            self = .SendMessage(_v)
        case "Skill":
            let _v: ToolUseSkill = try _jp(dict)
            self = .Skill(_v)
        case "Task":
            let _v: ToolUseTask = try _jp(dict)
            self = .Task(_v)
        case "TaskCreate":
            let _v: ToolUseTaskCreate = try _jp(dict)
            self = .TaskCreate(_v)
        case "TaskOutput":
            let _v: ToolUseTaskOutput = try _jp(dict)
            self = .TaskOutput(_v)
        case "TaskStop":
            let _v: ToolUseTaskStop = try _jp(dict)
            self = .TaskStop(_v)
        case "TaskUpdate":
            let _v: ToolUseTaskUpdate = try _jp(dict)
            self = .TaskUpdate(_v)
        case "TeamCreate":
            let _v: ToolUseTeamCreate = try _jp(dict)
            self = .TeamCreate(_v)
        case "TodoWrite":
            let _v: ToolUseTodoWrite = try _jp(dict)
            self = .TodoWrite(_v)
        case "ToolSearch":
            let _v: ToolUseToolSearch = try _jp(dict)
            self = .ToolSearch(_v)
        case "WebFetch":
            let _v: ToolUseWebFetch = try _jp(dict)
            self = .WebFetch(_v)
        case "WebSearch":
            let _v: ToolUseWebSearch = try _jp(dict)
            self = .WebSearch(_v)
        case "Write":
            let _v: ToolUseWrite = try _jp(dict)
            self = .Write(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .Agent(let v): return v.toJSON()
        case .AskUserQuestion(let v): return v.toJSON()
        case .Bash(let v): return v.toJSON()
        case .CronCreate(let v): return v.toJSON()
        case .Edit(let v): return v.toJSON()
        case .EnterPlanMode(let v): return v.toJSON()
        case .EnterWorktree(let v): return v.toJSON()
        case .ExitPlanMode(let v): return v.toJSON()
        case .ExitWorktree(let v): return v.toJSON()
        case .Glob(let v): return v.toJSON()
        case .Grep(let v): return v.toJSON()
        case .Read(let v): return v.toJSON()
        case .SendMessage(let v): return v.toJSON()
        case .Skill(let v): return v.toJSON()
        case .Task(let v): return v.toJSON()
        case .TaskCreate(let v): return v.toJSON()
        case .TaskOutput(let v): return v.toJSON()
        case .TaskStop(let v): return v.toJSON()
        case .TaskUpdate(let v): return v.toJSON()
        case .TeamCreate(let v): return v.toJSON()
        case .TodoWrite(let v): return v.toJSON()
        case .ToolSearch(let v): return v.toJSON()
        case .WebFetch(let v): return v.toJSON()
        case .WebSearch(let v): return v.toJSON()
        case .Write(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension ToolUse {
    public func strippingUnknown() -> ToolUse? {
        switch self {
        case .unknown: return nil
        case .Agent(let v): return v.strippingUnknown().map { .Agent($0) }
        case .AskUserQuestion(let v): return v.strippingUnknown().map { .AskUserQuestion($0) }
        case .Bash(let v): return v.strippingUnknown().map { .Bash($0) }
        case .CronCreate(let v): return v.strippingUnknown().map { .CronCreate($0) }
        case .Edit(let v): return v.strippingUnknown().map { .Edit($0) }
        case .EnterPlanMode(let v): return v.strippingUnknown().map { .EnterPlanMode($0) }
        case .EnterWorktree(let v): return v.strippingUnknown().map { .EnterWorktree($0) }
        case .ExitPlanMode(let v): return v.strippingUnknown().map { .ExitPlanMode($0) }
        case .ExitWorktree(let v): return v.strippingUnknown().map { .ExitWorktree($0) }
        case .Glob(let v): return v.strippingUnknown().map { .Glob($0) }
        case .Grep(let v): return v.strippingUnknown().map { .Grep($0) }
        case .Read(let v): return v.strippingUnknown().map { .Read($0) }
        case .SendMessage(let v): return v.strippingUnknown().map { .SendMessage($0) }
        case .Skill(let v): return v.strippingUnknown().map { .Skill($0) }
        case .Task(let v): return v.strippingUnknown().map { .Task($0) }
        case .TaskCreate(let v): return v.strippingUnknown().map { .TaskCreate($0) }
        case .TaskOutput(let v): return v.strippingUnknown().map { .TaskOutput($0) }
        case .TaskStop(let v): return v.strippingUnknown().map { .TaskStop($0) }
        case .TaskUpdate(let v): return v.strippingUnknown().map { .TaskUpdate($0) }
        case .TeamCreate(let v): return v.strippingUnknown().map { .TeamCreate($0) }
        case .TodoWrite(let v): return v.strippingUnknown().map { .TodoWrite($0) }
        case .ToolSearch(let v): return v.strippingUnknown().map { .ToolSearch($0) }
        case .WebFetch(let v): return v.strippingUnknown().map { .WebFetch($0) }
        case .WebSearch(let v): return v.strippingUnknown().map { .WebSearch($0) }
        case .Write(let v): return v.strippingUnknown().map { .Write($0) }
        }
    }
}

extension ToolUse {
    public func toTypedJSON() -> Any {
        switch self {
        case .Agent(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Agent"
            return d
        case .AskUserQuestion(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "AskUserQuestion"
            return d
        case .Bash(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Bash"
            return d
        case .CronCreate(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "CronCreate"
            return d
        case .Edit(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Edit"
            return d
        case .EnterPlanMode(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "EnterPlanMode"
            return d
        case .EnterWorktree(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "EnterWorktree"
            return d
        case .ExitPlanMode(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "ExitPlanMode"
            return d
        case .ExitWorktree(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "ExitWorktree"
            return d
        case .Glob(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Glob"
            return d
        case .Grep(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Grep"
            return d
        case .Read(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Read"
            return d
        case .SendMessage(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "SendMessage"
            return d
        case .Skill(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Skill"
            return d
        case .Task(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Task"
            return d
        case .TaskCreate(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "TaskCreate"
            return d
        case .TaskOutput(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "TaskOutput"
            return d
        case .TaskStop(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "TaskStop"
            return d
        case .TaskUpdate(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "TaskUpdate"
            return d
        case .TeamCreate(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "TeamCreate"
            return d
        case .TodoWrite(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "TodoWrite"
            return d
        case .ToolSearch(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "ToolSearch"
            return d
        case .WebFetch(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "WebFetch"
            return d
        case .WebSearch(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "WebSearch"
            return d
        case .Write(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["name"] = "Write"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}

extension ToolUse {
    public var caseName: String {
        switch self {
        case .Agent: return "Agent"
        case .AskUserQuestion: return "AskUserQuestion"
        case .Bash: return "Bash"
        case .CronCreate: return "CronCreate"
        case .Edit: return "Edit"
        case .EnterPlanMode: return "EnterPlanMode"
        case .EnterWorktree: return "EnterWorktree"
        case .ExitPlanMode: return "ExitPlanMode"
        case .ExitWorktree: return "ExitWorktree"
        case .Glob: return "Glob"
        case .Grep: return "Grep"
        case .Read: return "Read"
        case .SendMessage: return "SendMessage"
        case .Skill: return "Skill"
        case .Task: return "Task"
        case .TaskCreate: return "TaskCreate"
        case .TaskOutput: return "TaskOutput"
        case .TaskStop: return "TaskStop"
        case .TaskUpdate: return "TaskUpdate"
        case .TeamCreate: return "TeamCreate"
        case .TodoWrite: return "TodoWrite"
        case .ToolSearch: return "ToolSearch"
        case .WebFetch: return "WebFetch"
        case .WebSearch: return "WebSearch"
        case .Write: return "Write"
        case .unknown(let name, _): return name
        }
    }
}

extension ToolUse {
    public var id: String? {
        switch self {
        case .Agent(let v): return v.id
        case .AskUserQuestion(let v): return v.id
        case .Bash(let v): return v.id
        case .CronCreate(let v): return v.id
        case .Edit(let v): return v.id
        case .EnterPlanMode(let v): return v.id
        case .EnterWorktree(let v): return v.id
        case .ExitPlanMode(let v): return v.id
        case .ExitWorktree(let v): return v.id
        case .Glob(let v): return v.id
        case .Grep(let v): return v.id
        case .Read(let v): return v.id
        case .SendMessage(let v): return v.id
        case .Skill(let v): return v.id
        case .Task(let v): return v.id
        case .TaskCreate(let v): return v.id
        case .TaskOutput(let v): return v.id
        case .TaskStop(let v): return v.id
        case .TaskUpdate(let v): return v.id
        case .TeamCreate(let v): return v.id
        case .TodoWrite(let v): return v.id
        case .ToolSearch(let v): return v.id
        case .WebFetch(let v): return v.id
        case .WebSearch(let v): return v.id
        case .Write(let v): return v.id
        case .unknown: return nil
        }
    }
}
