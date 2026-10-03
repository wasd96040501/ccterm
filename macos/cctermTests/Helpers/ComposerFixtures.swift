import AgentSDK
import Foundation

@testable import ccterm

/// The composer's inputs as the design's sheet has them (`preview-live.js`
/// `MODELS`, `ACCOUNTS`, `COMMANDS`): the subscription's models with the older
/// ones folded, a provider with two aliases, one whose CLI hasn't answered.
enum ComposerFixtures {
    static let subscription = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let relay = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let deepseek = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    private static let allLevels = ["low", "medium", "high", "xhigh", "max"]

    static func model(
        _ value: String, _ name: String, resolved: String? = nil, levels: [String]? = nil, fast: Bool = false,
        auto: Bool = true
    ) -> InitializationResult.Model {
        let levels = levels ?? allLevels
        var model = InitializationResult.Model(
            value: value, displayName: name, supportsEffort: !levels.isEmpty, supportedEffortLevels: levels,
            supportsFastMode: fast, supportsAutoMode: auto)
        model.resolvedModel = resolved
        return model
    }

    /// A command as the CLI's `initialize` lists it (AgentSDK gives it no
    /// initializer of its own, only decoding).
    static func command(_ name: String, _ hint: String, _ description: String) -> SlashCommand {
        let json = ["name": name, "description": description, "argumentHint": hint]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SlashCommand.self, from: data)
    }

    static let commands: [SlashCommand] = [
        command("model", "[model]", "Set the AI model for this session"),
        command("effort", "[low|medium|high|xhigh|max]", "Set how hard Claude thinks"),
        command("compact", "[instructions]", "Clear history but keep a summary in context"),
        command("context", "", "Show what's in the context window"),
        command("clear", "", "Start a new conversation in this session"),
        command("review", "[PR]", "Review a pull request"),
        command("dataviz", "[request]", "Charts, dashboards and data visualizations"),
        command("fast", "[on|off]", "Toggle fast mode"),
    ]

    static let catalog = ModelCatalog(accounts: [
        AccountCatalog(
            id: subscription, name: "Claude Max", detail: "Subscription", isSubscription: true, isLoaded: true,
            models: [
                model("default", "Default (recommended)", resolved: "claude-opus-5-5", fast: true),
                model("opus", "Opus 5.5", fast: true),
                model("fable", "Fable 5.1"),
                model("sonnet", "Sonnet 5.5"),
                model("haiku", "Haiku 4.5", levels: [], auto: false),
                model("opus-5", "Opus 5", fast: true),
                model("sonnet-5", "Sonnet 5"),
                model("fable-5", "Fable 5"),
                model("opus-4-8", "Opus 4.8", fast: true),
                model("opus-4-7", "Opus 4.7"),
                model("opus-4-6", "Opus 4.6", levels: ["low", "medium", "high", "max"]),
                model("sonnet-4-6", "Sonnet 4.6", levels: ["low", "medium", "high", "max"]),
            ],
            shownModelCount: 5, commands: commands, fastModeUnavailableReason: nil, defaultPermissionMode: .auto),
        AccountCatalog(
            id: relay, name: "Work Relay", detail: "relay.example.com", isSubscription: false, isLoaded: true,
            models: [
                model(
                    "default", "Default", resolved: "claude-sonnet-4-6", levels: ["low", "medium", "high", "max"]),
                model("opus", "Opus", resolved: "claude-opus-4-6", levels: ["low", "medium", "high", "max"]),
                model("sonnet", "Sonnet", resolved: "claude-sonnet-4-6", levels: ["low", "medium", "high", "max"]),
                model("haiku", "Haiku", resolved: "claude-haiku-4-5", levels: [], auto: false),
            ],
            shownModelCount: 4, commands: commands, fastModeUnavailableReason: nil, defaultPermissionMode: nil),
        AccountCatalog(
            id: deepseek, name: "DeepSeek", detail: "api.deepseek.com", isSubscription: false, isLoaded: true,
            models: [model("default", "Default", resolved: "deepseek-v3.2", levels: [], auto: false)],
            shownModelCount: 1, commands: commands, fastModeUnavailableReason: nil, defaultPermissionMode: nil),
    ])

    /// The same, but the third account's CLI hasn't answered yet.
    static var catalogLoadingLast: ModelCatalog {
        var catalog = Self.catalog
        catalog.accounts[2].isLoaded = false
        catalog.accounts[2].models = []
        catalog.accounts[2].shownModelCount = 0
        return catalog
    }

    static func settings(
        _ value: String = "opus", on account: UUID = ComposerFixtures.subscription, effort: Effort? = .high,
        mode: PermissionMode = .auto, fast: Bool = false
    ) -> SessionSettings {
        SessionSettings(
            model: ModelChoice(account: account, value: value), effort: effort, permissionMode: mode, fastMode: fast)
    }

    static func session(
        _ phase: SessionState.Phase, waiting: Bool = false, visible: Bool = true
    ) -> ComposerModel.Context {
        .session(phase: phase, isWaitingForYou: waiting, isWaitingRequestVisible: visible)
    }

    static func model(
        _ context: ComposerModel.Context = .draft, settings: SessionSettings? = ComposerFixtures.settings(),
        pendingModel: ModelChoice? = nil, pendingFast: Bool? = nil, catalog: ModelCatalog = ComposerFixtures.catalog,
        allowsBypass: Bool = false, usage: Double? = nil, refusal: String? = nil,
        commands: [SlashCommand] = ComposerFixtures.commands
    ) -> ComposerModel {
        ComposerModel(
            ComposerModel.Input(
                context: context, placement: context == .draft ? .page : .floating, settings: settings,
                pendingModel: pendingModel, pendingFastMode: pendingFast,
                catalog: catalog, allowsBypassPermissions: allowsBypass, contextUsage: usage, refusal: refusal,
                commands: commands))
    }
}
