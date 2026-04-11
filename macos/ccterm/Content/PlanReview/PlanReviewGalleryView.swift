#if DEBUG
import SwiftUI
import AgentSDK

/// Debug gallery that renders the full plan review experience:
/// real InputBarView in comment mode + plan WebView + toolbar.
struct PlanReviewGalleryView: View {

    @State private var selectedScenario = 0

    private let scenarios: [(String, String)] = [
        ("Short Plan", shortGalleryPlan),
        ("Long Plan", longGalleryPlan),
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

            PlanReviewPreview(plan: scenarios[selectedScenario].1)
                .id(selectedScenario)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Preview Wrapper

private struct PlanReviewPreview: View {
    let plan: String

    @State private var viewModel: InputBarViewModel
    @State private var loader = PlanWebViewLoader()
    @State private var inputBarHeight: CGFloat = 0

    init(plan: String) {
        self.plan = plan
        _viewModel = State(initialValue: InputBarViewModel.newConversation(onRouterAction: { _ in }))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Plan WebView (fullscreen)
            if viewModel.planReviewVM.isActive {
                WebViewRepresentable(webView: loader.webView)
                    .ignoresSafeArea(edges: .top)
                    .padding(.bottom, inputBarHeight)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading plan WebView...")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Real InputBar in comment mode
            InputBarView(viewModel: viewModel)
                .frame(minWidth: 400, idealWidth: 860, maxWidth: 860)
                .padding(.top, 32)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: GalleryInputBarHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(GalleryInputBarHeightKey.self) { height in
            inputBarHeight = height
        }
        .toolbar {
            PlanToolbarContent(viewModel: viewModel.planReviewVM)
        }
        .onAppear {
            setupMockPlanState()
        }
    }

    private func setupMockPlanState() {
        // Inject singleton loader into viewModel so enterPlanView/search work
        viewModel.planWebViewLoader = loader
        viewModel.planReviewVM.planWebViewLoader = loader
        viewModel.permissionVM.planWebViewLoader = loader
        loader.onTextSelected = { [weak viewModel = viewModel] range in
            viewModel?.planReviewVM.pendingCommentSelections.append(range)
        }
        loader.onSelectionCleared = { [weak viewModel = viewModel] in
            viewModel?.planReviewVM.pendingCommentSelections.removeAll()
        }
        loader.onSearchResult = { [weak viewModel = viewModel] total, current in
            viewModel?.planReviewVM.searchTotal = total
            viewModel?.planReviewVM.searchCurrent = current
        }

        let cardId = "gallery-plan-\(plan.hashValue)"
        let request = PermissionRequest.makePreview(
            requestId: cardId,
            toolName: "ExitPlanMode",
            input: ["plan": plan]
        )
        let vm = ExitPlanModeCardViewModel(
            request: request,
            onDecision: { decision in
                appLog(.debug, "PlanGallery", "Decision: \(decision)")
            },
            onNewSession: {
                appLog(.debug, "PlanGallery", "New session requested")
            }
        )

        // Bind onViewPlan to enter plan fullscreen
        vm.onViewPlan = { [weak viewModel = viewModel] in
            viewModel?.planReviewVM.enter(permissionId: cardId)
        }
        vm.onExecute = { [weak viewModel = viewModel] mode in
            viewModel?.planReviewVM.executePlan(mode: mode)
        }

        // Push plan to loader
        if let md = vm.planMarkdown, !md.isEmpty {
            loader.setPlan(key: cardId, markdown: md)
        }

        let card = PermissionCardItem(id: cardId, cardType: .exitPlanMode(vm))
        viewModel.permissionVM.cards = [card]

        // Immediately enter plan viewing mode
        viewModel.planReviewVM.enter(permissionId: cardId)
    }
}

// MARK: - Preference Key

private struct GalleryInputBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Mock Plans

private let shortGalleryPlan = """
## Implementation Plan

1. **Add `WebViewContainer` class** — Override `intrinsicContentSize` to report JS-measured height
2. **Update `ReactWebView.makeNSView`** — Use `WebViewContainer` instead of plain `NSView`
3. **Simplify Coordinator** — Replace `heightConstraint` with direct `container` reference

### Changes
- `ccterm/Content/AutoSizingWebView.swift` — New container class
- `ccterm/Content/Chat/ChatView.swift` — Updated layout
"""

private let longGalleryPlan = """
## Architecture Redesign: Permission System v2

### Phase 1: Data Layer Refactoring
- Extract `PermissionRule` protocol from current inline logic
- Create `PermissionRuleEngine` that evaluates rules in priority order
- Add persistent storage for user-defined always-allow rules
- Migrate existing `allowOnce` / `allowAlways` to rule-based system

### Phase 2: UI Modernization
- Replace current card-based UI with a unified permission sheet
- Add search and filter to the permission history view
- Implement batch approve/deny for multiple pending permissions
- Add "remember for this session" option alongside always/once

### Phase 3: Security Hardening
- Add rate limiting for permission requests (prevent permission fatigue attacks)
- Implement permission scoping by directory and file pattern
- Add audit log for all permission decisions with timestamps
- Create admin-level override rules via managed settings

### Phase 4: Developer Experience
- Add permission simulation mode for testing
- Create permission rule debugger showing which rule matched
- Implement permission telemetry dashboard
- Add CI integration for permission policy testing

### Migration Strategy
1. Ship new engine behind feature flag
2. Dual-write decisions to old and new systems
3. Validate parity for 2 weeks
4. Switch reads to new system
5. Remove old code paths
"""

#endif
