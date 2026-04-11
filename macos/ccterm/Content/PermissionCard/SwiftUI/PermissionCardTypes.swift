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
    case bash(description: String?, command: String)
    case read(filePath: String?)
    case write(filePath: String?, oldString: String, newString: String)
    case edit(filePath: String?, oldString: String, newString: String)
    case glob(pattern: String?, path: String?)
    case grep(pattern: String?, path: String?, glob: String?)
    case webFetch(url: String?)
    case webSearch(query: String?, prompt: String?)
    case generic(reason: String?, fields: [(key: String, value: String)])

    static func from(_ request: PermissionRequest) -> Self {
        switch request.toolInput {
        case .Bash(let v):
            return .bash(description: v.input?.description, command: v.input?.command ?? "")
        case .Read(let v):
            return .read(filePath: v.input?.filePath)
        case .Write(let v):
            return .write(
                filePath: v.input?.filePath,
                oldString: "",
                newString: v.input?.content ?? ""
            )
        case .Edit(let v):
            return .edit(
                filePath: v.input?.filePath,
                oldString: v.input?.oldString ?? "",
                newString: v.input?.newString ?? ""
            )
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
