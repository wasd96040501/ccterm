import SwiftUI

// MARK: - Entry

/// One visual row in the transcript — a user bubble, a block of assistant
/// markdown, or an opaque tool block.
///
/// The `tool` case stores an `AnyView` so the transcript stays agnostic to
/// whichever tool renderer the caller picks. Real integration wraps
/// `ToolBlockView`; previews pass concrete `*Block` views directly.
enum ChatTranscriptEntry: Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, text: String)
    case tool(id: String, view: AnyView)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _), .tool(let id, _):
            return id
        }
    }
}

// MARK: - View

/// Native SwiftUI chat transcript — a read-only, top-to-bottom stream of
/// user, assistant, and tool entries. Pure presentation: the caller owns the
/// entry list and decides how SDK messages map to entries.
struct ChatTranscriptView: View {
    let entries: [ChatTranscriptEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(for entry: ChatTranscriptEntry) -> some View {
        switch entry {
        case .user(_, let text):
            HStack(spacing: 0) {
                Spacer(minLength: 60)
                UserBubble(text: text)
            }
        case .assistant(_, let text):
            MarkdownView(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(_, let view):
            view
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - User bubble

private struct UserBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
            )
            .foregroundStyle(.primary)
    }
}

// MARK: - Previews

#Preview("Mixed transcript") {
    ChatTranscriptView(entries: [
        .user(id: "u1", text: "Can you list the files in /usr/local/bin and then bump the timeout in config.swift?"),
        .assistant(id: "a1", text: "Sure — I'll **list the directory** first, then patch the config."),
        .tool(id: "t1", view: AnyView(
            BashBlock(
                command: "ls -la /usr/local/bin",
                stdout: "total 128\ndrwxr-xr-x  brew  staff  4096 Apr 18 10:30 .\ndrwxr-xr-x  root  wheel  4096 Apr 18 10:30 ..\n-rwxr-xr-x  brew  staff  2048 Apr 17 08:12 bun\n-rwxr-xr-x  brew  staff  1024 Apr 17 08:12 fzf",
                stderr: nil,
                status: .idle)
        )),
        .assistant(id: "a2", text: "Found 4 entries. Now editing **src/config.swift**:"),
        .tool(id: "t2", view: AnyView(
            FileEditBlock(
                filePath: "src/config.swift",
                oldString: "let timeout = 3000",
                newString: "let timeout = 5000",
                status: .idle)
        )),
        .assistant(id: "a3", text: "Done. The diff above shows the timeout going from `3000` to `5000` ms.\n\n- Listed the directory\n- Patched the constant\n- No other callers to update"),
        .user(id: "u2", text: "Thanks!"),
    ])
    .frame(width: 720, height: 620)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Assistant only — long markdown") {
    ChatTranscriptView(entries: [
        .assistant(id: "a1", text: """
        ## Plan

        Here is the approach:

        1. Read the existing file
        2. Apply a small edit
        3. Run the tests

        ```swift
        func greet(_ name: String) -> String {
            return "Hello, \\(name)!"
        }
        ```

        > Note: this is a quick prototype — we'll harden it later.
        """),
    ])
    .frame(width: 640, height: 500)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("User only") {
    ChatTranscriptView(entries: [
        .user(id: "u1", text: "Hi"),
        .user(id: "u2", text: "Just checking that short bubbles hug their text and don't stretch to fill the row."),
        .user(id: "u3", text: "And that a much longer message also wraps cleanly without running into the left edge of the scroll view — the bubble should keep a comfortable gutter on the left while the right edge stays aligned with the content area."),
    ])
    .frame(width: 640, height: 360)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Empty") {
    ChatTranscriptView(entries: [])
        .frame(width: 480, height: 240)
}
