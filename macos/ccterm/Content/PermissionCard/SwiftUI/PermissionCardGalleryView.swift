#if DEBUG
import SwiftUI
import AgentSDK

/// Debug-only gallery for visually testing all permission card variants inside the real InputBar.
struct PermissionCardGalleryView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Permission Card Gallery")
                    .font(.title2.bold())

                // MARK: - Bash Cards

                gallerySection("Bash — Short Command") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "bash-short", toolName: "Bash", input: [
                            "command": "ls -la",
                            "description": "List files",
                        ]),
                    ])
                }

                gallerySection("Bash — Medium Command") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "bash-med", toolName: "Bash", input: [
                            "command": """
                            cd /Volumes/largedisk/code/ccterm && \\
                            swift build 2>&1 | tail -5 && \\
                            swift test --filter "SessionTests" 2>&1 | tail -20
                            """,
                            "description": "Build and test the project",
                        ]),
                    ])
                }

                gallerySection("Bash — Long Script (should scroll at 300pt)") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "bash-long", toolName: "Bash", input: [
                            "command": longBashScript,
                            "description": "Full CI pipeline",
                        ]),
                    ])
                }

                gallerySection("Bash — No Description") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "bash-nodesc", toolName: "Bash", input: [
                            "command": "echo 'hello world'",
                        ]),
                    ])
                }

                // MARK: - Diff / Write Cards

                gallerySection("Write — Short Content") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "write-short", toolName: "Write", input: [
                            "file_path": "src/config.ts",
                            "content": "export const API_URL = 'https://api.example.com';\n",
                        ]),
                    ])
                }

                gallerySection("Edit — Short Diff") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "edit-short", toolName: "Edit", input: [
                            "file_path": "src/utils.ts",
                            "old_string": "const timeout = 3000;",
                            "new_string": "const timeout = 5000;",
                        ]),
                    ])
                }

                gallerySection("Edit — Medium Diff") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "edit-med", toolName: "Edit", input: [
                            "file_path": "src/components/Header.tsx",
                            "old_string": mediumDiffOld,
                            "new_string": mediumDiffNew,
                        ]),
                    ])
                }

                gallerySection("Edit — Long Diff (should scroll at 300pt)") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "edit-long", toolName: "Edit", input: [
                            "file_path": "src/services/api.ts",
                            "old_string": longDiffOld,
                            "new_string": longDiffNew,
                        ]),
                    ])
                }

                // MARK: - Plan Card

                gallerySection("ExitPlanMode — Short Plan") {
                    InputBarPreview(cards: [
                        makeExitPlanCard(id: "plan-short", plan: shortPlan),
                    ])
                }

                gallerySection("ExitPlanMode — Long Plan (should scroll at 300pt)") {
                    InputBarPreview(cards: [
                        makeExitPlanCard(id: "plan-long", plan: longPlan),
                    ])
                }

                // MARK: - Non-WebView Cards

                gallerySection("Read") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "read", toolName: "Read", input: [
                            "file_path": "/Volumes/largedisk/code/ccterm/ccterm/App/AppCoordinator.swift",
                        ]),
                    ])
                }

                gallerySection("Glob") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "glob", toolName: "Glob", input: [
                            "pattern": "**/*.swift",
                            "path": "/Volumes/largedisk/code/ccterm",
                        ]),
                    ])
                }

                gallerySection("Grep") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "grep", toolName: "Grep", input: [
                            "pattern": "func handleBridgeMessage",
                            "path": "/Volumes/largedisk/code/ccterm",
                            "glob": "*.swift",
                        ]),
                    ])
                }

                gallerySection("WebFetch") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "webfetch", toolName: "WebFetch", input: [
                            "url": "https://api.example.com/v1/status",
                        ]),
                    ])
                }

                gallerySection("WebSearch") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "websearch", toolName: "WebSearch", input: [
                            "query": "SwiftUI intrinsicContentSize NSViewRepresentable",
                            "prompt": "Find documentation on how NSViewRepresentable communicates size to SwiftUI",
                        ]),
                    ])
                }

                gallerySection("Generic Tool") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "generic", toolName: "CustomTool", input: [
                            "action": "migrate-schema",
                            "target": "production",
                            "version": "2.4.1",
                        ]),
                    ])
                }

                // MARK: - AskUserQuestion

                gallerySection("AskUserQuestion — Single Question") {
                    InputBarPreview(cards: [
                        makeAskUserQuestionCard(id: "ask-single", questions: [
                            [
                                "question": "Which database migration strategy should I use?",
                                "header": "Database Setup",
                                "options": [
                                    ["label": "Incremental migration", "description": "Apply changes one at a time"],
                                    ["label": "Full rebuild", "description": "Drop and recreate all tables"],
                                ],
                            ],
                        ]),
                    ])
                }

                gallerySection("AskUserQuestion — Multiple Questions") {
                    InputBarPreview(cards: [
                        makeAskUserQuestionCard(id: "ask-multi", questions: [
                            [
                                "question": "Which testing framework?",
                                "header": "Test Configuration",
                                "options": [
                                    ["label": "XCTest"],
                                    ["label": "Swift Testing"],
                                ],
                            ],
                            [
                                "question": "Code coverage threshold?",
                                "options": [
                                    ["label": "80%", "description": "Standard"],
                                    ["label": "90%", "description": "Strict"],
                                    ["label": "None", "description": "Skip coverage checks"],
                                ],
                            ],
                        ]),
                    ])
                }

                // MARK: - Multiple Cards (page dots)

                gallerySection("Multiple Cards — With Page Dots") {
                    InputBarPreview(cards: [
                        makeStandardCard(id: "multi-1", toolName: "Bash", input: [
                            "command": "rm -rf /tmp/cache",
                            "description": "Clean cache",
                        ]),
                        makeStandardCard(id: "multi-2", toolName: "Edit", input: [
                            "file_path": "src/config.ts",
                            "old_string": "debug: true",
                            "new_string": "debug: false",
                        ]),
                        makeExitPlanCard(id: "multi-3", plan: shortPlan),
                    ])
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func gallerySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: 600)
        }
    }
}

