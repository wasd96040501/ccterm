import AgentSDK
import Foundation

/// Everything the composer shows, worded (design 08 *The composer*): the
/// three chips and their menus, the status slot, the action button's kind,
/// the failure section and the red line. Pure — built from the session's
/// facts and the catalog, tested without AppKit; the views only draw it and
/// keep what is theirs alone (the field's text, which decides whether the
/// arrow is enabled; the slash list's filter).
///
/// One model for both tabs: a New tab is `.draft`, a session tab
/// `.session(…)`. Every rule of what can be chosen when is asked of
/// `SessionSettings` / `SessionState`, never decided here; this only words
/// their answers.
nonisolated struct ComposerModel: Equatable, Sendable {
    /// Where the composer is.
    enum Context: Equatable, Sendable {
        /// A New tab: nothing runs, every choice applies at launch.
        case draft
        /// A session's tab: its phase, whether a request waits for the reader,
        /// and whether that request is in view (*Waiting for you ↑* when not).
        case session(phase: SessionState.Phase, isWaitingForYou: Bool, isWaitingRequestVisible: Bool)
    }

    /// The facts the model is built from.
    struct Input: Equatable, Sendable {
        var context: Context
        var settings: SessionSettings
        var pendingModel: ModelChoice?
        var pendingFastMode: Bool?
        var catalog: ModelCatalog
        var allowsBypassPermissions: Bool
        /// How full the context is, 0…1; `nil` before the first turn.
        var contextUsage: Double?
        /// The last refusal, in words.
        var refusal: String?
        /// The slash commands to complete (the session's, else the catalog's).
        var commands: [SlashCommand]
    }

    /// A glyph a view draws — an SF Symbol or a generated asset, chosen by the
    /// view; the model names only what it means.
    enum Glyph: Equatable, Sendable {
        case fast
        /// *After this turn* (the 10-pt clock).
        case later
        case permissionMode(PermissionMode)
        /// The effort meter filled to `level` of 5; `nil` empty.
        case effort(level: Int?)
        case subscription
        case provider
        /// ↻ — choosing it restarts the session.
        case restart
        case check
    }

    /// One pull-down's face.
    struct Chip: Equatable, Sendable {
        var title: String
        /// Tertiary words after the title (a provider's name); dropped first
        /// when the composer narrows.
        var detail: String?
        var leadingGlyphs: [Glyph]
        /// After the title: the clock while a change waits for the turn.
        var trailingGlyph: Glyph?
        var isEnabled: Bool
        /// Bypass Permissions: red glyph and text.
        var isDanger: Bool
        var toolTip: String?
        /// Whether the title may be dropped (leaving the glyphs) when the
        /// composer narrows — Effort's and Mode's; the model's never.
        var titleIsDroppable: Bool
    }

    /// An item of the Effort or Mode menu, or of the model panel.
    struct Item: Equatable, Sendable {
        var title: String
        var subtitle: String?
        var glyph: Glyph?
        var isChecked: Bool
        var isEnabled: Bool
        var isDanger: Bool
        /// What choosing it does.
        var change: SessionSettings.Change
        /// ↻ at the trailing edge: another account, while a process runs.
        var restarts: Bool
    }

    /// A menu: sections, each with an optional header (and its trailing key
    /// hint, ⇧⇥ for Mode), separated.
    struct Menu: Equatable, Sendable {
        struct Section: Equatable, Sendable {
            var header: String?
            var headerHint: String?
            var items: [Item]
        }
        var sections: [Section]
    }

    /// One account's section of the model panel (design 08 *Model*).
    struct ModelSection: Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        /// *Subscription*, or the provider's host.
        var detail: String
        var glyph: Glyph
        /// *Restarts the session* / *Applies after this turn* / *Loading…*.
        var note: String?
        var items: [Item]
        /// Models folded into *N More Models* (expands in place).
        var foldedItems: [Item]
    }

    /// The Fast Mode switch under the panel's scroll.
    struct FastModeSwitch: Equatable, Sendable {
        var isOn: Bool
        var isEnabled: Bool
        /// Why it is off-limits (*Opus 5.5, Opus 5 and Opus 4.8 only*, *Only
        /// with the subscription*, *Requires extra usage*), or *after this turn*.
        var subtitle: String?
    }

    /// The status slot before the action button.
    enum Status: Equatable, Sendable {
        /// Plain tertiary words: *Starting Claude…*, *Compacting…*, *Will
        /// resume when you send*.
        case note(String)
        /// Coral *Waiting for you ↑*; a click scrolls to the request.
        case waitingForYou(String)
    }

    /// The action button. `.send`: the arrow, accent with text in the field,
    /// grey and disabled without (the field's text is the view's own fact).
    /// `.stop`: the stop square while Claude works or starts — and, with text
    /// in the field, the arrow beside it, stop to the left.
    enum Action: Equatable, Sendable {
        case send
        case stop
    }

    /// The failure section at the card's top (design 08 *Failed*).
    struct Failure: Equatable, Sendable {
        var title: String
        var detail: String
    }

    var placeholder: String
    var model: Chip
    var effort: Chip
    var mode: Chip
    var modelSections: [ModelSection]
    /// *Applies after this turn* over every section while Claude works.
    var modelPanelHeader: String?
    var fastMode: FastModeSwitch
    var effortMenu: Menu
    var modeMenu: Menu
    /// What ⇧⇥ chooses: the next available mode in the CLI's cycle.
    var cycledMode: SessionSettings.Change?
    var status: Status?
    /// The ring's fraction, from half full; `nil` hides it.
    var contextRing: Double?
    var action: Action
    var failure: Failure?
    /// The red line under the card.
    var error: String?
    var commands: [SlashCommand]

    init(_ input: Input) {
        // TODO(fill C): word every part from `input` (design 08, preview-live.js
        // `accHTML`, `menuItems`, `MENU`); ComposerModelTests.
        placeholder =
            input.context == .draft ? String(localized: "Ask Claude to…") : String(localized: "Message Claude")
        let empty = Chip(
            title: "", detail: nil, leadingGlyphs: [], trailingGlyph: nil, isEnabled: true, isDanger: false,
            toolTip: nil, titleIsDroppable: false)
        model = empty
        effort = empty
        mode = empty
        modelSections = []
        modelPanelHeader = nil
        fastMode = FastModeSwitch(isOn: input.settings.fastMode, isEnabled: false, subtitle: nil)
        effortMenu = Menu(sections: [])
        modeMenu = Menu(sections: [])
        cycledMode = nil
        status = nil
        contextRing = nil
        switch input.context {
        case .draft:
            action = .send
        case .session(let phase, _, _):
            switch phase {
            case .starting, .responding, .compacting: action = .stop
            default: action = .send
            }
        }
        failure = nil
        error = input.refusal
        commands = input.commands
    }
}
