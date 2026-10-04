import Foundation

/// Everything the composer shows, worded (design 08 *The composer*): the three
/// chips and their menus, the status slot, the action button's kind, the
/// failure section and the red line. The view only draws it and keeps what is
/// its own alone — the field's text, which decides whether the arrow is
/// enabled, and the slash list's filter.
///
/// A choice a reader can make (a menu item, ⇧⇥) is named by an `id` the app
/// gave it; the composer hands it back and never reads it.
public struct ComposerPresentation: Equatable, Sendable {
    /// Where the container stands the card.
    public enum Placement: Equatable, Sendable {
        /// In a page (a New tab's): the key hints under it, and room below for
        /// its menus and completion.
        case page
        /// Over a session's bottom edge: nothing under it; its menus and
        /// completion open above.
        case floating
    }

    /// A glyph the view draws — an SF Symbol or a generated asset, chosen by
    /// the view; this names only what it means.
    public enum Glyph: Hashable, Sendable {
        case fast
        /// *After this turn* (the 10-pt clock).
        case later
        /// A permission mode's.
        case ask, acceptEdits, plan, auto, dontAsk, bypassPermissions
        /// The effort meter filled to `level` of 5; `nil` empty.
        case effort(level: Int?)
        case subscription
        case provider
        /// ↻ — choosing it restarts the session.
        case restart
        case check
    }

    /// One pull-down's face.
    public struct Chip: Equatable, Sendable {
        public var title: String
        /// Tertiary words after the title (a provider's name); dropped first
        /// when the composer narrows.
        public var detail: String?
        public var leadingGlyphs: [Glyph]
        /// After the title: the clock while a change waits for the turn.
        public var trailingGlyph: Glyph?
        public var isEnabled: Bool
        /// Bypass Permissions: red glyph and text.
        public var isDanger: Bool
        public var toolTip: String?
        /// Whether the title may be dropped (leaving the glyphs) when the
        /// composer narrows — Effort's and Mode's; the model's never.
        public var titleIsDroppable: Bool

        public init(
            title: String, detail: String? = nil, leadingGlyphs: [Glyph] = [], trailingGlyph: Glyph? = nil,
            isEnabled: Bool = true, isDanger: Bool = false, toolTip: String? = nil, titleIsDroppable: Bool = false
        ) {
            self.title = title
            self.detail = detail
            self.leadingGlyphs = leadingGlyphs
            self.trailingGlyph = trailingGlyph
            self.isEnabled = isEnabled
            self.isDanger = isDanger
            self.toolTip = toolTip
            self.titleIsDroppable = titleIsDroppable
        }
    }

    /// An item of the Effort or Mode menu, or of the model panel.
    public struct Item: Equatable, Sendable {
        /// Handed back when it is chosen.
        public var id: String
        public var title: String
        public var subtitle: String?
        public var glyph: Glyph?
        public var isChecked: Bool
        public var isEnabled: Bool
        public var isDanger: Bool
        /// ↻ at the trailing edge: another account, while a process runs.
        public var restarts: Bool

        public init(
            id: String, title: String, subtitle: String? = nil, glyph: Glyph? = nil, isChecked: Bool = false,
            isEnabled: Bool = true, isDanger: Bool = false, restarts: Bool = false
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.glyph = glyph
            self.isChecked = isChecked
            self.isEnabled = isEnabled
            self.isDanger = isDanger
            self.restarts = restarts
        }
    }

    /// A menu: sections, each with an optional header (and its trailing key
    /// hint, ⇧⇥ for Mode), separated.
    public struct Menu: Equatable, Sendable {
        public struct Section: Equatable, Sendable {
            public var header: String?
            public var headerHint: String?
            public var items: [Item]

            public init(header: String? = nil, headerHint: String? = nil, items: [Item]) {
                self.header = header
                self.headerHint = headerHint
                self.items = items
            }
        }

        public var sections: [Section]

        public init(sections: [Section] = []) {
            self.sections = sections
        }
    }

    /// One account's section of the model menu (design 08 *Model*): every
    /// model it has.
    public struct ModelSection: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        /// *Subscription*, or the provider's host.
        public var detail: String
        public var glyph: Glyph
        /// *Restarts the session* / *Applies after this turn* / *Loading…*.
        public var note: String?
        public var items: [Item]

