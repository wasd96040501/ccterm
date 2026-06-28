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
/// them touch the dispatch switch. This task ships ONE STUB conformer per kind
/// (each returns an empty `NSView()` so the spine builds + the card mounts
/// without a crash); the parallel fan-out swaps each STUB body for the real
/// one without editing `bodyBuilder(for:)`.
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
/// (`.unknown`) falls to the fallback that reads `PermissionCardCopy.parameter`.
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

// MARK: - STUB conformers (one per kind — empty NSView, no crash)
//
// Each STUB returns a bare `NSView()` so the dispatch + card spine build and
// the card mounts. The 11 real bodies (and the fallback) are authored
// independently in the parallel fan-out against `PermissionCardBodyBuilding`,
// each swapping its STUB's `makeBody` for the real port. DO NOT inline the real
// body here — that would collide with the parallel subtasks.

/// STUB — Bash / PowerShell. Real body: command + diff (sed-as-edit goes to
/// `PermissionSedEditCardBodyBuilder`), bash rule count.
struct PermissionShellCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionShellCardBody` — command
        // mono block + optional command-diff (DiffNSView) + bash rule count.
        NSView()
    }
}

/// STUB — sed-in-place edit (a Bash command `parseSedEditCommand` matched).
struct PermissionSedEditCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionSedEditCardBody` — diff +
        // literal command fallback.
        NSView()
    }
}

/// STUB — Edit / MultiEdit / FileEdit / Write / FileWrite.
struct PermissionFileWriteCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionFileWriteCardBody` — file
        // path + basename + diff (FS read at build time) + subtitle.
        NSView()
    }
}

/// STUB — NotebookEdit.
struct PermissionNotebookEditCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionNotebookEditCardBody`.
        NSView()
    }
}

/// STUB — WebFetch.
struct PermissionWebFetchCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionWebFetchCardBody` — domain
        // chip + prompt.
        NSView()
    }
}

/// STUB — Read / Glob / Grep / FileRead.
struct PermissionFilesystemReadCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionFilesystemReadCardBody`.
        NSView()
    }
}

/// STUB — Task / Agent.
struct PermissionTaskAgentCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionTaskAgentCardBody` — chip +
        // description.
        NSView()
    }
}

/// STUB — Skill.
struct PermissionSkillCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionSkillCardBody` — cwd chip +
        // skill detail.
        NSView()
    }
}

/// STUB — `mcp__*` tools.
struct PermissionMcpCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionMcpCardBody` — server chip +
        // tool detail.
        NSView()
    }
}

/// STUB — EnterPlanMode.
struct PermissionEnterPlanModeCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionEnterPlanModeCardBody`.
        NSView()
    }
}

/// STUB — ExitPlanMode / ExitPlanModeV2.
struct PermissionExitPlanModeCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port `PermissionExitPlanModeCardBody` — the
        // plan markdown.
        NSView()
    }
}

/// STUB — AskUserQuestion. The card never asks for this body (it takes over
/// the chrome, §4.5); kept as a no-op so the dispatch is total.
struct PermissionAskUserQuestionCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(§4.5): the AskUserQuestion wizard owns its own chrome via a
        // dedicated view controller — it is not built through this path.
        NSView()
    }
}

/// STUB — fallback for `.unknown` / uncurated tools. Real body: a single
/// monospace line from `PermissionCardCopy.parameter(for:)`.
struct PermissionFallbackCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // TODO(parallel fan-out): port the fallback body — a single
        // monospace `PermissionCardCopy.parameter(for:)` line (lineLimit 3).
        NSView()
    }
}
