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
/// their answers. What a phase means for the words (a process runs; a turn
/// runs) is read from the phase itself.
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
        /// `nil` while nothing is known yet — no catalog on a first launch, a
        /// session with no settings read: the chips say *Loading…*.
        var settings: SessionSettings?
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

    /// A New tab's composer: its pop-ups and completion open below it (the
    /// view is centred, with room under); a session's open above.
    var isDraft: Bool
    /// Whether the status slot's words come with the running arc (starting,
    /// compacting).
    var statusIsBusy: Bool
    /// *50 %* beside the ring.
    var contextRingText: String?
    var contextRingToolTip: String?
    var sendToolTip: String
    var stopToolTip: String

    init(_ input: Input) {
        let facts = Facts(input)
        isDraft = input.context == .draft
        statusIsBusy = facts.isBusy
        let percent = input.contextUsage.flatMap { $0 >= 0.5 ? Int((min($0, 1) * 100).rounded()) : nil }
        contextRingText = percent.map { "\($0) %" }
        contextRingToolTip = contextRingText.map {
            String(localized: "\($0) of the context is used — click for /context")
        }
        sendToolTip = facts.isWorking ? String(localized: "Queue ↩") : String(localized: "Send ↩")
        stopToolTip = facts.phase == .starting ? String(localized: "Cancel ⌘.") : String(localized: "Stop ⌘.")
        placeholder =
            input.context == .draft ? String(localized: "Ask Claude to…") : String(localized: "Message Claude")
        model = facts.modelChip()
        effort = facts.effortChip()
        mode = facts.modeChip()
        modelSections = facts.modelSections()
        modelPanelHeader = facts.isWorking ? String(localized: "Applies after this turn") : nil
        fastMode = facts.fastModeSwitch()
        effortMenu = facts.effortMenu()
        modeMenu = facts.modeMenu()
        cycledMode = facts.cycledMode()
        status = facts.status()
        contextRing = input.contextUsage.flatMap { $0 >= 0.5 ? min($0, 1) : nil }
        action = facts.isStoppable ? .stop : .send
        failure = facts.failure()
        error = input.refusal
        commands = input.commands
    }
}

// MARK: - Wording

extension ComposerModel {
    /// The five levels, in the order the menu lists them, with their names.
    static var effortLevels: [(effort: Effort, name: String)] {
        [
            (.low, String(localized: "Low")),
            (.medium, String(localized: "Medium")),
            (.high, String(localized: "High")),
            (.xhigh, String(localized: "Extra High")),
            (.max, String(localized: "Max")),
        ]
    }

    /// 1…5: how many bars of the meter a level fills.
    static func meterLevel(of effort: Effort) -> Int {
        (effortLevels.firstIndex { $0.effort == effort } ?? 0) + 1
    }

    /// A mode's menu name, its chip's short name and the line under it.
    static func words(of mode: PermissionMode) -> (name: String, short: String, subtitle: String) {
        switch mode {
        case .default:
            return (
                String(localized: "Ask Permissions"), String(localized: "Ask"),
                String(localized: "Asks before edits and commands")
            )
        case .acceptEdits:
            return (
                String(localized: "Accept Edits"), String(localized: "Accept Edits"),
                String(localized: "Edits files without asking; asks before commands")
            )
        case .plan:
            return (
                planName, planName, String(localized: "Reads and plans; changes nothing")
            )
        case .auto:
            return (
                String(localized: "Auto"), String(localized: "Auto"),
                String(localized: "Approves safe actions, asks when unsure")
            )
        case .dontAsk:
            return (
                String(localized: "Don’t Ask"), String(localized: "Don’t Ask"),
                String(localized: "Runs only what’s already allowed")
            )
        case .bypassPermissions:
            return (
                String(localized: "Bypass Permissions"), String(localized: "Bypass"),
                String(localized: "Runs everything without asking")
            )
        }
    }

    /// *Plan*, the permission mode — not the subscription plan's word, which
    /// Settings already translates.
    private static var planName: String { String(localized: "Plan (permission mode)", defaultValue: "Plan") }

    /// The modes the menu lists above its separator, in its order; Bypass is
    /// set apart under it.
    static let menuModes: [PermissionMode] = [.default, .acceptEdits, .plan, .auto, .dontAsk]

    /// A model's short name, as the chip says it: the name the CLI gives it,
    /// except where that names an alias — the CLI's own default, or any model
    /// of a provider, whose aliases are the provider's to define — which says
    /// what it resolves to (`claude-sonnet-4-6` → *Sonnet 4.6*).
    static func shortName(of model: InitializationResult.Model, isSubscription: Bool) -> String {
        if let resolved = model.resolvedModel, model.value == "default" || !isSubscription,
            let name = prettyModelName(resolved)
        {
            return name
        }
        return model.displayName
    }

