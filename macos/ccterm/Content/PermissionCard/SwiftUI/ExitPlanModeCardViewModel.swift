import SwiftUI
import Observation
import AgentSDK

@Observable
final class ExitPlanModeCardViewModel {
    let request: PermissionRequest
    let planMarkdown: String?
    private let onDecision: (PermissionDecision) -> Void
    private let onNewSession: (() -> Void)?

    // MARK: - Plan Fullscreen Support

    var commentStore: PlanCommentStore?
    var onViewPlan: (() -> Void)?
    var onExecute: ((PlanExecutionMode) -> Void)?

    var hasPlan: Bool { !(planMarkdown ?? "").isEmpty }

    /// Plan markdown 中第一个 heading 的文字（去掉 `#` 前缀），用于卡片标题。
    var planTitle: String? {
        guard let md = planMarkdown else { return nil }
        let lines = md.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return nil
    }

    /// Plan markdown 中第一行非 heading、非空的文字，用于卡片副标题。
    var planSubtitle: String? {
        guard let md = planMarkdown else { return nil }
        let lines = md.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return trimmed
        }
        return nil
    }

    init(
        request: PermissionRequest,
        onDecision: @escaping (PermissionDecision) -> Void,
        onNewSession: (() -> Void)?
    ) {
        self.request = request
        self.onDecision = onDecision
        self.onNewSession = onNewSession
        if case .ExitPlanMode(let v) = request.toolInput {
            self.planMarkdown = v.input?.plan
            appLog(.debug, "PlanDebug", "ExitPlanModeCardVM init: toolInput matched, plan length=\(v.input?.plan?.count ?? -1), input=\(String(describing: v.input))")
        } else {
            self.planMarkdown = nil
            appLog(.debug, "PlanDebug", "ExitPlanModeCardVM init: toolInput NOT ExitPlanMode, got \(String(describing: request.toolInput))")
        }

        appLog(.debug, "PlanDebug", "ExitPlanModeCardVM init: hasPlan=\(hasPlan) requestId=\(request.requestId)")

        if hasPlan {
            self.commentStore = PlanCommentStore(permissionRequestId: request.requestId)
        }
    }

    // MARK: - Confirm / Deny

    /// Primary confirm (Cmd+Return): view plan if available, otherwise allow.
    func confirm() {
        if hasPlan {
            onViewPlan?()
        } else {
            onDecision(request.allowOnce())
        }
    }

    func deny(feedback: String? = nil) {
        PlanCommentStore.cleanup(permissionRequestId: request.requestId)
        if let feedback, !feedback.isEmpty {
            onDecision(request.deny(feedback: feedback))
        } else {
            onDecision(request.deny())
        }
    }

    // MARK: - Decision Methods (called from PlanReviewViewModel)

    func executeNewSession() { onNewSession?() }
    func executeAllow() { onDecision(request.allowOnce()) }
    func executeDeny() { onDecision(request.deny()) }
    func executeDenyWithFeedback(_ feedback: String) { onDecision(request.deny(feedback: feedback)) }
}
