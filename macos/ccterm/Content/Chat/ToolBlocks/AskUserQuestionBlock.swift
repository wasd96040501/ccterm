import SwiftUI

/// Tool block for the `AskUserQuestion` tool — header is caller-supplied;
/// body lists each question along with the user's answer (when available).
struct AskUserQuestionBlock: View {
    let title: String
    let items: [QAItem]
    let status: ToolBlockStatus

    @State private var isExpanded = false

    struct QAItem: Identifiable {
        let id = UUID()
        let question: String
        let answer: String?
    }

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: !items.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    QARow(item: item)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            Label(title, systemImage: "questionmark.bubble")
        }
    }
}

// MARK: - Subviews

private struct QARow: View {
    let item: AskUserQuestionBlock.QAItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.question)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if let answer = item.answer, !answer.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(answer)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("awaiting answer…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview("Answered") {
    AskUserQuestionBlock(
        title: "Asked: question",
        items: [
            .init(
                question: "Which framework should we use for navigation?",
                answer: "NavigationSplitView"),
            .init(
                question: "Should the sidebar be collapsible by default?",
                answer: "Yes"),
        ],
        status: .idle
    )
    .padding()
    .frame(width: 560, height: 240, alignment: .topLeading)
}

#Preview("Awaiting answer — running") {
    AskUserQuestionBlock(
        title: "Asked: question",
        items: [
            .init(question: "Would you like to continue?", answer: nil)
        ],
        status: .running
    )
    .padding()
    .frame(width: 560, height: 240, alignment: .topLeading)
}

#Preview("Error") {
    AskUserQuestionBlock(
        title: "Asked: question",
        items: [
            .init(question: "Pick an option", answer: nil)
        ],
        status: .error("user declined to answer")
    )
    .padding()
    .frame(width: 560, height: 240, alignment: .topLeading)
}
