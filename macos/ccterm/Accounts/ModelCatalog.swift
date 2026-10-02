import AgentSDK
import Foundation

/// What every account's CLI offers — its models, their effort levels and
/// modes, its slash commands — as its `initialize` answered, in Settings'
/// order of accounts. The composer's menus read it before any session runs
/// (design 08 *Where the menus get models*); `ModelCatalogStore` keeps it.
nonisolated struct ModelCatalog: Sendable, Equatable {
    /// One per account, the subscription first, then providers as Settings
    /// lists them. An account whose CLI hasn't answered yet is present with
    /// `isLoaded` false, so its section can say *Loading…*.
    var accounts: [AccountCatalog]

    init(accounts: [AccountCatalog] = []) {
        self.accounts = accounts
    }

    /// The account `id`'s catalog, if it is one.
    func account(_ id: UUID) -> AccountCatalog? {
        accounts.first { $0.id == id }
    }

    /// The model `choice` names, if its account offers it.
    func model(_ choice: ModelChoice) -> InitializationResult.Model? {
        account(choice.account)?.models.first { $0.value == choice.value }
    }

    /// The subscription's account, the usual one.
    var subscription: AccountCatalog? {
        accounts.first { $0.isSubscription }
    }
}

/// One account's section of the catalog.
nonisolated struct AccountCatalog: Sendable, Equatable, Identifiable {
    /// The `Account.id`.
    let id: UUID
    /// Settings' name for it (*Claude Max*, *Work Relay*).
    var name: String
    /// Its detail in the section header: *Subscription*, or the provider's host.
    var detail: String
    var isSubscription: Bool
    /// Whether its CLI has answered (from this launch or the disk cache).
    var isLoaded: Bool
    /// Every model `initialize` listed, in its order; the first `shownModelCount`
    /// are listed, the rest fold into *N More Models* (the current model is never
    /// folded — that is the menu's to honour).
    var models: [InitializationResult.Model]
    var shownModelCount: Int
    /// The slash commands this account's CLI knows, for completion in a New tab.
    var commands: [SlashCommand]
    /// Why Fast Mode can't be used on this account (`fast_mode_disabled_reason`
    /// in words); `nil` when it can.
    var fastModeUnavailableReason: String?
    /// The CLI's `current_permission_mode` — a New tab's first default.
    var defaultPermissionMode: PermissionMode?
}
