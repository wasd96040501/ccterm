import SwiftUI

/// Tool block for the `Bash` tool — header reads `Bash <intent>`; body
/// shows the actual command + merged stdout / stderr.
struct BashBlock: View {
    let command: String
    /// Short natural-language intent from `v.input.description`. When
    /// present the header uses it; otherwise the header falls back to the
    /// command itself (truncated).
    let description: String?
    let stdout: String?
    let stderr: String?
    let status: ToolBlockStatus

    @State private var isExpanded = false

    var body: some View {
        ToolBlock(
            status: status,
            isExpanded: $isExpanded,
            hasExpandableContent: !command.isEmpty
                || stdout?.isEmpty == false
                || stderr?.isEmpty == false
        ) {
            VStack(alignment: .leading, spacing: 8) {
                NativeBashView(command: command, maxHeight: 260)
                if let stdout, !stdout.isEmpty {
                    OutputView(text: stdout, isStderr: false)
                }
                if let stderr, !stderr.isEmpty {
                    OutputView(text: stderr, isStderr: true)
                }
            }
        } label: {
            Label("Bash \(intent)", systemImage: "terminal")
        }
    }

    private var intent: String {
        if let description, !description.isEmpty { return description }
        let collapsed = command.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }
}

// MARK: - Output view

private struct OutputView: View {
    let text: String
    let isStderr: Bool

    var body: some View {
        ScrollView([.vertical]) {
            Text(cleaned)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isStderr ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 240)
        .toolBlockSecondarySectionStyle()
    }

    private var cleaned: String {
        text.replacingOccurrences(
            of: "\\x1b\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression)
    }
}

// MARK: - Previews

#Preview("Idle — simple") {
    BashBlock(
        command: "ls -la /usr/local/bin",
        description: nil,
        stdout: "total 128\ndrwxr-xr-x  brew  staff  4096 Apr 18 10:30 .\ndrwxr-xr-x  root  wheel  4096 Apr 18 10:30 ..",
        stderr: nil,
        status: .idle
    )
    .padding()
    .frame(width: 520, height: 260, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Running") {
    BashBlock(
        command: "make build",
        description: nil,
        stdout: nil,
        stderr: nil,
        status: .running
    )
    .padding()
    .frame(width: 520, height: 260, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Error — non-zero exit") {
    BashBlock(
        command: "cat /nonexistent/file.txt",
        description: nil,
        stdout: nil,
        stderr: "cat: /nonexistent/file.txt: No such file or directory",
        status: .error("Command failed with exit code 1")
    )
    .padding()
    .frame(width: 520, height: 260, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Long command truncated") {
    BashBlock(
        command: "find /usr/local -name '*.dylib' -type f -exec ls -la {} \\; | sort -k5 -n -r | head -20",
        description: nil,
        stdout: "lrwxr-xr-x  1 admin  wheel  1234 Apr  4 12:00 libfoo.dylib\n...",
        stderr: nil,
        status: .idle
    )
    .padding()
    .frame(width: 520, height: 260, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Mixed stdout + stderr") {
    BashBlock(
        command: "npm test",
        description: nil,
        stdout: "> project@1.0.0 test\n> jest\n\nPASS  src/foo.test.ts\nPASS  src/bar.test.ts",
        stderr: "npm WARN deprecated package@1.0.0: use newer version",
        status: .idle
    )
    .padding()
    .frame(width: 520, height: 260, alignment: .topLeading)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