        public init(id: UUID, name: String, detail: String, glyph: Glyph, note: String? = nil, items: [Item]) {
            self.id = id
            self.name = name
            self.detail = detail
            self.glyph = glyph
            self.note = note
            self.items = items
        }
    }

    /// The Fast Mode switch under the panel's scroll.
    public struct FastModeSwitch: Equatable, Sendable {
        public var isOn: Bool
        public var isEnabled: Bool
        /// Why it is off-limits, or *after this turn*.
        public var subtitle: String?

        public init(isOn: Bool, isEnabled: Bool, subtitle: String? = nil) {
            self.isOn = isOn
            self.isEnabled = isEnabled
            self.subtitle = subtitle
        }
    }

    /// The status slot before the action button.
    public enum Status: Equatable, Sendable {
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
    public enum Action: Equatable, Sendable {
        case send
        case stop
    }

    /// The failure section at the card's top (design 08 *Failed*).
    public struct Failure: Equatable, Sendable {
        public var title: String
        /// The reason in words: *Exit code 1*, or the launch error.
        public var detail: String
        /// stderr's last line after it, set as the CLI's output (monospaced).
        public var output: String?

        public init(title: String, detail: String, output: String? = nil) {
            self.title = title
            self.detail = detail
            self.output = output
        }
    }

    /// A slash command the field completes.
    public struct Command: Equatable, Sendable {
        public var name: String
        /// Placeholder text for the arguments, e.g. `<file>`.
        public var argumentHint: String
        public var description: String

        public init(name: String, argumentHint: String = "", description: String = "") {
            self.name = name
            self.argumentHint = argumentHint
            self.description = description
        }
    }

    public var placeholder: String
    public var model: Chip
    public var effort: Chip
    public var mode: Chip
    public var modelSections: [ModelSection]
    /// *Applies after this turn* over every section while Claude works.
    public var modelPanelHeader: String?
    public var fastMode: FastModeSwitch
    public var effortMenu: Menu
    public var modeMenu: Menu
    /// What ⇧⇥ chooses: the id of the next mode in the cycle.
    public var cycledModeID: String?
    public var status: Status?
    /// The ring's fraction, from half full; `nil` hides it.
    public var contextRing: Double?
    public var action: Action
    public var failure: Failure?
    /// The red line under the card.
    public var error: String?
    public var commands: [Command]
    public var placement: Placement
    /// Whether the status slot's words come with the running arc (starting,
    /// compacting).
    public var statusIsBusy: Bool
    /// *50 %* beside the ring.
    public var contextRingText: String?
    public var contextRingToolTip: String?
    public var sendToolTip: String
    public var stopToolTip: String

    public init(
        placeholder: String, model: Chip, effort: Chip, mode: Chip, modelSections: [ModelSection] = [],
        modelPanelHeader: String? = nil, fastMode: FastModeSwitch, effortMenu: Menu = Menu(),
        modeMenu: Menu = Menu(), cycledModeID: String? = nil, status: Status? = nil, contextRing: Double? = nil,
        action: Action = .send, failure: Failure? = nil, error: String? = nil, commands: [Command] = [],
        placement: Placement, statusIsBusy: Bool = false, contextRingText: String? = nil,
        contextRingToolTip: String? = nil, sendToolTip: String, stopToolTip: String
    ) {
        self.placeholder = placeholder
        self.model = model
        self.effort = effort
        self.mode = mode
        self.modelSections = modelSections
        self.modelPanelHeader = modelPanelHeader
        self.fastMode = fastMode
        self.effortMenu = effortMenu
        self.modeMenu = modeMenu
        self.cycledModeID = cycledModeID
        self.status = status
        self.contextRing = contextRing
        self.action = action
        self.failure = failure
        self.error = error
        self.commands = commands
        self.placement = placement
        self.statusIsBusy = statusIsBusy
        self.contextRingText = contextRingText
        self.contextRingToolTip = contextRingToolTip
        self.sendToolTip = sendToolTip
        self.stopToolTip = stopToolTip
    }
}
