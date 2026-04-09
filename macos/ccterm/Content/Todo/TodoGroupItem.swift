import SwiftUI

// MARK: - TodoGroup

enum TodoGroup: Int, CaseIterable, Identifiable {
    case pending = 0
    case needsConfirmation
    case inProgress
    case completed
    case archived
    case deleted

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .pending: return String(localized: "Pending")
        case .needsConfirmation: return String(localized: "Needs Confirmation")
        case .inProgress: return String(localized: "In Progress")
        case .completed: return String(localized: "Completed")
        case .archived: return String(localized: "Archived")
        case .deleted: return String(localized: "Deleted")
        }
    }

    func defaultExpanded(isEmpty: Bool) -> Bool {
        switch self {
        case .pending: return true
        default: return !isEmpty
        }
    }

    var emptyMessage: String {
        switch self {
        case .pending: return String(localized: "No pending tasks")
        case .needsConfirmation: return String(localized: "No tasks need confirmation")
        case .inProgress: return String(localized: "No tasks in progress")
        case .completed: return String(localized: "No completed tasks")
        case .archived: return String(localized: "No archived tasks")
        case .deleted: return String(localized: "No deleted tasks")
        }
    }

    var themeColor: Color {
        switch self {
        case .pending: return Color(.systemGray)
        case .needsConfirmation: return Color(.systemOrange)
        case .inProgress: return Color(.systemBlue)
        case .completed: return Color(.systemGreen)
        case .archived: return Color(.systemGray)
        case .deleted: return Color(.systemRed)
        }
    }

    var status: TodoStatus? {
        switch self {
        case .pending: return .pending
        case .needsConfirmation: return .needsConfirmation
        case .inProgress: return .inProgress
        case .completed: return .completed
        case .archived: return .merged
        case .deleted: return nil
        }
    }
}
