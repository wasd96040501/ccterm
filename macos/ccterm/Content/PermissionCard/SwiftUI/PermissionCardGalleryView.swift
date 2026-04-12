#if DEBUG
import SwiftUI
import AgentSDK

/// Debug-only gallery for visually testing all permission card variants.
struct PermissionCardGalleryView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Permission Card Gallery")
                    .font(.title2.bold())

                // MARK: - Bash Cards

                gallerySection("Bash — Short Command") {
                    CardPreview(cards: [
                        makeStandardCard(id: "bash-short", toolName: "Bash", input: [
                            "command": "ls -la",
                            "description": "List files",
                        ]),
                    ])
                }

                gallerySection("Bash — Medium Command") {
                    CardPreview(cards: [
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
                    CardPreview(cards: [
                        makeStandardCard(id: "bash-long", toolName: "Bash", input: [
                            "command": longBashScript,
                            "description": "Full CI pipeline",
                        ]),
                    ])
                }

                // MARK: - Diff / Write Cards

                gallerySection("Edit — Short Diff") {
                    CardPreview(cards: [
                        makeStandardCard(id: "edit-short", toolName: "Edit", input: [
                            "file_path": "src/utils.ts",
                            "old_string": "const timeout = 3000;",
                            "new_string": "const timeout = 5000;",
                        ]),
                    ])
                }

                // MARK: - Plan Card

                gallerySection("ExitPlanMode — Short Plan") {
                    CardPreview(cards: [
                        makeExitPlanCard(id: "plan-short", plan: shortPlan),
                    ])
                }

                // MARK: - AskUserQuestion

                gallerySection("AskUserQuestion — Single Question") {
                    CardPreview(cards: [
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

                // MARK: - Multiple Cards

                gallerySection("Multiple Cards — With Page Dots") {
                    CardPreview(cards: [
                        makeStandardCard(id: "multi-1", toolName: "Bash", input: [
                            "command": "rm -rf /tmp/cache",
                            "description": "Clean cache",
                        ]),
                        makeStandardCard(id: "multi-2", toolName: "Edit", input: [
                            "file_path": "src/config.ts",
                            "old_string": "debug: true",
                            "new_string": "debug: false",
                        ]),
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

// MARK: - Card Preview Wrapper (standalone, no InputBarView)

private struct CardPreview: View {
    let cards: [PermissionCardItem]
    @State private var currentIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if cards.count > 1 {
                PageDotIndicatorSwiftUIView(count: cards.count, currentIndex: $currentIndex)
                    .frame(height: 16)
                    .padding(.top, 2)
            }
            if let card = cards[safe: currentIndex] {
                cardView(for: card)
                    .id(card.id)
            }
        }
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func cardView(for card: PermissionCardItem) -> some View {
        switch card.cardType {
        case .standard(let vm): StandardCardView(viewModel: vm)
        case .exitPlanMode(let vm): ExitPlanModeCardView(viewModel: vm)
        case .askUserQuestion(let vm): SwiftUIAskUserQuestionCardView(viewModel: vm)
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
"""

private let shortPlan = """
## Implementation Plan

1. **Add `WebViewContainer` class** — Override `intrinsicContentSize` to report JS-measured height
2. **Update `ReactWebView.makeNSView`** — Use `WebViewContainer` instead of plain `NSView`
3. **Simplify Coordinator** — Replace `heightConstraint` with direct `container` reference
"""

#endif
