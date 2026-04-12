#if DEBUG
import SwiftUI
import AgentSDK

/// Debug view to verify that NativeBashView / NativeDiffView correctly hug their content.
struct ScrollHugTestView: View {
    @State private var selected = 0

    private let cases: [(String, [PermissionCardItem])] = [
        ("Short Bash", [makeCard(id: "bash-short", toolName: "Bash", input: [
            "command": "ls -la",
            "description": "List files",
        ])]),
        ("Long Bash", [makeCard(id: "bash-long", toolName: "Bash", input: [
            "command": (1...40).map { "echo \"line \($0): doing some work here\"" }.joined(separator: " && "),
            "description": "Run many echo commands",
        ])]),
        ("Short Diff", [makeCard(id: "diff-short", toolName: "Edit", input: [
            "file_path": "src/config.swift",
            "old_string": "let timeout = 3000",
            "new_string": "let timeout = 5000",
        ])]),
        ("Long Diff", [makeCard(id: "diff-long", toolName: "Edit", input: [
            "file_path": "src/api.swift",
            "old_string": (1...30).map { "let config\($0) = \($0)" }.joined(separator: "\n"),
            "new_string": (1...30).map { "let config\($0) = \($0 * 10)" }.joined(separator: "\n"),
        ])]),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Picker("Case", selection: $selected) {
                ForEach(0..<cases.count, id: \.self) { i in
                    Text(cases[i].0).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            ScrollHugCardPreview(cards: cases[selected].1)
                .id(cases[selected].0)
                .frame(maxWidth: 600)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Card Preview (standalone, no InputBarView dependency)

private struct ScrollHugCardPreview: View {
    let cards: [PermissionCardItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(cards) { card in
                cardView(for: card)
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

// MARK: - Card Factory

private func makeCard(id: String, toolName: String, input: [String: Any]) -> PermissionCardItem {
    let request = PermissionRequest.makePreview(requestId: id, toolName: toolName, input: input)
    let vm = StandardCardViewModel(request: request, onDecision: { _ in })
    return PermissionCardItem(id: id, cardType: .standard(vm))
}

#endif
