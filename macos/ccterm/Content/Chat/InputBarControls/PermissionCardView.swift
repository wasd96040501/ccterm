import AgentSDK
import SwiftUI

/// Floating decision card shown over the input bar when the CLI is
/// waiting on a permission request. Hosted by `PermissionCardOverlay`
/// inside `ChatSessionViewController`'s dedicated full-pane, click-through
/// `permissionCardHost` (a `PassthroughHostingView`) — NOT inside the
/// input-bar host:
///
/// - The card lives in its own full-pane overlay so its footprint never
///   pumps the bottom-anchored bar host's intrinsic height. (Earlier the
///   card was a `ZStack` child of `ChatRestingBar`; its union height grew
///   the `.intrinsicContentSize` bar host and the bar band ballooned up
///   when a card appeared.)
/// - `PermissionCardOverlay` pins the card's bottom edge with the same
///   `chatBottomInset` the bar uses, so the card sits flush with the
///   chrome row and visually extends *up* from there.
/// - The overlay is detail-pane-wide, so the card's
///   `.frame(maxWidth: BlockStyle.maxLayoutWidth)` reaches the full 780
///   (the transcript column width) instead of clipping to the bar's width.
/// - The host is layered above the bar host, and everything outside the
///   card passes clicks through to the transcript (see
///   `PassthroughHostingView`).
///
/// Pure UI: the card receives a `PermissionRequest` plus four decision
/// callbacks and renders the body. Wiring through to `session.respond(...)`
/// lives in `PermissionCardOverlay` (`decisionHandlers(for:session:)`) —
/// keeping this view free of session state so it stays snapshot-friendly.
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
    /// Receives an `updatedInput` payload for kinds that gather answers
    /// inside the body (today: `askUserQuestion`). The body composes the
    /// dict (`questions` + `answers` per the AskUserQuestion contract)
    /// and the host turns it into `request.allowOnce(updatedInput:)`.
    /// Default is a no-op so existing call sites compile unchanged.
    var onAllowWithInput: ([String: Any]?) -> Void = { _ in }

    /// Matches `InputBarView2.cornerRadius` so the card visually
    /// belongs to the same surface family as the pill.
    static let cornerRadius: CGFloat = 16

    private var kind: PermissionCardKind { PermissionCardKind.kind(for: request) }

    /// `askUserQuestion` owns its full chrome (header / questions /
    /// option rows / submit / cancel) — the generic header + reason +
    /// button row are not rendered for it.
    private var bodyOwnsChrome: Bool { kind == .askUserQuestion }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !bodyOwnsChrome { header }
            body(for: kind)
            if !bodyOwnsChrome,
                let reason = request.decisionReason?.reason, !reason.isEmpty
            {
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
            if !bodyOwnsChrome { buttonRow }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: BlockStyle.maxLayoutWidth, alignment: .leading)
        .modifier(PermissionCardSurface(cornerRadius: Self.cornerRadius))
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
        case .bash, .powerShell:
            PermissionShellCardBody(request: request, kind: kind)
        case .sedEdit:
            PermissionSedEditCardBody(request: request)
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
        case .mcp:
            PermissionMcpCardBody(request: request)
        case .enterPlanMode:
            PermissionEnterPlanModeCardBody(request: request)
        case .exitPlanMode:
            PermissionExitPlanModeCardBody(request: request)
        case .askUserQuestion:
            // The AskUserQuestion wizard is now pure AppKit
            // (`AskUserQuestionCardViewController`, migration plan §4.5). The
            // production path mounts it directly via the AppKit
            // `PermissionCardContentView`; this SwiftUI card survives only for
            // the DEBUG `PermissionCardsDemoView`, so it bridges to the same
            // AppKit VC through a representable rather than re-hosting a
            // now-deleted SwiftUI body.
            AskUserQuestionCardRepresentable(
                request: request,
                onSubmit: onAllowWithInput,
                onCancel: onDeny)
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

// MARK: - Surface

/// Opaque card surface used by the floating permission card. Mirrors
/// the rounded-rect + edge-stroke + soft-shadow chrome of
/// `BarSurfaceModifier` but drops the translucent material — the
/// permission card sits directly above the input bar and the bar's
/// material was bleeding through, which made the diff/command preview
/// hard to read. Solid `controlBackgroundColor` reads as a clear panel
/// against any window backdrop.
private struct PermissionCardSurface: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12),
                radius: 10, x: 0, y: 4)
    }
}

// MARK: - Button

