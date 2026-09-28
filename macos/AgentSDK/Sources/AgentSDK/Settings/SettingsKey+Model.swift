import Foundation

// Model, reasoning and request settings.

extension SettingsKey where Value == String {
    /// The model: an alias (`opus`), a model ID, or `default`. Applying it
    /// switches the session's model once the running turn ends (the call
    /// waits for that); a model outside the allowlist is refused or stepped
    /// down, which ``SettingsSnapshot/applied`` shows. Unsetting it returns
    /// the session to Claude Code's default model.
    public static var model: Self { Self("model") }

    /// The main-thread agent (built-in or custom): its system prompt, tools
    /// and model. Applied once the running turn ends; an unknown name fails
    /// the call. Unsetting it leaves the session with no main-thread agent.
    public static var agent: Self { Self("agent") }

    /// The model behind the server-side advisor tool.
    public static var advisorModel: Self { Self("advisorModel") }
}

extension SettingsKey where Value == [String] {
    /// Models tried in order when the primary is overloaded or unavailable.
    public static var fallbackModel: Self { Self("fallbackModel") }
}

extension SettingsKey where Value == Effort {
    /// Reasoning effort, applied from the next request. The layer keeps
    /// `low` through `xhigh`; `max` takes effect for the session but is not
    /// kept in the layer, so it reads back as absent, and runs as `high` on
    /// a model without `max`. Unsetting it returns the session to the
    /// model's default effort, not to the launch value.
    public static var effortLevel: Self { Self("effortLevel") }
}

extension SettingsKey where Value == Bool {
    /// Ultracode: standing workflow orchestration, in force only while the
    /// session runs at `xhigh` effort. Unsetting it turns it off, whatever
    /// the launch value.
    public static var ultracode: Self { Self("ultracode") }

    /// Fast mode, on models that support it. Applied once the running turn
    /// ends.
    public static var fastMode: Self { Self("fastMode") }

    /// `false` turns thinking off; absent or `true` lets supported models
    /// think.
    public static var alwaysThinkingEnabled: Self { Self("alwaysThinkingEnabled") }

    /// Whether to request summaries of the model's thinking.
    public static var showThinkingSummaries: Self { Self("showThinkingSummaries") }
}

extension SettingsKey where Value == PromptCacheTTL {
    /// Prompt-cache lifetime for the main conversation. Absent: automatic.
    public static var promptCacheTTL: Self { Self("promptCacheTtl") }
}
