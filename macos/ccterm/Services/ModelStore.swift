import AgentSDK
import Foundation
import Observation

/// In-memory snapshot of the CLI's `[ModelInfo]` catalog, refreshed
/// on every app launch (no disk cache — a stale cache lets the picker
/// show models the CLI no longer offers, or hide ones it just added).
/// UI binds `isLoading` to a `ProgressView` while the first fetch is
/// in flight.
@Observable
@MainActor
final class ModelStore {
    static let shared = ModelStore()

    private(set) var models: [ModelInfo] = []
    /// True while the bootstrap fetch is running. UI binds this to the
    /// progress indicator next to the model trigger.
    private(set) var isLoading: Bool = false

    private init() {}

    /// Refresh from a session's `InitializeResponse.models` payload.
    /// Idempotent — empty input is treated as "no update" rather than
    /// "clear" (a transient init failure shouldn't blank the menu).
    func update(_ newModels: [ModelInfo]) {
        guard !newModels.isEmpty else { return }
        models = Self.withExtendedModels(newModels)
        isLoading = false
    }

    /// Merge extended-context models into any model list (deduped by value).
    /// Called from UI sites that resolve `session.availableModels` vs `store.models`.
    static func withExtendedModels(_ base: [ModelInfo]) -> [ModelInfo] {
        let existing = Set(base.map(\.value))
        let extras = extendedContextModels.filter { !existing.contains($0.value) }
        return base + extras
    }

    // 1M-context Opus variants not (yet) returned by the CLI catalog.
    private static let extendedContextModels: [ModelInfo] = {
        let dicts: [[String: Any]] = [
            [
                "value": "claude-opus-4-6[1m]",
                "displayName": "Opus 4.6 [1M]",
                "description": "Claude Opus 4.6 with 1M context",
                "supportsEffort": true,
                "supportedEffortLevels": ["low", "medium", "high", "xhigh"],
                "supportsFastMode": true,
                "supportsAutoMode": true,
            ],
            [
                "value": "claude-opus-4-7[1m]",
                "displayName": "Opus 4.7 [1M]",
                "description": "Claude Opus 4.7 with 1M context",
                "supportsEffort": true,
                "supportedEffortLevels": ["low", "medium", "high", "xhigh"],
                "supportsFastMode": true,
                "supportsAutoMode": true,
            ],
        ]
        return dicts.compactMap { try? ModelInfo(json: $0) }
    }()

    /// Kick off a one-shot CLI session in a temp directory, harvest the
    /// model catalog from its init response, and stop. Fires every
    /// launch. The in-flight dedupe is load-bearing: callers that hit
    /// `.shared` twice per launch (compose mode + a popover open before
    /// the first fetch lands) would otherwise race a second CLI
    /// process.
    func prefetchIfNeeded() {
        guard !isLoading else { return }
        isLoading = true
        appLog(.info, "ModelStore", "prefetch starting")
        Task.detached(priority: .userInitiated) { [weak self] in
            let fetched = await Self.fetchModels()
            await MainActor.run {
                guard let self else { return }
                if !fetched.isEmpty {
                    self.update(fetched)
                    appLog(.info, "ModelStore", "prefetch loaded \(fetched.count) models")
                } else {
                    self.isLoading = false
                    appLog(.warning, "ModelStore", "prefetch returned no models")
                }
            }
        }
    }

    private static func fetchModels() async -> [ModelInfo] {
        let tmpDir = NSTemporaryDirectory()
        let customCommand = await MainActor.run {
            UserDefaults.standard.string(forKey: "customCLICommand")
        }
        let config = SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: tmpDir),
            customCommand: customCommand,
            allowDangerouslySkipPermissions: true
        )
        let session = AgentSDK.Session(configuration: config)
        do {
            try await session.start()
        } catch {
            appLog(.warning, "ModelStore", "fetch session start failed: \(error)")
            session.stop()
            return []
        }
        let response: InitializeResponse? = await withCheckedContinuation { cont in
            session.initialize(promptSuggestions: false) { resp in
                cont.resume(returning: resp)
            }
        }
        session.stop()
        return response?.models ?? []
    }
}