/// Compact decision button — 24pt tall, 8pt radius, three visual
/// weights (primary / secondary / destructive). Hover lifts the fill
/// by 8% so the affordance reads on top of the card surface.
/// Shared across permission card body renderers (e.g.
/// `PermissionAskUserQuestionCardBody` uses it for its Deny / Confirm
/// row) so every kind's decision row reads as the same family.
struct PermissionDecisionButton: View {
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

// MARK: - AskUserQuestion bridge (DEBUG demo only)

/// Hosts the pure-AppKit `AskUserQuestionCardViewController` (migration plan
/// §4.5) inside the still-SwiftUI `PermissionCardView`, which now survives only
/// for the DEBUG `PermissionCardsDemoView`. Production mounts the wizard VC
/// directly via the AppKit `PermissionCardContentView` — there is no SwiftUI
/// AskUserQuestion body anymore.
private struct AskUserQuestionCardRepresentable: NSViewControllerRepresentable {
    let request: PermissionRequest
    let onSubmit: ([String: Any]?) -> Void
    let onCancel: () -> Void

    func makeNSViewController(context: Context) -> AskUserQuestionCardViewController {
        AskUserQuestionCardViewController(
            request: request, onSubmit: onSubmit, onCancel: onCancel)
    }

    func updateNSViewController(
        _ controller: AskUserQuestionCardViewController, context: Context
    ) {}
}

#Preview("Bash") {
    PermissionCardView(
        request: PermissionRequest.makePreview(
            requestId: "preview-1",
            toolName: "Bash",
            input: [
                "command": "git push --force origin main",
                "description": "Force-push the rebased branch",
            ]),
        onAllowOnce: {},
        onAllowAlways: {},
        onDeny: {}
    )
    .padding(16)
    .frame(width: 560)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Edit · file") {
    PermissionCardView(
        request: PermissionRequest.makePreview(
            requestId: "preview-2",
            toolName: "Edit",
            input: [
                "file_path": "/Users/example/Project/Sources/Greeter.swift",
                "old_string": "print(\"hello\")",
                "new_string": "print(\"hello, world\")",
            ]),
        onAllowOnce: {},
        onAllowAlways: {},
        onDeny: {}
    )
    .padding(16)
    .frame(width: 560)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Edit · long diff scrolls") {
    let oldText = (0..<25).map { i in
        "    case option\(i): return \"option-\(i)\""
    }.joined(separator: "\n")
    let newText = (0..<25).map { i in
        "    case option\(i): return String(localized: \"option-\(i)\")"
    }.joined(separator: "\n")
    return PermissionCardView(
        request: PermissionRequest.makePreview(
            requestId: "preview-long-diff",
            toolName: "Edit",
            input: [
                "file_path": "/Users/example/Project/Sources/Localized.swift",
                "old_string": oldText,
                "new_string": newText,
            ]),
        onAllowOnce: {},
        onAllowAlways: {},
        onDeny: {}
    )
    .padding(16)
    .frame(width: 560)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("WebFetch") {
    PermissionCardView(
        request: PermissionRequest.makePreview(
            requestId: "preview-3",
            toolName: "WebFetch",
            input: [
                "url": "https://docs.swift.org/swift-book/",
                "prompt": "Summarise the section on protocols.",
            ]),
        onAllowOnce: {},
        onAllowAlways: {},
        onDeny: {}
    )
    .padding(16)
    .frame(width: 560)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("EnterPlanMode") {
    PermissionCardView(
        request: PermissionRequest.makePreview(
            requestId: "preview-4",
            toolName: "EnterPlanMode",
            input: [:]),
        onAllowOnce: {},
        onAllowAlways: {},
        onDeny: {}
    )
    .padding(16)
    .frame(width: 560)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("AskUserQuestion") {
    PermissionCardView(
        request: PermissionRequest.makePreview(
            requestId: "preview-ask",
            toolName: "AskUserQuestion",
            input: [
                "questions": [
                    [
                        "question":
                            "Should we keep backwards-compatibility shims for the old API?",
                        "header": "Compat",
                        "multiSelect": false,
                        "options": [
                            [
                                "label": "Yes, keep them",
                                "description": "Existing clients still depend on them",
                            ],
                            [
                                "label": "No, remove them",
                                "description": "Cleaner break, faster releases",
                            ],
                            [
                                "label": "Defer to next milestone",
                                "description": "Re-evaluate after the migration",
                            ],
                        ],
                    ],
                    [
                        "question": "Which timezone should the report default to?",
                        "header": "Timezone",
                        "options": [
                            ["label": "UTC"],
                            ["label": "America/Los_Angeles"],
                            ["label": "Asia/Shanghai"],
                        ],
                    ],
                    [
                        "question": "Do we ship a migration script in this PR?",
                        "header": "Migration",
                        "options": [
                            ["label": "Yes — include it"],
                            ["label": "No — handle ad hoc"],
                        ],
                    ],
                ]
            ]),
        onAllowOnce: {},
        onAllowAlways: {},
        onDeny: {}
    )
    .padding(16)
    .frame(width: 600, height: 620)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Fallback · unknown tool") {
    PermissionCardView(
        request: PermissionRequest.makePreview(
            requestId: "preview-5",
            toolName: "MysteryTool",
            input: [
                "command": "do-something --important"
            ]),
        onAllowOnce: {},
        onAllowAlways: {},
        onDeny: {}
    )
    .padding(16)
    .frame(width: 560)
    .background(Color(nsColor: .windowBackgroundColor))
}