    /// `claude-opus-5-5` → *Opus 5.5*, `claude-haiku-4-5-20251001` → *Haiku 4.5*;
    /// `nil` for an id that doesn't follow the pattern (`deepseek-v3.2`).
    static func prettyModelName(_ id: String) -> String? {
        var parts = id.split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return nil }
        parts.removeFirst()
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.allSatisfy(\.isLetter) else { return nil }
        let digits = parts.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return "\(family.capitalized) \(digits.joined(separator: "."))"
    }

    /// What the words are made from: the input, with the answers to the
    /// questions every part asks (which model is shown, whether a process
    /// runs, whether a turn does).
    fileprivate struct Facts {
        let input: Input
        let settings: SessionSettings?
        let shownModel: ModelChoice?
        let shownFast: Bool
        let account: AccountCatalog?
        let model: InitializationResult.Model?

        init(_ input: Input) {
            self.input = input
            settings = input.settings
            shownModel = input.pendingModel ?? input.settings?.model
            shownFast = input.pendingFastMode ?? input.settings?.fastMode ?? false
            account = shownModel.flatMap { input.catalog.account($0.account) }
            model = shownModel.flatMap { input.catalog.model($0) }
        }

        var phase: SessionState.Phase? {
            if case .session(let phase, _, _) = input.context { return phase }
            return nil
        }

        /// A process runs: an account change restarts it.
        var isRunning: Bool {
            switch phase {
            case .idle, .responding, .compacting: true
            default: false
            }
        }

        /// A turn runs: model and Fast apply after it.
        var isWorking: Bool {
            switch phase {
            case .responding, .compacting: true
            default: false
            }
        }

        /// Stop is what the action button does (and it cancels a launch).
        var isStoppable: Bool {
            switch phase {
            case .starting, .responding, .compacting: true
            default: false
            }
        }

        /// The running arc goes with the status words.
        var isBusy: Bool { phase == .starting || phase == .compacting }

        var hasPendingChange: Bool { input.pendingModel != nil || input.pendingFastMode != nil }

        var modelName: String {
            guard let choice = shownModel else { return String(localized: "Loading…") }
            if let model { return ComposerModel.shortName(of: model, isSubscription: account?.isSubscription ?? true) }
            return choice.value == "default" ? String(localized: "Default") : choice.value
        }

        /// A model the catalog doesn't know yet is taken to offer every level.
        var takesEffort: Bool { model?.supportedEffortLevels.isEmpty != true }

        /// The level that will run; `nil` for a model that takes none.
        var shownEffort: Effort? {
            guard let settings, takesEffort else { return nil }
            return settings.effectiveEffort(catalog: input.catalog) ?? .high
        }

        // MARK: Chips

        func modelChip() -> Chip {
            guard settings != nil else {
                return Chip(
                    title: String(localized: "Loading…"), detail: nil, leadingGlyphs: [], trailingGlyph: nil,
                    isEnabled: false, isDanger: false, toolTip: nil, titleIsDroppable: false)
            }
            let provider = account.flatMap { $0.isSubscription ? nil : $0.name }
            var tip = [account?.name, model?.resolvedModel ?? modelName].compactMap { $0 }.joined(separator: " · ")
            if hasPendingChange { tip += " — " + String(localized: "switches after this turn") }
            return Chip(
                title: modelName, detail: provider, leadingGlyphs: shownFast ? [.fast] : [],
                trailingGlyph: hasPendingChange ? .later : nil, isEnabled: true, isDanger: false,
                toolTip: tip, titleIsDroppable: false)
        }

        func effortChip() -> Chip {
            guard settings != nil, let level = shownEffort else {
                let tip = settings == nil ? nil : String(localized: "\(modelName) doesn’t take an effort level")
                return Chip(
                    title: "—", detail: nil, leadingGlyphs: [.effort(level: nil)], trailingGlyph: nil,
                    isEnabled: false, isDanger: false, toolTip: tip, titleIsDroppable: true)
            }
            let name = ComposerModel.effortLevels.first { $0.effort == level }?.name ?? level.rawValue
            return Chip(
                title: name, detail: nil, leadingGlyphs: [.effort(level: ComposerModel.meterLevel(of: level))],
                trailingGlyph: nil, isEnabled: true, isDanger: false,
                toolTip: String(localized: "Effort: \(name)"), titleIsDroppable: true)
        }

        func modeChip() -> Chip {
            let mode = settings?.permissionMode ?? .default
            let words = ComposerModel.words(of: mode)
            return Chip(
                title: words.short, detail: nil, leadingGlyphs: [.permissionMode(mode)], trailingGlyph: nil,
                isEnabled: settings != nil, isDanger: mode == .bypassPermissions, toolTip: words.name,
                titleIsDroppable: true)
        }

        // MARK: Menus

        func effortMenu() -> Menu {
            guard settings != nil else { return Menu(sections: []) }
            let supported = model.map { Set($0.supportedEffortLevels) }
            let items = ComposerModel.effortLevels.map { level, name -> Item in
                let isOffered = supported?.contains(level.rawValue) ?? true
                let subtitle: String?
                if !isOffered {
                    subtitle = String(localized: "Not on \(modelName)")
                } else if level == .high {
                    subtitle = String(localized: "Default")
                } else if level == .max {
                    subtitle = String(localized: "This session only")
                } else {
                    subtitle = nil
                }
                return Item(
                    title: name, subtitle: subtitle, glyph: .effort(level: ComposerModel.meterLevel(of: level)),
                    isChecked: shownEffort == level, isEnabled: isOffered, isDanger: false,
                    change: .effort(level), restarts: false)
            }
            return Menu(sections: [
                Menu.Section(header: String(localized: "Effort · \(modelName)"), headerHint: nil, items: items)
            ])
        }

        func modeMenu() -> Menu {
            guard let settings else { return Menu(sections: []) }
            func item(_ mode: PermissionMode) -> Item {
                let words = ComposerModel.words(of: mode)
                let why = settings.unavailability(
                    of: mode, catalog: input.catalog, allowsBypassPermissions: input.allowsBypassPermissions)
                return Item(
                    title: words.name, subtitle: why ?? words.subtitle, glyph: .permissionMode(mode),
                    isChecked: settings.permissionMode == mode, isEnabled: why == nil,
                    isDanger: mode == .bypassPermissions, change: .permissionMode(mode), restarts: false)
            }
            return Menu(sections: [
                Menu.Section(
                    header: String(localized: "Permission Mode"), headerHint: "⇧⇥",
                    items: ComposerModel.menuModes.map(item)),
                Menu.Section(header: nil, headerHint: nil, items: [item(.bypassPermissions)]),
            ])
        }

        func cycledMode() -> SessionSettings.Change? {
            guard let settings else { return nil }
            let next = settings.nextCycledMode(
                catalog: input.catalog, allowsBypassPermissions: input.allowsBypassPermissions)
            return next == settings.permissionMode ? nil : .permissionMode(next)
        }

        // MARK: The model panel

        func modelSections() -> [ModelSection] {
            guard let settings else { return [] }
            let current = shownModel
            return input.catalog.accounts.map { account in
                let restarts = isRunning && account.id != settings.model.account
                func item(_ model: InitializationResult.Model) -> Item {
                    let short = ComposerModel.shortName(of: model, isSubscription: account.isSubscription)
                    let subtitle: String?
                    if !account.isSubscription {
                        subtitle = model.resolvedModel.flatMap { $0 == model.displayName ? nil : $0 }
                    } else if model.value == "default", short != model.displayName {
                        subtitle = short
                    } else {
                        subtitle = nil
                    }
                    let choice = ModelChoice(account: account.id, value: model.value)
                    return Item(
                        title: model.displayName, subtitle: subtitle, glyph: nil, isChecked: choice == current,
                        isEnabled: !model.isDisabled, isDanger: false, change: .model(choice), restarts: restarts)
                }
                let count = min(max(account.shownModelCount, 0), account.models.count)
                var shown = Array(account.models[..<count])
                var folded = Array(account.models[count...])
                // The current model is never folded away.
                if let current, current.account == account.id, folded.contains(where: { $0.value == current.value }) {
                    shown += folded
                    folded = []
                }
                let note: String?
                if !account.isLoaded {
                    note = String(localized: "Loading…")
                } else if restarts {
                    note = String(localized: "Restarts the session")
                } else {
                    note = nil
                }
                return ModelSection(
                    id: account.id, name: account.name, detail: account.detail,
                    glyph: account.isSubscription ? .subscription : .provider, note: note,
                    items: shown.map(item), foldedItems: folded.map(item))
            }
        }

        func fastModeSwitch() -> FastModeSwitch {
            guard settings != nil else { return FastModeSwitch(isOn: false, isEnabled: false, subtitle: nil) }
            let supports = model?.supportsFastMode ?? false
            let reason = account?.fastModeUnavailableReason
            let subtitle: String
            if let reason {
                subtitle = reason
            } else if !supports {
                if account?.isSubscription ?? true {
                    let names =
                        input.catalog.subscription?.models.filter { $0.supportsFastMode && $0.value != "default" }
                        .map(\.displayName) ?? []
                    subtitle =
                        names.isEmpty
                        ? String(localized: "Not on this model")
                        : String(localized: "\(ListFormatter.localizedString(byJoining: names)) only")
                } else {
                    subtitle = String(localized: "Only with the subscription")
                }
            } else if isWorking, input.pendingFastMode != nil {
                subtitle = String(localized: "After this turn")
            } else {
                subtitle = String(localized: "Faster output on Opus · billed as extra usage")
            }
            return FastModeSwitch(isOn: shownFast, isEnabled: supports && reason == nil, subtitle: subtitle)
        }

        // MARK: Status, failure

        func status() -> Status? {
            guard case .session(let phase, let isWaiting, let isVisible) = input.context else { return nil }
            if isWaiting, !isVisible { return .waitingForYou(String(localized: "Waiting for you ↑")) }
            switch phase {
            case .starting: return .note(String(localized: "Starting Claude…"))
            case .compacting: return .note(String(localized: "Compacting…"))
            case .atRest: return .note(String(localized: "Will resume when you send"))
            default: return nil
            }
        }

        func failure() -> Failure? {
            guard case .failed(let failure) = phase else { return nil }
            return Failure(title: String(localized: "Claude quit unexpectedly"), detail: failure.message)
        }
    }
}
