import AgentSDK
import SwiftUI

/// Body for `.bash` and `.powerShell` permission requests. Mirrors
/// the upstream `BashPermissionRequest` shape: full command rendered
/// in a code-block card (the same `DiffView` chrome the file-write
/// body uses for its diff preview, in `isNewFile` mode so there is no
/// `+`/`-` chrome — gives the command the same gutter / syntax
/// highlight treatment as a file body), `description` rendered dim
/// below, and a compact "compound command" hint when the CLI flagged
/// the request as having per-subcommand rules.
///
/// The DiffView is wrapped in `BoundedHeightScrollView` so a short
/// command sizes to its intrinsic height and a runaway heredoc caps
/// at `commandMaxHeight` and scrolls — buttons always stay reachable.
///
/// Sandboxing / classifier / destructive-warning surfacing from the
/// upstream are intentionally deferred — the CLI doesn't ship those
/// fields through `PermissionRequest` today and we can layer them in
/// when the SDK grows the structured channel.
struct PermissionShellCardBody: View {
    let request: PermissionRequest
    let kind: PermissionCardKind

    /// Maximum visible height for the embedded command `DiffView`. The
    /// command typically renders in a few lines; the cap is generous
    /// enough to surface a typical multi-line heredoc without scroll,
    /// and short enough that the decision buttons stay on-screen even
    /// in a narrow window.
    static let commandMaxHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BoundedHeightScrollView(maxHeight: Self.commandMaxHeight) {
                DiffView(diff: commandDiffBlock)
            }
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

    /// `DiffBlock` wrapper around the command so `DiffView` can render
    /// it as a code block with gutter line numbers + bash syntax
    /// highlighting. `oldString == nil` puts `DiffLayout` into
    /// `isNewFile` mode — no `+` sign column, no add-tinted background;
    /// the body reads as "a code listing" rather than "a diff that is
    /// all additions". `filePath` extension picks the highlight.js
    /// language (`.sh` → `bash`, `.ps1` → no entry, falls through to
    /// no highlighting — same shape as a plain monospaced block).
    var commandDiffBlock: DiffBlock {
        let displayed = command.isEmpty ? "—" : command
        // Drop the trailing newline (if any) so the diff doesn't render
        // a blank pseudo-line under the last real line.
        let trimmed = displayed.hasSuffix("\n") ? String(displayed.dropLast()) : displayed
        return DiffBlock(
            filePath: commandSyntheticPath,
            oldString: nil,
            newString: trimmed)
    }

    /// Synthetic file path consumed by `LanguageDetection.language(for:)`
    /// — the extension is the only thing that matters; the basename is
    /// arbitrary. `command.sh` resolves to highlight.js's `bash` lexer
    /// which already covers Bash and Zsh; `command.ps1` has no
    /// highlight.js mapping in our `extToLang` table so PowerShell
    /// falls through to plain text (acceptable; tokens would just be
    /// `nil` and the renderer omits coloring).
    private var commandSyntheticPath: String {
        switch kind {
        case .powerShell: return "command.ps1"
        default: return "command.sh"
        }
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
