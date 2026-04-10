import Foundation

/// SessionHandle 广播的事件。消费者通过 `handle.eventStream()` 订阅。
enum SessionEvent {
    /// 运行时状态变化。
    case statusChanged(old: SessionHandle.Status, new: SessionHandle.Status)
    /// 待决策权限列表变化（新增/移除/清空）。
    case permissionsChanged([PendingPermission])
    /// 子进程退出。emit 时 status 仍是退出前的值。
    case processExited(ProcessExit)
    /// 工作目录变化（sessionInit 或 pathChange）。
    case cwdChanged(String)
}
