import AgentSDK
import Foundation

/// Cross-session cache of the CLI's `[ModelInfo]` catalog, persisted to
/// `UserDefaults`. The model picker reads the cache when no session has
/// started yet (compose mode, fresh app launch), so the menu has rows
/// before the first `initialize` round-trip completes. Updated whenever a
/// `SessionHandle2` finishes bootstrap with a non-empty `models` array.
enum ModelStore {
    private static let cacheKey = "cachedModelList"

    static var cached: [ModelInfo] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
            let raws = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raws.compactMap { try? ModelInfo(json: $0) }
    }

    static func update(_ models: [ModelInfo]) {
        let raws = models.map(\._raw)
        guard let data = try? JSONSerialization.data(withJSONObject: raws) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
