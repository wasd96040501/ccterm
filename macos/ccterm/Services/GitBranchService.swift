import Foundation
import Observation

/// 统一的 git branch 文件监控服务。按路径去重，多个会话共享同一 cwd 时只建一个 FileMonitor。
///
/// 使用方：
/// - SidebarViewModel：历史会话（无 handle）通过 branch(for:) 读取
/// - SessionHandle：活跃会话通过 branch 属性（由 GitBranchService 写入）
@Observable
@MainActor
final class GitBranchService {

    /// 路径 → 分支名
    private(set) var branchByPath: [String: String] = [:]

    /// 活跃的文件监控（路径 → source）
    @ObservationIgnored private var sources: [String: DispatchSourceFileSystemObject] = [:]

    /// 每个路径的引用计数（多个会话可能共享 cwd）
    @ObservationIgnored private var refCounts: [String: Int] = [:]

    /// 注册路径监控，引用计数 +1。
    func observe(path: String) {
        refCounts[path, default: 0] += 1
        guard sources[path] == nil else { return }
        // 立即读一次当前 branch
        branchByPath[path] = GitUtils.currentBranch(at: path)
        // 启动 .git/HEAD 文件监控
        startMonitor(for: path)
    }

    /// 取消路径监控，引用计数 -1，归零时停止。
    func stopObserving(path: String) {
        guard let count = refCounts[path] else { return }
        if count <= 1 {
            refCounts.removeValue(forKey: path)
            sources.removeValue(forKey: path)?.cancel()
            branchByPath.removeValue(forKey: path)
        } else {
            refCounts[path] = count - 1
        }
    }

    /// 批量同步：传入当前需要的路径集合，自动增删监控。
    func sync(paths: Set<String>) {
        let current = Set(sources.keys)
        for path in paths.subtracting(current) { observe(path: path) }
        for path in current.subtracting(paths) {
            // 直接移除（不走引用计数递减）
            refCounts.removeValue(forKey: path)
            sources.removeValue(forKey: path)?.cancel()
            branchByPath.removeValue(forKey: path)
        }
    }

    /// 查询指定路径的当前分支。
    func branch(for path: String) -> String? {
        branchByPath[path]
    }

    // MARK: - Private

    private func startMonitor(for path: String) {
        let headPath = resolveHeadPath(at: path)
        guard let headPath else { return }

        let fd = open(headPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let newBranch = GitUtils.currentBranch(at: path)
            Task { @MainActor [weak self] in
                self?.branchByPath[path] = newBranch
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        sources[path] = source
    }

    /// 解析 .git/HEAD 的实际路径（处理 worktree 场景）。
    private func resolveHeadPath(at directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }

        if isDir.boolValue {
            return (gitPath as NSString).appendingPathComponent("HEAD")
        }

        // Worktree: .git 是文件，内容为 "gitdir: /path/to/.git/worktrees/xxx"
        guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              content.hasPrefix("gitdir: ") else { return nil }
        let gitdir = String(content.dropFirst("gitdir: ".count))
        let resolved = gitdir.hasPrefix("/") ? gitdir : (directory as NSString).appendingPathComponent(gitdir)
        return (resolved as NSString).appendingPathComponent("HEAD")
    }
}
