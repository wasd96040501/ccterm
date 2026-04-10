#if DEBUG
import SwiftUI
import AgentSDK

/// Debug gallery that renders the full plan review experience:
/// real SwiftUIChatInputBar in comment mode + plan WebView + toolbar.
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

/// Wraps real SwiftUIChatInputBar + PlanWebViewRepresentable to simulate
/// the full-screen plan review experience with mock data.
private struct PlanReviewPreview: View {
    let plan: String

    @State private var session: ChatSessionViewModel
    @State private var loader = PlanWebViewLoader()
    @State private var inputBarHeight: CGFloat = 0

    init(plan: String) {
        self.plan = plan
        _session = State(initialValue: ChatSessionViewModel.newConversation(onRouterAction: { _ in }))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Plan WebView (fullscreen)
            if session.isViewingPlan {
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
            SwiftUIChatInputBar(
                state: session,
                actions: ChatInputBarActions()
            )
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
            PlanToolbarContent(session: session)
        }
        .onAppear {
            setupMockPlanState()
        }
    }

    private func setupMockPlanState() {
        // Inject singleton loader into session so enterPlanView/search work
        session.planWebViewLoader = loader
        loader.onTextSelected = { [weak session = session] range in
            session?.pendingCommentSelections.append(range)
        }
        loader.onSelectionCleared = { [weak session = session] in
            session?.pendingCommentSelections.removeAll()
        }
        loader.onSearchResult = { [weak session = session] total, current in
            session?.planSearchTotal = total
            session?.planSearchCurrent = current
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
                NSLog("[PlanGallery] Decision: \(decision)")
            },
            onNewSession: {
                NSLog("[PlanGallery] New session requested")
            }
        )

        // Bind onViewPlan to enter plan fullscreen
        vm.onViewPlan = { [weak session = session] in
            session?.enterPlanView(permissionId: cardId)
        }
        vm.onExecute = { [weak session = session] mode in
            session?.executePlan(mode: mode)
        }

        // Push plan to loader
        if let md = vm.planMarkdown, !md.isEmpty {
            loader.setPlan(key: cardId, markdown: md)
        }

        let card = PermissionCardItem(id: cardId, cardType: .exitPlanMode(vm))
        session.permissionCards = [card]

        // Immediately enter plan viewing mode
        session.enterPlanView(permissionId: cardId)
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

### Code Changes

```swift
protocol PermissionRule {
    var priority: Int { get }
    func evaluate(_ request: PermissionRequest) -> PermissionDecision?
}

class PermissionRuleEngine {
    private var rules: [PermissionRule] = []

    func addRule(_ rule: PermissionRule) {
        rules.append(rule)
        rules.sort { $0.priority > $1.priority }
    }

    func evaluate(_ request: PermissionRequest) -> PermissionDecision {
        for rule in rules {
            if let decision = rule.evaluate(request) {
                return decision
            }
        }
        return .askUser
    }
}
```

### Timeline
- Phase 1: Week 1-2
- Phase 2: Week 3-4
- Phase 3: Week 5-6
- Phase 4: Week 7-8
"""

#endif
