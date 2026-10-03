import DisplayModels
import Foundation

/// The composer's states as the design's sheet shows them (`preview-live.js`
/// `MODELS`, `ACCOUNTS`, `COMMANDS`, `buildLiveSpecimens`), already worded:
/// the subscription's models with the older ones folded, a provider with
/// aliases, one whose CLI hasn't answered; each state a `ComposerPresentation`.
/// The component tests render the same values.
enum ComposerFixtures {
    typealias P = ComposerPresentation

    static let subscription = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let relay = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let deepseek = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    static let commands: [P.Command] = [
        P.Command(name: "model", argumentHint: "[model]", description: "Set the AI model for this session"),
        P.Command(
            name: "effort", argumentHint: "[low|medium|high|xhigh|max]", description: "Set how hard Claude thinks"),
        P.Command(
            name: "compact", argumentHint: "[instructions]", description: "Clear history but keep a summary in context"),
        P.Command(name: "context", description: "Show what's in the context window"),
        P.Command(name: "clear", description: "Start a new conversation in this session"),
        P.Command(name: "review", argumentHint: "[PR]", description: "Review a pull request"),
        P.Command(
            name: "dataviz", argumentHint: "[request]", description: "Charts, dashboards and data visualizations"),
        P.Command(name: "fast", argumentHint: "[on|off]", description: "Toggle fast mode"),
    ]

    // MARK: Menus

    private static func item(
        _ id: String, _ title: String, _ subtitle: String? = nil, glyph: P.Glyph? = nil, checked: Bool = false,
        enabled: Bool = true, danger: Bool = false, restarts: Bool = false
    ) -> P.Item {
        P.Item(
            id: id, title: title, subtitle: subtitle, glyph: glyph, isChecked: checked, isEnabled: enabled,
            isDanger: danger, restarts: restarts)
    }

    /// The five levels; `checked` of 1…5 is the one in force.
    static func effortMenu(model: String, checked: Int?) -> P.Menu {
        let levels =
            [
                ("low", "Low", nil), ("medium", "Medium", nil), ("high", "High", "Default"),
                ("xhigh", "Extra High", nil), ("max", "Max", "This session only"),
            ] as [(String, String, String?)]
        let items = levels.enumerated().map { index, level in
            item(
                "effort:\(level.0)", level.1, level.2, glyph: .effort(level: index + 1), checked: checked == index + 1)
        }
        return P.Menu(sections: [P.Menu.Section(header: "Effort · \(model)", items: items)])
    }

    /// The five modes, Bypass apart; `checked` is the one in force.
    static func modeMenu(checked: P.Glyph) -> P.Menu {
        let modes: [(P.Glyph, String, String, String)] = [
            (.ask, "ask", "Ask Permissions", "Asks before edits and commands"),
            (.acceptEdits, "acceptEdits", "Accept Edits", "Edits files without asking; asks before commands"),
            (.plan, "plan", "Plan", "Reads and plans; changes nothing"),
            (.auto, "auto", "Auto", "Approves safe actions, asks when unsure"),
            (.dontAsk, "dontAsk", "Don’t Ask", "Runs only what’s already allowed"),
        ]
        return P.Menu(sections: [
            P.Menu.Section(
                header: "Permission Mode", headerHint: "⇧⇥",
                items: modes.map { item("mode:\($0.1)", $0.2, $0.3, glyph: $0.0, checked: $0.0 == checked) }),
            P.Menu.Section(
                items: [
                    item(
                        "mode:bypassPermissions", "Bypass Permissions", "Runs everything without asking",
                        glyph: .bypassPermissions, checked: checked == .bypassPermissions, danger: true)
                ]),
        ])
    }

    /// The model panel: the subscription's models with the older ones folded,
    /// a provider with aliases (restarting the session while a process runs),
    /// one whose CLI hasn't answered. `current` is the id of the checked model.
    static func modelSections(current: String, restarts: Bool = false) -> [P.ModelSection] {
        func models(_ account: UUID, _ rows: [(String, String, String?)]) -> [P.Item] {
            rows.map { value, name, resolved in
                let id = "model:\(account.uuidString):\(value)"
                return item(
                    id, name, resolved, checked: id == current, restarts: restarts && account != subscription)
            }
        }
        return [
            P.ModelSection(
                id: subscription, name: "Claude Max", detail: "Subscription", glyph: .subscription,
                items: models(
                    subscription,
                    [
                        ("default", "Default (recommended)", "Opus 5.5"), ("opus", "Opus 5.5", nil),
                        ("fable", "Fable 5.1", nil), ("sonnet", "Sonnet 5.5", nil), ("haiku", "Haiku 4.5", nil),
                    ]),
                foldedItems: models(
                    subscription,
                    [
                        ("opus-5", "Opus 5", nil), ("sonnet-5", "Sonnet 5", nil), ("fable-5", "Fable 5", nil),
                        ("opus-4-8", "Opus 4.8", nil), ("opus-4-7", "Opus 4.7", nil), ("opus-4-6", "Opus 4.6", nil),
                        ("sonnet-4-6", "Sonnet 4.6", nil),
                    ])),
            P.ModelSection(
                id: relay, name: "Work Relay", detail: "relay.example.com", glyph: .provider,
                note: restarts ? "Restarts the session" : nil,
                items: models(
                    relay,
                    [
                        ("default", "Default", "claude-sonnet-4-6"), ("opus", "Opus", "claude-opus-4-6"),
                        ("sonnet", "Sonnet", "claude-sonnet-4-6"), ("haiku", "Haiku", "claude-haiku-4-5"),
                    ])),
            P.ModelSection(
                id: deepseek, name: "DeepSeek", detail: "api.deepseek.com", glyph: .provider,
                note: restarts ? "Restarts the session" : nil,
                items: models(deepseek, [("default", "Default", "deepseek-v3.2")])),
        ]
    }

