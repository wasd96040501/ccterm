import SwiftUI
import AgentSDK

// MARK: - PermissionCardItem

struct PermissionCardItem: Identifiable {
    let id: String
    let cardType: PermissionCardType
}

// MARK: - PermissionCardType

enum PermissionCardType {
    case standard(StandardCardViewModel)
    case exitPlanMode(ExitPlanModeCardViewModel)
    case askUserQuestion(AskUserQuestionCardViewModel)

    var canConfirm: Bool {
        switch self {
        case .standard: true
        case .exitPlanMode: true
        case .askUserQuestion(let vm): vm.allAnswered
        }
    }

    func confirm() {
        switch self {
        case .standard(let vm): vm.confirm()
        case .exitPlanMode(let vm): vm.confirm()
        case .askUserQuestion(let vm): vm.confirm()
        }
    }

    func deny() {
        switch self {
        case .standard(let vm): vm.deny()
        case .exitPlanMode(let vm): vm.deny()
        case .askUserQuestion(let vm): vm.deny()
        }
    }
}

// MARK: - PermissionOption (legacy, kept for compatibility)

struct PermissionOption: Identifiable {
    let id: Int
    let title: String
    let makeDecision: (PermissionRequest) -> PermissionDecision
}

// MARK: - ToolContentDescriptor

enum ToolContentDescriptor {
    case bash(description: String?, tokens: [BashToken])
    case read(filePath: String?)
    case write(filePath: String?, hunks: [DiffEngine.Hunk])
    case edit(filePath: String?, hunks: [DiffEngine.Hunk])
    case glob(pattern: String?, path: String?)
    case grep(pattern: String?, path: String?, glob: String?)
    case webFetch(url: String?)
    case webSearch(query: String?, prompt: String?)
    case generic(reason: String?, fields: [(key: String, value: String)])

    static func from(_ request: PermissionRequest) -> Self {
        switch request.toolInput {
        case .Bash(let v):
            let command = v.input?.command
            let tokens: [BashToken] = {
                guard let cmd = command, !cmd.isEmpty else { return [] }
                let clean = cmd.replacingOccurrences(
                    of: "\\x1b\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
                return BashHighlighter.tokenize(clean)
            }()
            return .bash(description: v.input?.description, tokens: tokens)
        case .Read(let v):
            return .read(filePath: v.input?.filePath)
        case .Write(let v):
            let content = v.input?.content
            let hunks: [DiffEngine.Hunk] = {
                guard let c = content, !c.isEmpty else { return [] }
                return DiffEngine.computeHunks(old: "", new: c)
            }()
            return .write(filePath: v.input?.filePath, hunks: hunks)
        case .Edit(let v):
            let oldStr = v.input?.oldString ?? ""
            let newStr = v.input?.newString ?? ""
            let hunks: [DiffEngine.Hunk] = {
                guard !oldStr.isEmpty || !newStr.isEmpty else { return [] }
                return DiffEngine.computeHunks(old: oldStr, new: newStr)
            }()
            return .edit(filePath: v.input?.filePath, hunks: hunks)
        case .Glob(let v):
            return .glob(pattern: v.input?.pattern, path: v.input?.path)
        case .Grep(let v):
            return .grep(pattern: v.input?.pattern, path: v.input?.path, glob: v.input?.glob)
        case .WebFetch(let v):
            return .webFetch(url: v.input?.url)
        case .WebSearch(let v):
            let prompt = request.rawInput["prompt"] as? String
            return .webSearch(query: v.input?.query, prompt: prompt)
        default:
            var fields: [(key: String, value: String)] = []
            for key in request.rawInput.keys.sorted() {
                if let value = request.rawInput[key] as? String, !value.isEmpty {
                    fields.append((key: key, value: value))
                }
            }
            let reason = request.decisionReason?.reason
            return .generic(reason: reason, fields: fields)
        }
    }
}
