import Foundation

/// A model as the reader chooses it: an account and one of the models it
/// serves. The account is not a control of its own — it follows from the
/// model (design 08 *Model*): a provider's models exist only under that
/// provider, so the pair is the choice.
nonisolated struct ModelChoice: Hashable, Codable, Sendable {
    /// The `Account.id` whose launch environment runs the model.
    var account: UUID
    /// What the CLI takes as `--model` / `set_model`: an `InitializationResult.Model.value`.
    /// `"default"` is the CLI's own choice, which follows its settings rather
    /// than pinning a model.
    var value: String

    /// The CLI's own default model on `account`.
    static func `default`(on account: UUID) -> ModelChoice {
        ModelChoice(account: account, value: "default")
    }
}
