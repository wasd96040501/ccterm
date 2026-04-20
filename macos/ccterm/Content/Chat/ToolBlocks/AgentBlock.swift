import SwiftUI

/// Tool block for the `Agent` / `Task` tool — header shows description and a
/// status summary; body shows the progress entries and final output text.
struct AgentBlock: View {
    let description: String
    let progress: [ProgressEntry]
    /// Final text output after the agent completes.
    let outputText: String?
    /// Sub-agent runtime status (separate from this block's ToolBlockStatus —
    /// useful for showing "running / completed / stopped" labels).
    let agentState: String?
    let toolUseCount: Int?
    let status: ToolBlockStatus

    @State private var isExpanded = false

    struct ProgressEntry: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: !progress.isEmpty || outputText?.isEmpty == false
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !progress.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(progress) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let outputText, !outputText.isEmpty {
                    ScrollView([.vertical]) {
                        MarkdownView(outputText)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        } label: {
            Label(labelText, systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private var labelText: String {
        var out = "Agent \(description)"
        var suffix: [String] = []
        if let agentState { suffix.append(agentState) }
        if let toolUseCount, toolUseCount > 0 { suffix.append("\(toolUseCount) tools") }
        if !suffix.isEmpty { out += "  (\(suffix.joined(separator: ", ")))" }
        return out
    }
}

// MARK: - Previews

#Preview("Running with progress") {
    AgentBlock(
        description: "Research how SwiftUI animation timing works",
        progress: [
            .init(text: "Searching documentation…"),
            .init(text: "Reading 3 articles"),
            .init(text: "Cross-referencing examples"),
        ],
        outputText: nil,
        agentState: "running",
        toolUseCount: 5,
        status: .running
    )
    .padding()
    .frame(width: 600, height: 320, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Completed with output") {
    AgentBlock(
        description: "Audit repo for TODOs",
        progress: [
            .init(text: "Grep pattern 'TODO' across repo"),
            .init(text: "Found 12 matches"),
        ],
        outputText: """
        ## Summary

        Found **12** TODO comments across 7 files:

        - `src/Foo.swift` — 4 TODOs
        - `src/Bar.swift` — 3 TODOs
        - others — 5 TODOs
        """,
        agentState: "completed",
        toolUseCount: 3,
        status: .idle
    )
    .padding()
    .frame(width: 600, height: 480, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Error") {
    AgentBlock(
        description: "Deploy to staging",
        progress: [],
        outputText: nil,
        agentState: "failed",
        toolUseCount: 0,
        status: .error("agent exceeded context window")
    )
    .padding()
    .frame(width: 600, height: 320, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Minimal") {
    AgentBlock(
        description: "Analyse changes",
        progress: [],
        outputText: nil,
        agentState: nil,
        toolUseCount: nil,
        status: .idle
    )
    .padding()
    .frame(width: 600, height: 320, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