// MARK: - InputBar Preview Wrapper

/// Wraps the real SwiftUIChatInputBar with a mock ChatSessionViewModel pre-loaded with permission cards.
private struct InputBarPreview: View {
    @State private var state: ChatSessionViewModel
    private let initialCards: [PermissionCardItem]

    init(cards: [PermissionCardItem]) {
        self.initialCards = cards
        _state = State(initialValue: ChatSessionViewModel.newConversation(onRouterAction: { _ in }))
    }

    var body: some View {
        SwiftUIChatInputBar(state: state, actions: ChatInputBarActions())
            .onAppear {
                state.permissionCards = initialCards
            }
    }
}

// MARK: - Card Factories

private func makeStandardCard(id: String, toolName: String, input: [String: Any]) -> PermissionCardItem {
    let request = PermissionRequest.makePreview(requestId: id, toolName: toolName, input: input)
    let vm = StandardCardViewModel(request: request, onDecision: { _ in })
    return PermissionCardItem(id: id, cardType: .standard(vm))
}

private func makeExitPlanCard(id: String, plan: String) -> PermissionCardItem {
    let request = PermissionRequest.makePreview(requestId: id, toolName: "ExitPlanMode", input: ["plan": plan])
    let vm = ExitPlanModeCardViewModel(request: request, onDecision: { _ in }, onNewSession: nil)
    return PermissionCardItem(id: id, cardType: .exitPlanMode(vm))
}

private func makeAskUserQuestionCard(id: String, questions: [[String: Any]]) -> PermissionCardItem {
    let request = PermissionRequest.makePreview(requestId: id, toolName: "AskUserQuestion", input: ["questions": questions])
    let vm = AskUserQuestionCardViewModel(request: request, onDecision: { _ in })
    return PermissionCardItem(id: id, cardType: .askUserQuestion(vm))
}

// MARK: - Mock Data

private let longBashScript = """
#!/bin/bash
set -euo pipefail

echo "=== Step 1: Environment Setup ==="
export NODE_ENV=production
export CI=true

echo "=== Step 2: Clean Previous Build ==="
rm -rf build/ dist/ .cache/ node_modules/.cache/
rm -rf coverage/ test-results/

echo "=== Step 3: Install Dependencies ==="
npm ci --prefer-offline --no-audit

echo "=== Step 4: Lint ==="
npx eslint src/ --ext .ts,.tsx --max-warnings 0

echo "=== Step 5: Type Check ==="
npx tsc --noEmit --pretty

echo "=== Step 6: Unit Tests ==="
npx jest --coverage --ci --maxWorkers=4

echo "=== Step 7: Build ==="
npx webpack --mode production --config webpack.prod.js

echo "=== Step 8: Integration Tests ==="
npx playwright test --reporter=html --workers=2

echo "=== Step 9: Bundle Analysis ==="
npx webpack-bundle-analyzer dist/stats.json -m static -r dist/bundle-report.html

echo "=== Step 10: Generate Docs ==="
npx typedoc --out docs/ src/index.ts

echo "=== Step 11: Package Release ==="
VERSION=$(node -p "require('./package.json').version")
tar -czf "release-${VERSION}.tar.gz" dist/ docs/

echo "=== Done ==="
echo "Release artifact: release-${VERSION}.tar.gz"
"""

private let mediumDiffOld = """
import { useState } from 'react';

export function Header({ title }: { title: string }) {
    const [isOpen, setIsOpen] = useState(false);

    return (
        <header>
            <h1>{title}</h1>
            <button onClick={() => setIsOpen(!isOpen)}>Menu</button>
        </header>
    );
}
"""

private let mediumDiffNew = """
import { useState, useCallback } from 'react';

interface HeaderProps {
    title: string;
    subtitle?: string;
    onMenuToggle?: (isOpen: boolean) => void;
}

export function Header({ title, subtitle, onMenuToggle }: HeaderProps) {
    const [isOpen, setIsOpen] = useState(false);

    const handleToggle = useCallback(() => {
        const next = !isOpen;
        setIsOpen(next);
        onMenuToggle?.(next);
    }, [isOpen, onMenuToggle]);

    return (
        <header>
            <h1>{title}</h1>
            {subtitle && <p className="subtitle">{subtitle}</p>}
            <button onClick={handleToggle}>Menu</button>
        </header>
    );
}
"""

private let longDiffOld = (1...40).map { i in
    "export const config\(i) = { name: 'item\(i)', value: \(i), enabled: true };"
}.joined(separator: "\n")

private let longDiffNew = (1...40).map { i in
    "export const config\(i) = { name: 'item\(i)', value: \(i * 10), enabled: \(i % 3 != 0), priority: \(i % 5) };"
}.joined(separator: "\n")

private let shortPlan = """
## Implementation Plan

1. **Add `WebViewContainer` class** — Override `intrinsicContentSize` to report JS-measured height
2. **Update `ReactWebView.makeNSView`** — Use `WebViewContainer` instead of plain `NSView`
3. **Simplify Coordinator** — Replace `heightConstraint` with direct `container` reference
"""

private let longPlan = """
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
