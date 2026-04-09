import Foundation
import AgentSDK

/// Caches and fetches the available model list.
enum ModelStore {

    private static let cacheKey = "cachedModelList"
    private static let timestampKey = "cachedModelListTimestamp"
    private static let expirationInterval: TimeInterval = 24 * 60 * 60  // 24 小时

    // MARK: - Cache

    static var cached: [ModelInfo] {
        get {
            guard let data = UserDefaults.standard.data(forKey: cacheKey),
                  let raws = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return raws.compactMap { try? ModelInfo(json: $0) }
        }
        set {
            let raws = newValue.map(\._raw)
            if let data = try? JSONSerialization.data(withJSONObject: raws) {
                UserDefaults.standard.set(data, forKey: cacheKey)
            }
        }
    }

    static var isCacheExpired: Bool {
        guard let timestamp = UserDefaults.standard.object(forKey: timestampKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(timestamp) > expirationInterval
    }

    /// Update cache from InitializeResponse (called after CLI starts).
    static func update(_ models: [ModelInfo]) {
        cached = models
        UserDefaults.standard.set(Date(), forKey: timestampKey)
    }

    /// 缓存过期时异步获取。用 tmp 目录启动临时 CLI。
    static func prefetchIfNeeded() {
        guard isCacheExpired else { return }
        let tmpDir = NSTemporaryDirectory()
        fetchModels(directory: tmpDir, pluginDirs: []) { models in
            if !models.isEmpty {
                CLICapabilityStore.shared.update(from: models)
            }
        }
    }

    /// Fetch models by starting a temporary CLI session.
    static func fetchModels(directory: String, pluginDirs: [String], completion: @escaping ([ModelInfo]) -> Void) {
        let config = SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: directory),
            plugins: pluginDirs
        )
        let session = AgentSDK.Session(configuration: config)

        Task {
            do {
                try await session.start()
                let response: InitializeResponse? = await withCheckedContinuation { continuation in
                    session.initialize(promptSuggestions: false) { response in
                        continuation.resume(returning: response)
                    }
                }

                let models = response?.models ?? []
                if !models.isEmpty {
                    update(models)
                }

                session.stop()

                DispatchQueue.main.async {
                    completion(models)
                }
            } catch {
                NSLog("[ModelStore] fetchModels failed: %@", "\(error)")
                session.stop()
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
    }
}
