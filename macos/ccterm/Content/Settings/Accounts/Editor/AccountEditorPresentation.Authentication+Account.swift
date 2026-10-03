import DisplayModels

extension AccountEditorPresentation.Authentication {
    /// The menu's choice for how `authentication` sends the credential.
    init(_ authentication: Account.Authentication) {
        switch authentication {
        case .authToken: self = .authToken
        case .apiKey: self = .apiKey
        }
    }
}

extension Account.Authentication {
    /// What the menu's `choice` stores.
    init(_ choice: AccountEditorPresentation.Authentication) {
        switch choice {
        case .authToken: self = .authToken
        case .apiKey: self = .apiKey
        }
    }
}
