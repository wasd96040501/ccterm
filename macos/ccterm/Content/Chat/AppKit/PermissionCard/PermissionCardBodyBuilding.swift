import AgentSDK
import AppKit

/// The uniform per-kind body-builder interface for the AppKit permission card
/// (migration plan §4.4). It is the single delegation point the dispatch
/// `bodyBuilder(for:)` returns one of — replacing the SwiftUI
/// `PermissionCardView.body(for:kind:)` 12-arm `switch`
/// (`PermissionCardView.swift:97-129`).
///
/// **Why a protocol + dispatch instead of an inline switch.** The 11 real
/// per-kind bodies (Shell / SedEdit / FileWrite / NotebookEdit / WebFetch /
/// FilesystemRead / TaskAgent / Skill / Mcp / EnterPlanMode / ExitPlanMode)
/// are authored independently and in parallel against THIS protocol — none of
/// them touch the dispatch switch. Each real builder lives in its own file
/// under `Content/Chat/InputBarControls/AppKit/` and keeps the canonical
/// `Permission<Kind>CardBodyBuilder` name the switch below already returns, so
/// the dispatch never needed editing. The only stubs that remain here are the
/// two arms that never get a per-kind body: `AskUserQuestion` (owns its chrome,
/// §4.5) and the `.unknown` fallback.
///
/// The `askUserQuestion` arm is NOT a body builder here — it is the §4.5
/// delegation point (`PermissionCardContentView.bodyOwnsChrome`), so the card
/// renders no generic chrome for it and the body builder is never asked.
///
/// The protocol passes `engine` (the `SyntaxHighlightEngine` from
/// `DetailContext.syntaxEngine`) into every `makeBody` so the diff-family
/// bodies (Shell / SedEdit / FileWrite) can own a cancellable highlight `Task`
/// and reach the engine by argument rather than `@Environment` — they are not
/// blocked on this task. STUB conformers ignore it.
@MainActor
protocol PermissionCardBodyBuilding {
    /// Build the middle (body) section for one `PermissionRequest`. Returns a
    /// fresh `NSView` each call — the card mounts it into its `NSStackView`.
    /// `engine` is the shared syntax engine for diff-family bodies; STUBs and
    /// non-diff bodies ignore it.
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView
}

// MARK: - Dispatch

/// Map a `PermissionCardKind` to its body builder — the AppKit analogue of
/// `PermissionCardView.body(for:kind:)` (`PermissionCardView.swift:97-129`).
/// One builder instance per kind; `.askUserQuestion` is handled by the card's
/// chrome-takeover branch (it never reaches a body builder), and `default`
/// (`.unknown`) falls to the fallback that reads `PermissionCardStrings.parameter`.
///
/// Authored once. The parallel per-kind subtasks replace each STUB conformer's
/// `makeBody` body with the real port WITHOUT editing this function.
@MainActor
func permissionCardBodyBuilder(for kind: PermissionCardKind) -> PermissionCardBodyBuilding {
    switch kind {
    case .bash, .powerShell:
        return PermissionShellCardBodyBuilder()
    case .sedEdit:
        return PermissionSedEditCardBodyBuilder()
    case .fileEdit, .fileWrite:
        return PermissionFileWriteCardBodyBuilder()
    case .notebookEdit:
        return PermissionNotebookEditCardBodyBuilder()
    case .webFetch:
        return PermissionWebFetchCardBodyBuilder()
    case .filesystemRead:
        return PermissionFilesystemReadCardBodyBuilder()
    case .taskAgent:
        return PermissionTaskAgentCardBodyBuilder()
    case .skill:
        return PermissionSkillCardBodyBuilder()
    case .mcp:
        return PermissionMcpCardBodyBuilder()
    case .enterPlanMode:
        return PermissionEnterPlanModeCardBodyBuilder()
    case .exitPlanMode:
        return PermissionExitPlanModeCardBodyBuilder()
    case .askUserQuestion:
        // The §4.5 delegation point: the card renders no generic chrome for
        // AskUserQuestion (`bodyOwnsChrome`), so the body builder is never
        // asked for one. A no-op fallback is returned for completeness so a
        // hypothetical caller never crashes.
        return PermissionAskUserQuestionCardBodyBuilder()
    default:
        return PermissionFallbackCardBodyBuilder()
    }
}

// MARK: - Chrome-only / fallback conformers (no per-kind body)
//
// The 11 per-kind body builders live in their own files under
// `Content/Chat/InputBarControls/AppKit/` (e.g. `PermissionShellCardBody.swift`
// declares `PermissionShellCardBodyBuilder`). Only the two arms that never get a
// real per-kind body remain here.

/// AskUserQuestion. The card never asks for this body (it takes over the chrome,
/// §4.5); kept as a no-op so the dispatch is total.
struct PermissionAskUserQuestionCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // The AskUserQuestion wizard owns its own chrome via a dedicated view
        // controller (§4.5) — it is not built through this path.
        NSView()
    }
}

/// Fallback for `.unknown` / uncurated tools — a single monospace line from
/// `PermissionCardStrings.parameter(for:)`, 1:1 with the SwiftUI
/// `PermissionFallbackCardBody` (`PermissionCardView.swift:208-222`): size-12
/// monospaced, primary (labelColor), 3-line cap, middle truncation, selectable,
/// full-width leading. Renders nothing when no parameter resolves.
struct PermissionFallbackCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        guard let parameter = PermissionCardStrings.parameter(for: request) else {
            return container
        }
        let label = NSTextField(wrappingLabelWithString: parameter)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor  // SwiftUI `.primary`
        label.maximumNumberOfLines = 3  // SwiftUI `.lineLimit(3)`
        label.lineBreakMode = .byTruncatingMiddle  // SwiftUI `.truncationMode(.middle)`
        label.isSelectable = true  // SwiftUI `.textSelection(.enabled)`
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}
