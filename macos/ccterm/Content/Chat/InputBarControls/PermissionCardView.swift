import AgentSDK
import SwiftUI

/// Floating decision card shown above the input bar when the CLI is
/// waiting on a permission request. Mount as
/// `.overlay(alignment: .bottom)` on `InputBarChrome`:
///
/// - Bottom edge sits flush with the chrome row (permission mode /
///   model+effort), so the card visually extends *up* from there.
/// - Width inherits the chrome wrapper's frame — same span as the
///   attach button + pill of `InputBarView2`.
/// - Z-order is above the input bar; the bar surface fades through
///   the card's material as the card expands upward.
///
/// Pure UI: the card receives a `PermissionRequest` plus three
/// decision callbacks and renders the body. Wiring through to
/// `session.respond(...)` lives in `InputBarChrome` — keeping this
/// view free of session state so it stays snapshot-friendly.
///
/// The body shape varies per category — see `PermissionCardKind`.
/// Each kind owns a small sibling view next to this file (e.g.
/// `PermissionShellCardBody`); the parent renders the shared
/// chrome (header / decision reason / buttons) and delegates the
/// middle section to the per-kind body.
struct PermissionCardView: View {
    let request: PermissionRequest
    let onAllowOnce: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void

    /// Matches `InputBarView2.cornerRadius` so the card visually
    /// belongs to the same surface family as the pill.
    static let cornerRadius: CGFloat = 16

    private var kind: PermissionCardKind { PermissionCardKind.kind(for: request) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            body(for: kind)
            if let reason = request.decisionReason?.reason, !reason.isEmpty {
                Label {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            buttonRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .barSurface(cornerRadius: Self.cornerRadius)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
            Text(PermissionCardCopy.title(for: request))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func body(for kind: PermissionCardKind) -> some View {
        switch kind {
        case .bash, .powerShell, .sedEdit:
            // sed-in-Bash falls through to the shell body until a
            // dedicated sed parser lands — the user still sees the
            // exact command. Once a sed → DiffBlock pipeline exists
            // this case moves to PermissionFileWriteCardBody.
            PermissionShellCardBody(request: request, kind: kind)
        case .fileEdit, .fileWrite:
            PermissionFileWriteCardBody(request: request, kind: kind)
        case .notebookEdit:
            PermissionNotebookEditCardBody(request: request)
        case .webFetch:
            PermissionWebFetchCardBody(request: request)
        case .filesystemRead:
            PermissionFilesystemReadCardBody(request: request)
        case .taskAgent:
            PermissionTaskAgentCardBody(request: request)
        case .skill:
            PermissionSkillCardBody(request: request)
        default:
            PermissionFallbackCardBody(request: request)
        }
    }

    @ViewBuilder
    private var buttonRow: some View {
        HStack(spacing: 8) {
            PermissionDecisionButton(
                title: String(localized: "Deny"),
                role: .destructive,
                action: onDeny)
            Spacer(minLength: 0)
            PermissionDecisionButton(
                title: String(localized: "Allow once"),
                role: .secondary,
                action: onAllowOnce)
            PermissionDecisionButton(
                title: String(localized: "Allow always"),
                role: .primary,
                action: onAllowAlways)
        }
    }
}

// MARK: - Copy helpers

/// Centralises the user-facing strings derived from a
/// `PermissionRequest`. Lives next to the view (not on `AgentSDK`)
/// because the localized copy is product-shape, not SDK-shape.
enum PermissionCardCopy {

    /// One-line headline. Falls back to a generic verb when the tool
    /// isn't in the curated list.
    static func title(for request: PermissionRequest) -> String {
        let verb = toolVerb(request.toolName, kind: PermissionCardKind.kind(for: request))
        return String(localized: "Claude wants to \(verb)")
    }

    /// The most informative single field from `rawInput`, in the
    /// order Anthropic's CLI prefers for its own preview text.
    /// Consumed by `PermissionFallbackCardBody` for kinds without a
    /// dedicated renderer.
    static func parameter(for request: PermissionRequest) -> String? {
        let candidates = ["command", "file_path", "path", "pattern", "url"]
        for key in candidates {
            if let v = request.rawInput[key] as? String, !v.isEmpty {
                return v
            }
        }
        return nil
    }

    private static func toolVerb(_ name: String, kind: PermissionCardKind) -> String {
        switch kind {
        case .bash: return String(localized: "run a shell command")
        case .powerShell: return String(localized: "run a PowerShell command")
        case .sedEdit, .fileEdit: return String(localized: "edit a file")
        case .fileWrite: return String(localized: "write a file")
        case .notebookEdit: return String(localized: "edit a notebook")
        case .filesystemRead:
            switch name {
            case "Glob": return String(localized: "search for files")
            case "Grep": return String(localized: "search file contents")
            default: return String(localized: "read a file")
            }
        case .webFetch: return String(localized: "fetch a web page")
        case .enterPlanMode: return String(localized: "enter plan mode")
        case .exitPlanMode: return String(localized: "exit plan mode")
        case .taskAgent: return String(localized: "run a sub-task")
        case .skill: return String(localized: "run a skill")
        case .askUserQuestion: return String(localized: "ask you a question")
        case .mcp: return String(localized: "use \(name)")
        case .unknown: return String(localized: "use \(name)")
        }
    }
}

// MARK: - Fallback body

/// Generic one-liner body used until each kind ships its own
/// dedicated renderer. Same shape as before this file was split.
private struct PermissionFallbackCardBody: View {
    let request: PermissionRequest

    var body: some View {
        if let detail = PermissionCardCopy.parameter(for: request) {
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Button

/// Compact decision button — 24pt tall, 8pt radius, three visual
/// weights (primary / secondary / destructive). Hover lifts the fill
/// by 8% so the affordance reads on top of `.barSurface` material.
private struct PermissionDecisionButton: View {
    enum Role {
        case primary, secondary, destructive
    }

    let title: String
    let role: Role
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(background)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(stroke, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.linear(duration: 0.1), value: hovering)
    }

    private var foreground: Color {
        switch role {
        case .primary: return .white
        case .secondary: return .primary
        case .destructive: return .red
        }
    }

    private var background: Color {
        switch role {
        case .primary:
            return hovering ? Color.accentColor.opacity(0.92) : Color.accentColor
        case .secondary:
            return hovering ? Color.primary.opacity(0.10) : Color.primary.opacity(0.04)
        case .destructive:
            return hovering ? Color.red.opacity(0.16) : Color.red.opacity(0.08)
        }
    }

    private var stroke: Color {
        switch role {
        case .primary: return .clear
        case .secondary: return Color(nsColor: .separatorColor)
        case .destructive: return Color.red.opacity(0.4)
        }
    }
}
