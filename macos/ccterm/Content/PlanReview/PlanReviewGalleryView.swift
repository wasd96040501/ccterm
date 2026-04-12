#if DEBUG
import SwiftUI
import AgentSDK

/// Debug gallery that renders the full plan review experience.
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

            Text("Plan Review Gallery — requires running app to test")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

### Phase 2: UI Modernization
- Replace current card-based UI with a unified permission sheet
- Add search and filter to the permission history view

### Phase 3: Security Hardening
- Add rate limiting for permission requests
- Implement permission scoping by directory and file pattern

### Phase 4: Developer Experience
- Add permission simulation mode for testing
- Create permission rule debugger

### Migration Strategy
1. Ship new engine behind feature flag
2. Dual-write decisions to old and new systems
3. Validate parity for 2 weeks
4. Switch reads to new system
5. Remove old code paths
"""

#endif
