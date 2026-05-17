import AgentSDK
import Foundation
import Observation

/// Cross-session cache of the CLI's `[ModelInfo]` catalog. The model
/// picker reads `models` directly so the popover has rows immediately
/// after launch (compose mode, fresh app start), with a small
/// `isLoading` flag the bar uses to render a `ProgressView` while the
/// first fetch is in flight. A finished session bootstrap also writes
/// the freshest catalog back through `update(_:)` so the cache stays
/// current.
@Observable
@MainActor
final class ModelStore {
    static let shared = ModelStore()

    private(set) var models: [ModelInfo] = []
    /// True while the bootstrap fetch is running. UI binds this to the
    /// progress indicator next to the model trigger.
    private(set) var isLoading: Bool = false

    private static let cacheKey = "cachedModelList"

    private init() {
        models = Self.cachedFromDisk()
    }

    /// Refresh from a session's `InitializeResponse.models` payload.
    /// Idempotent — empty input is treated as "no update" rather than
    /// "clear cache" (a transient init failure shouldn't blank the menu).
    func update(_ newModels: [ModelInfo]) {
        guard !newModels.isEmpty else { return }
        models = newModels
        Self.writeCache(newModels)
        isLoading = false
    }

    /// Kick off a one-shot CLI session in a temp directory, harvest the
    /// model catalog from its init response, and stop. Fires every
    /// launch — the disk cache only seeds the UI for cold start; a
    /// stale cache must not block a refresh, otherwise the user can
    /// never see a model the CLI added since last run. The in-flight
    /// dedupe is still load-bearing: callers that hit `.shared` twice
    /// per launch (compose mode + a popover open before the first
    /// fetch lands) would otherwise race a second CLI process.
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

    // MARK: - Disk cache

    private static func cachedFromDisk() -> [ModelInfo] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
            let raws = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raws.compactMap { try? ModelInfo(json: $0) }
    }

    private static func writeCache(_ newModels: [ModelInfo]) {
        let raws = newModels.map(\._raw)
        guard let data = try? JSONSerialization.data(withJSONObject: raws) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
