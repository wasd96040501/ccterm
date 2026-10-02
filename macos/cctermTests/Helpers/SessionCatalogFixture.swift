import AgentSDK
import Foundation

@testable import ccterm

/// The design sheet's catalog (`preview-live.js` `MODELS`): the subscription
/// with *Default*, the three family aliases and two older models, and one
/// provider whose models take no effort and no Auto.
enum SessionCatalogFixture {
    static let subscription = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let relay = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private static let allFive = ["low", "medium", "high", "xhigh", "max"]
    private static let noExtraHigh = ["low", "medium", "high", "max"]

    static func model(
        _ value: String, name: String? = nil, resolved: String? = nil, levels: [String] = allFive,
        fast: Bool = false, auto: Bool = true
    ) -> InitializationResult.Model {
        var model = InitializationResult.Model(
            value: value, displayName: name ?? value, supportsEffort: !levels.isEmpty, supportedEffortLevels: levels,
            supportsFastMode: fast, supportsAutoMode: auto)
        model.resolvedModel = resolved
        return model
    }

    static var catalog: ModelCatalog {
        ModelCatalog(accounts: [
            AccountCatalog(
                id: subscription, name: "Claude Max", detail: "Subscription", isSubscription: true, isLoaded: true,
                models: [
                    model("default", name: "Default (recommended)", resolved: "claude-opus-5-5", fast: true),
                    model("opus", name: "Opus 5.5", resolved: "claude-opus-5-5", fast: true),
                    model("fable", name: "Fable 5.1", resolved: "claude-fable-5-1"),
                    model("sonnet", name: "Sonnet 5.5", resolved: "claude-sonnet-5-5"),
                    model("haiku", name: "Haiku 4.5", resolved: "claude-haiku-4-5", levels: [], auto: false),
                    model("claude-opus-4-6", name: "Opus 4.6", resolved: "claude-opus-4-6", levels: noExtraHigh),
                ],
                shownModelCount: 5, commands: [], fastModeUnavailableReason: nil, defaultPermissionMode: .auto),
            AccountCatalog(
                id: relay, name: "Work Relay", detail: "relay.example.com", isSubscription: false, isLoaded: true,
                models: [
                    model("default", name: "Default", resolved: "claude-sonnet-4-6", levels: noExtraHigh),
                    model("haiku", name: "Haiku", resolved: "claude-haiku-4-5", levels: [], auto: false),
                ],
                shownModelCount: 2, commands: [], fastModeUnavailableReason: nil, defaultPermissionMode: nil),
        ])
    }

    static func choice(_ value: String, on account: UUID = subscription) -> ModelChoice {
        ModelChoice(account: account, value: value)
    }

    static func settings(
        _ value: String = "opus", on account: UUID = subscription, effort: Effort? = nil,
        mode: PermissionMode = .default, fast: Bool = false
    ) -> SessionSettings {
        SessionSettings(model: choice(value, on: account), effort: effort, permissionMode: mode, fastMode: fast)
    }
}
