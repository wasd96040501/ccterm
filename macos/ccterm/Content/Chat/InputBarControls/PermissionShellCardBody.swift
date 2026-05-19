import AgentSDK
import SwiftUI

/// Body for `.bash` and `.powerShell` permission requests. Mirrors
/// the upstream `BashPermissionRequest` shape: full command rendered
/// monospaced (multi-line preserved), `description` rendered dim
/// below, and a compact "compound command" hint when the CLI flagged
/// the request as having per-subcommand rules.
///
/// Sandboxing / classifier / destructive-warning surfacing from the
/// upstream are intentionally deferred — the CLI doesn't ship those
/// fields through `PermissionRequest` today and we can layer them in
/// when the SDK grows the structured channel.
struct PermissionShellCardBody: View {
    let request: PermissionRequest
    let kind: PermissionCardKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            commandView
            if let description = description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let hint = compoundHint {
                Label {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pure derivations from `request`. Marked `internal` (not
    /// `private`) so logic tests can assert on the same inputs the
    /// view's body reads — see `PermissionShellCardBodyTests`. No
    /// state lives here; the view is a function of these getters.
    var command: String {
        (request.rawInput["command"] as? String) ?? ""
    }

    var description: String? {
        request.rawInput["description"] as? String
    }

    /// True when the CLI's decision reason says the rules were
    /// computed per-subcommand. Same signal the upstream Bash dialog
    /// reads to seed the "yes, apply suggestions" branch.
    var isCompoundCommand: Bool {
        guard case .structured(let type, _) = request.decisionReason else { return false }
        return type == "subcommandResults"
    }

    /// Count of bash rules in the request's suggestion bundle — what
    /// "Allow always" would install. We surface only the count, not
    /// the rule text, since long compound runs accumulate dozens.
    var bashRuleCount: Int {
        guard let suggestions = request.permissionSuggestions else { return 0 }
        return suggestions.reduce(0) { acc, suggestion in
            if case .addRules(let s) = suggestion {
                return acc + s.rules.filter { $0.toolName == "Bash" || $0.toolName == "PowerShell" }.count
            }
            return acc
        }
    }

    var compoundHint: String? {
        guard isCompoundCommand else { return nil }
        let n = bashRuleCount
        if n <= 1 { return nil }
        return String(
            localized: "Compound command — \"Allow always\" will save \(n) rules")
    }

    @ViewBuilder
    private var commandView: some View {
        // `.lineLimit(6)` lets multi-line heredocs / `&& \`-continued
        // commands stay readable without letting a runaway shell
        // script push the buttons off-screen. The text is selectable
        // so users can copy a long command into a terminal to inspect.
        Text(command.isEmpty ? "—" : command)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(6)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Bash · simple") {
    PermissionShellCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-1",
            toolName: "Bash",
            input: [
                "command": "rm -rf node_modules",
                "description": "Reset deps",
            ]),
        kind: .bash
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Bash · multi-line heredoc") {
    PermissionShellCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-2",
            toolName: "Bash",
            input: [
                "command":
                    "git commit -m \"$(cat <<'EOF'\nfeat: add preview\n\nLong body explaining the change in detail.\nEOF\n)\"",
                "description": "Commit current changes",
            ]),
        kind: .bash
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("PowerShell") {
    PermissionShellCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-3",
            toolName: "PowerShell",
            input: [
                "command": "Get-ChildItem -Recurse -Filter *.swift | Measure-Object",
                "description": "Count Swift files",
            ]),
        kind: .powerShell
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}
