import AgentSDK

enum PermissionCardViewModelFactory {
    static func make(
        for request: PermissionRequest,
        onDecision: @escaping (PermissionDecision) -> Void,
        onNewSession: (() -> Void)?
    ) -> PermissionCardType {
        switch request.toolName {
        case "ExitPlanMode":
            .exitPlanMode(ExitPlanModeCardViewModel(
                request: request, onDecision: onDecision, onNewSession: onNewSession))
        case "AskUserQuestion":
            .askUserQuestion(AskUserQuestionCardViewModel(
                request: request, onDecision: onDecision))
        default:
            .standard(StandardCardViewModel(
                request: request, onDecision: onDecision))
        }
    }
}
