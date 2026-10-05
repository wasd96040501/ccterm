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
///
/// Codable for `NewSessionDefaults`: every value is written as the raw string
/// the CLI takes, so a value a later version doesn't know reads as the plain
/// default instead of failing the whole record.
nonisolated struct SessionSettings: Equatable, Sendable, Codable {
    var model: ModelChoice
    /// `nil`: the model's own default level.
    var effort: Effort?
    var permissionMode: PermissionMode
    var fastMode: Bool

    init(model: ModelChoice, effort: Effort?, permissionMode: PermissionMode, fastMode: Bool) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.fastMode = fastMode
    }

    /// One control's choice.
    enum Change: Hashable, Sendable {
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
    ///
    /// A model the catalog doesn't know (its account hasn't answered) brings
    /// nothing along: what it can't do isn't known.
    func applying(_ change: Change, catalog: ModelCatalog) -> SessionSettings {
        var next = self
        switch change {
        case .model(let model):
            next.model = model
            if let entry = catalog.model(model) {
                if !entry.supportsFastMode { next.fastMode = false }
                if !entry.supportsAutoMode, next.permissionMode == .auto { next.permissionMode = .default }
            }
        case .effort(let effort):
            next.effort = effort
        case .permissionMode(let mode):
            next.permissionMode = mode
        case .fastMode(let on):
            next.fastMode = on
            if on, next.permissionMode == .auto { next.permissionMode = .default }
        }
        return next
    }

    /// The level the CLI will actually run: the chosen one if the model
    /// supports it, else High; `nil` for a model that takes no effort
    /// (Haiku 4.5), whose chip is disabled and shows *—*. With no level chosen
    /// it is the model's own default (`defaultEffort(of:)`). A model the
    /// catalog doesn't know yet shows what was chosen.
    func effectiveEffort(catalog: ModelCatalog) -> Effort? {
        guard let entry = catalog.model(model) else { return effort }
        guard entry.supportsEffort else { return nil }
        guard let effort else { return Self.defaultEffort(for: model, catalog: catalog) }
        return Self.levels(of: entry).contains(effort) ? effort : .high
    }

    /// The levels `model` takes, in the scale's order; empty when it takes none.
    static func levels(of model: InitializationResult.Model) -> [Effort] {
        guard model.supportsEffort else { return [] }
        let named = Set(model.supportedEffortLevels.compactMap(Effort.init(rawValue:)))
        return Effort.allCases.filter(named.contains)
    }

    /// Why `mode` can't be chosen now, in words (*Unavailable while Fast Mode
    /// is on*, *Not on Haiku 4.5*, *Allow it in Settings › General*); `nil`
    /// when it can. A menu greys the item with this as its subtitle; ⇧⇥ skips it.
    func unavailability(
        of mode: PermissionMode, catalog: ModelCatalog, allowsBypassPermissions: Bool
    ) -> String? {
        switch mode {
        case .auto:
            if fastMode { return String(localized: "Unavailable while Fast Mode is on") }
            if let entry = catalog.model(model), !entry.supportsAutoMode {
                return String(localized: "Not on \(catalog.shortName(of: model) ?? entry.displayName)")
            }
            return nil
        case .bypassPermissions:
            return allowsBypassPermissions ? nil : String(localized: "Allow it in Settings › General")
        default:
            return nil
        }
    }

    /// The next mode ⇧⇥ moves to: Ask → Accept Edits → Plan → Auto, the CLI's
    /// own order, skipping any unavailable; Don't Ask and Bypass are reached
    /// only from the menu. From a mode outside the cycle it starts at Ask.
    func nextCycledMode(catalog: ModelCatalog, allowsBypassPermissions: Bool) -> PermissionMode {
        let cycle: [PermissionMode] = [.default, .acceptEdits, .plan, .auto]
        let start = cycle.firstIndex(of: permissionMode) ?? cycle.count - 1
        for step in 1...cycle.count {
            let candidate = cycle[(start + step) % cycle.count]
            if unavailability(of: candidate, catalog: catalog, allowsBypassPermissions: allowsBypassPermissions) == nil
            {
                return candidate
            }
        }
        return permissionMode
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case model, effort, permissionMode, fastMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(ModelChoice.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort).flatMap(Effort.init(rawValue:))
        permissionMode =
            try container.decodeIfPresent(String.self, forKey: .permissionMode).flatMap(PermissionMode.init(rawValue:))
            ?? .default
        fastMode = try container.decodeIfPresent(Bool.self, forKey: .fastMode) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(effort?.rawValue, forKey: .effort)
        try container.encode(permissionMode.rawValue, forKey: .permissionMode)
        try container.encode(fastMode, forKey: .fastMode)
    }
}
