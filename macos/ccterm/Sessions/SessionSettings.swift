import AgentSDK
import Foundation

/// What a session runs on, as the composer's controls choose it: model (and
/// with it the account), effort, permission mode and Fast Mode.
///
/// A New tab holds one as its draft; a session's `SessionState.settings` is
/// the one its CLI runs (or, at rest, the one it last ran, read back from the
/// transcript). The rules that tie the four together — what a change brings
/// with it — are here, pure, so a draft and a live session follow the same
/// ones (design 08 *Settings × state*).
nonisolated struct SessionSettings: Equatable, Sendable {
    var model: ModelChoice
    /// `nil`: the model's own default level.
    var effort: Effort?
    var permissionMode: PermissionMode
    var fastMode: Bool

    /// One control's choice.
    enum Change: Equatable, Sendable {
        case model(ModelChoice)
        /// `nil` goes back to the model's default level.
        case effort(Effort?)
        case permissionMode(PermissionMode)
        case fastMode(Bool)
    }

    /// The settings after `change`, with what it brings along (design 08
    /// *Fast Mode*, *Permission mode*):
    /// - a model without Fast Mode turns Fast off;
    /// - Fast on, or a model without Auto, steps Auto down to Ask;
    /// - an effort the new model lacks is kept (the CLI runs it as High, see
    ///   `effectiveEffort`), so switching back restores it.
    func applying(_ change: Change, catalog: ModelCatalog) -> SessionSettings {
        // TODO(fill B): the cascades; covered by SessionSettingsTests.
        var next = self
        switch change {
        case .model(let model): next.model = model
        case .effort(let effort): next.effort = effort
        case .permissionMode(let mode): next.permissionMode = mode
        case .fastMode(let on): next.fastMode = on
        }
        return next
    }

    /// The level the CLI will actually run: the chosen one if the model
    /// supports it, else High; `nil` for a model that takes no effort
    /// (Haiku 4.5), whose chip is disabled and shows *—*.
    func effectiveEffort(catalog: ModelCatalog) -> Effort? {
        // TODO(fill B)
        effort
    }

    /// Why `mode` can't be chosen now, in words (*Unavailable while Fast Mode
    /// is on*, *Not on Haiku 4.5*, *Allow it in Settings › General*); `nil`
    /// when it can. A menu greys the item with this as its subtitle; ⇧⇥ skips it.
    func unavailability(
        of mode: PermissionMode, catalog: ModelCatalog, allowsBypassPermissions: Bool
    ) -> String? {
        // TODO(fill B)
        nil
    }

    /// The next mode ⇧⇥ moves to: Ask → Accept Edits → Plan → Auto, the CLI's
    /// own order, skipping any unavailable; Don't Ask and Bypass are reached
    /// only from the menu.
    func nextCycledMode(catalog: ModelCatalog, allowsBypassPermissions: Bool) -> PermissionMode {
        // TODO(fill B)
        permissionMode
    }
}
