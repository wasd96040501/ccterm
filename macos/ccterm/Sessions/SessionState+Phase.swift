import AgentSDK
import Foundation

extension SessionState.Phase {
    /// A process exists: starting, idle, responding, compacting.
    nonisolated var isRunning: Bool {
        switch self {
        case .starting, .idle, .responding, .compacting: true
        case .atRest, .failed: false
        }
    }

    /// A turn runs: responding, compacting.
    nonisolated var isWorking: Bool {
        switch self {
        case .responding, .compacting: true
        case .atRest, .starting, .idle, .failed: false
        }
    }

    /// When `change` takes effect from `settings` in this phase (design 08
    /// *Settings × state*) — the rule `SessionState.timing(of:)` follows, for a
    /// composer that holds a phase and settings but no session state.
    ///
    /// With no process, or one still starting, every change is kept for the
    /// launch. Running, the mode lands now and the effort with the next
    /// request; the model and Fast Mode now when idle and after the turn when
    /// working; a model of another account is a restart.
    nonisolated func timing(
        of change: SessionSettings.Change, from settings: SessionSettings
    ) -> SessionState.ChangeTiming {
        switch self {
        case .atRest, .starting, .failed: return .atLaunch
        case .idle, .responding, .compacting: break
        }
        switch change {
        case .model(let choice):
            if choice.account != settings.model.account { return .restart }
            return isWorking ? .afterTurn : .now
        case .fastMode: return isWorking ? .afterTurn : .now
        case .effort: return .nextRequest
        case .permissionMode: return .now
        }
    }
}

extension SessionSettings {
    /// The effort a model runs at when none is chosen: `.high` when the model
    /// takes effort (the CLI doesn't report its default), `nil` when it takes
    /// none. A model the catalog doesn't know yet takes `nil`: nothing is
    /// shown for what isn't known.
    nonisolated static func defaultEffort(for model: ModelChoice, catalog: ModelCatalog) -> Effort? {
        guard let entry = catalog.model(model), entry.supportsEffort else { return nil }
        return .high
    }
}