    // MARK: States

    /// The sheet's composer of one state; every argument is a fact the app
    /// words, here worded by hand.
    static func state(
        model: String = "Opus 5.5", provider: String? = nil, fast: Bool = false, pending: Bool = false,
        effort: (name: String, level: Int)? = ("High", 3), mode: P.Glyph = .auto,
        modeWords: (name: String, short: String)? = nil, status: P.Status? = nil, busy: Bool = false,
        ring: Double? = nil, action: P.Action = .send, failure: P.Failure? = nil, error: String? = nil,
        placement: P.Placement = .floating, draft: Bool = false, current: String? = nil
    ) -> P {
        let modeWords =
            modeWords ?? [
                .ask: ("Ask Permissions", "Ask"), .acceptEdits: ("Accept Edits", "Accept Edits"),
                .plan: ("Plan", "Plan"), .auto: ("Auto", "Auto"), .dontAsk: ("Don’t Ask", "Don’t Ask"),
                .bypassPermissions: ("Bypass Permissions", "Bypass"),
            ][mode] ?? ("Auto", "Auto")
        let working = action == .stop
        let percent = ring.map { "\(Int(($0 * 100).rounded())) %" }
        return P(
            placeholder: draft ? "Ask Claude to…" : "Message Claude",
            model: P.Chip(
                title: model, detail: provider, leadingGlyphs: fast ? [.fast] : [],
                trailingGlyph: pending ? .later : nil,
                toolTip: model),
            effort: effort.map {
                P.Chip(
                    title: $0.name, leadingGlyphs: [.effort(level: $0.level)], toolTip: "Effort: \($0.name)",
                    titleIsDroppable: true)
            }
                ?? P.Chip(
                    title: "—", leadingGlyphs: [.effort(level: nil)], isEnabled: false,
                    toolTip: "\(model) doesn’t take an effort level", titleIsDroppable: true),
            mode: P.Chip(
                title: modeWords.short, leadingGlyphs: [mode], isDanger: mode == .bypassPermissions,
                toolTip: modeWords.name, titleIsDroppable: true),
            modelSections: modelSections(current: current ?? "model:\(subscription.uuidString):opus"),
            modelPanelHeader: pending ? "Applies after this turn" : nil,
            fastMode: P.FastModeSwitch(
                isOn: fast, isEnabled: true, subtitle: "Faster output on Opus · billed as extra usage"),
            effortMenu: effortMenu(model: model, checked: effort?.level),
            modeMenu: modeMenu(checked: mode), cycledModeID: "mode:acceptEdits", status: status,
            contextRing: ring, action: action, failure: failure, error: error, commands: commands,
            placement: placement, statusIsBusy: busy, contextRingText: percent,
            contextRingToolTip: percent.map { "\($0) of the context is used — click for /context" },
            sendToolTip: working ? "Queue ↩" : "Send ↩", stopToolTip: busy ? "Cancel ⌘." : "Stop ⌘.")
    }

    static let idle = state(model: "Sonnet 5.5", effort: ("Extra High", 4), mode: .acceptEdits)
    static let responding = state(pending: true, action: .stop)
    static let waiting = state(mode: .ask, status: .waitingForYou("Waiting for you ↑"), action: .stop)
    static let starting = state(status: .note("Starting Claude…"), busy: true, action: .stop)
    static let atRest = state(
        model: "Sonnet 5.5", effort: ("Extra High", 4), mode: .acceptEdits,
        status: .note("Will resume when you send"))
    static let failed = state(
        failure: P.Failure(
            title: "Claude quit unexpectedly", detail: "Exit code 1",
            output: "API Error: 529 overloaded_error · retries exhausted"))
    static let haikuBypass = state(model: "Haiku 4.5", effort: nil, mode: .bypassPermissions)
    static let fastRing = state(fast: true, effort: ("Max", 5), mode: .acceptEdits, ring: 0.72)
    static let refused = state(error: "Opus 4.8 isn’t available to your organization.")
    static let newTab = state(
        model: "Default", provider: "Work Relay", mode: .acceptEdits, placement: .page, draft: true,
        current: "model:\(relay.uuidString):default")
    static let loading = P(
        placeholder: "Ask Claude to…", model: P.Chip(title: "Loading…", isEnabled: false),
        effort: P.Chip(title: "—", leadingGlyphs: [.effort(level: nil)], isEnabled: false, titleIsDroppable: true),
        mode: P.Chip(title: "Ask", leadingGlyphs: [.ask], isEnabled: false, titleIsDroppable: true),
        fastMode: P.FastModeSwitch(isOn: false, isEnabled: false), placement: .page,
        sendToolTip: "Send ↩", stopToolTip: "Stop ⌘.")
}
