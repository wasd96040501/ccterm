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

