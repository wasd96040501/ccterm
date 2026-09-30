import Foundation

/// Which account the sheet edits, which decides its sections and buttons.
enum AccountEditorMode: Equatable {
    /// The subscription's settings, for the account signed in: its details,
    /// variables and launch; Sign Out….
    case subscription(Subscription)
    /// A provider being added: connection, variables, models, launch; Add.
    case newProvider
    /// A provider already in the list: the same, with Delete… and Save.
    case provider
}
