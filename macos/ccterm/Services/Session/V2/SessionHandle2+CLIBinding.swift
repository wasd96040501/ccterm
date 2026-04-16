import Foundation
import AgentSDK

/// CLI 接线层：attach/detach 生命周期 + 所有 CLI 回调处理。
///
/// 这是 SessionHandle2 中变动最频繁的部分。attach 内注册所有 AgentSDK 回调，
/// 回调处理状态提取、pending 权限维护、进程退出处理、stderr 累积。
extension SessionHandle2 {

    /// 绑定后端。注册所有 CLI 回调，status 从 .inactive → .starting。
    /// 调用方：SessionService。
    func attach(backend: SessionBackend, bridge: SessionBridge) {
        fatalError("TODO")
    }

    /// 断开后端。拒绝所有 pending 权限，清空 stderr，status → .inactive。
    /// 调用方：SessionService。
    func detach() {
        fatalError("TODO")
    }

    /// 异步等待 sessionInit 到达。30 秒超时。
    /// 调用方：SessionService（launch 流程阻塞直到就绪）。
    func waitForSessionInit() async throws {
        fatalError("TODO")
    }
}
