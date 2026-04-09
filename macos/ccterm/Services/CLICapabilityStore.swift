import AgentSDK
import Observation

/// App 层的 CLI 能力缓存 + 响应式包装。
@Observable
@MainActor
final class CLICapabilityStore {
    static let shared = CLICapabilityStore()

    private(set) var capability: CLICapability?
    /// 可用模型列表（从 InitializeResponse 获取，或 ModelStore 缓存）
    private(set) var availableModels: [ModelInfo] = []

    func isAvailable(_ feature: CLIFeature) -> Bool {
        capability?.isAvailable(feature) ?? false
    }

    // MARK: - Per-model 能力（运行时细化）

    /// 当前选中模型是否支持 effort
    func supportsEffort(for modelValue: String?) -> Bool {
        guard let modelValue,
              let info = availableModels.first(where: { $0.value == modelValue }) else {
            return true // 未选模型（default）假定支持
        }
        return info.supportsEffort ?? false
    }

    /// 当前选中模型支持的 effort levels。nil = 不支持，返回空数组。
    func supportedEffortLevels(for modelValue: String?) -> [Effort] {
        guard let modelValue,
              let info = availableModels.first(where: { $0.value == modelValue }) else {
            return Effort.allCases // 未选模型（default）假定全部支持
        }
        guard let levels = info.supportedEffortLevels else { return [] }
        return levels.compactMap { Effort(rawValue: $0) }
    }

    /// 当前选中模型是否支持 auto permission mode
    func supportsAutoMode(for modelValue: String?) -> Bool {
        guard let modelValue,
              let info = availableModels.first(where: { $0.value == modelValue }) else {
            return true // 未选模型（default）假定支持
        }
        return info.supportsAutoMode ?? false
    }

    // MARK: - Update

    /// App 启动时调用
    func loadFromCache() {
        availableModels = ModelStore.cached
    }

    /// 从 InitializeResponse 更新（每次会话启动后调用）
    func update(from models: [ModelInfo]) {
        availableModels = models
        ModelStore.update(models)
    }

    /// 检测 CLI 版本（异步，App 启动时调用）
    func detectVersion() {
        Task.detached {
            let cap = await CLICapability.detect()
            await MainActor.run { self.capability = cap }
        }
    }
}
