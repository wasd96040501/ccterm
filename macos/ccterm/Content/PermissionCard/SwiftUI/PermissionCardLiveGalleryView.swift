#if DEBUG
import SwiftUI
import AgentSDK

/// Debug gallery that tests ExitPlanMode permission cards in the exact same layout as ChatView.
struct PermissionCardLiveGalleryView: View {

    @State private var selectedScenario = 0

    private let scenarios: [(String, String)] = [
        ("Plan — Short", shortLivePlan),
        ("Plan — Long", longLivePlan),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Scenario", selection: $selectedScenario) {
                ForEach(scenarios.indices, id: \.self) { i in
                    Text(scenarios[i].0).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            ZStack(alignment: .bottom) {
                Color(nsColor: .windowBackgroundColor)

                LiveInputBarPreview(plan: scenarios[selectedScenario].1)
                    .id(selectedScenario)
                    .frame(maxWidth: 860)
                    .padding(.top, 32)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
    }
}

private struct LiveInputBarPreview: View {
    @State private var state: ChatSessionViewModel
    private let plan: String

    init(plan: String) {
        self.plan = plan
        _state = State(initialValue: ChatSessionViewModel.newConversation(onRouterAction: { _ in }))
    }

    var body: some View {
        SwiftUIChatInputBar(state: state, actions: ChatInputBarActions())
            .onAppear {
                let id = "live-plan-\(plan.hashValue)"
                let request = PermissionRequest.makePreview(
                    requestId: id,
                    toolName: "ExitPlanMode",
                    input: ["plan": plan]
                )
                let vm = ExitPlanModeCardViewModel(request: request, onDecision: { _ in }, onNewSession: nil)
                vm.onViewPlan = { [weak state] in
                    state?.enterPlanView(permissionId: id)
                }
                vm.onExecute = { [weak state] mode in
                    state?.executePlan(mode: mode)
                }
                state.permissionCards = [PermissionCardItem(id: id, cardType: .exitPlanMode(vm))]
            }
    }
}

private let shortLivePlan = """
## Implementation Plan

1. **Add `WebViewContainer` class** — Override `intrinsicContentSize`
2. **Update `ReactWebView.makeNSView`** — Use `WebViewContainer`
3. **Simplify Coordinator** — Replace constraint with container reference
"""

private let longLivePlan = """
## Architecture Redesign: Permission System v2

### Phase 1: Data Layer Refactoring
- Extract `PermissionRule` protocol
- Create `PermissionRuleEngine`
- Add persistent storage for rules
- Migrate existing logic to rule-based system

### Phase 2: UI Modernization
- Unified permission sheet
- Search and filter in history
- Batch approve/deny
- Session-scoped permissions
"""

#endif
