import Foundation
import AgentSDK

final class TodoSessionCoordinator {

    // MARK: - Properties

    private let todoService: TodoService
    private let sessionService: SessionService

    // MARK: - Lifecycle

    init(todoService: TodoService, sessionService: SessionService) {
        self.todoService = todoService
        self.sessionService = sessionService
    }

    // MARK: - Worktree Creation

    /// Creates a worktree and starts a session for the given todo item.
    func startTodoSession(for todoItem: TodoItem) {
        let todoId = todoItem.id
        let uuid = todoId.uuidString
        let title = todoItem.title

        guard let metadata = todoItem.metadata, !metadata.paths.isEmpty else {
            NSLog("[TodoSessionCoordinator] No paths in metadata for todo %@", uuid)
            return
        }

        let baseBranch = metadata.gitBranch ?? "main"
        let branchName = "todo/\(uuid)"

        // Move worktree creation off main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Worktree base path: ~/.local/share/ccterm/todo/{uuid}/
            let basePath = NSString(string: "~/.local/share/ccterm/todo/\(uuid)")
                .expandingTildeInPath

            try? FileManager.default.createDirectory(
                atPath: basePath,
                withIntermediateDirectories: true
            )

            // Create worktree for each path
            var worktreePaths: [String] = []
            for path in metadata.paths {
                let projectName = (path as NSString).lastPathComponent
                let worktreePath = (basePath as NSString).appendingPathComponent(projectName)

                let result = GitUtils.createWorktree(
                    repoPath: path,
                    worktreePath: worktreePath,
                    branch: branchName,
                    baseBranch: baseBranch
                )

                if result {
                    worktreePaths.append(worktreePath)
                } else {
                    NSLog("[TodoSessionCoordinator] Failed to create worktree at %@", worktreePath)
                }
            }

            guard let primaryPath = worktreePaths.first else {
                NSLog("[TodoSessionCoordinator] No worktrees created for todo %@", uuid)
                try? FileManager.default.removeItem(atPath: basePath)
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.todoService.updateWorktreeBranch(branchName, for: todoId)

                let addDirs = Array(worktreePaths.dropFirst())
                let config = SessionConfig(
                    originPath: primaryPath,
                    isWorktree: false, // worktree already created manually
                    pluginDirs: metadata.pluginDirs,
                    additionalDirs: addDirs.isEmpty ? nil : addDirs,
                    permissionMode: .default
                )

                let prompt = self.buildPreprocessingPrompt(
                    title: title,
                    worktreePath: primaryPath,
                    baseBranch: baseBranch
                )

                Task {
                    do {
                        let handle = try await self.sessionService.start(config: config)
                        self.todoService.updateSessionId(handle.sessionId, for: todoId)
                        self.sessionService.updateSessionType(handle.sessionId, type: .todo, linkedTodoId: todoId.uuidString)
                        handle.send(.text(prompt))
                    } catch {
                        NSLog("[TodoSessionCoordinator] Failed to start session: %@", "\(error)")
                    }
                }
            }
        }
    }

    // MARK: - State Writeback

    /// Called from ChatSessionViewModel event handler to sync session state to TodoItem.
    func handleStateChange(needsAttention: Bool, for sessionId: String) {
        guard let todo = todoService.todo(forSessionId: sessionId) else { return }
        if todo.status == .pending && needsAttention {
            todoService.markNeedsConfirmation(id: todo.id)
        }
    }

    /// Called when the user sends a message in a todo session.
    func handleUserMessage(for sessionId: String) {
        guard let todo = todoService.todo(forSessionId: sessionId) else { return }
        if todo.status == .needsConfirmation {
            todoService.markInProgress(id: todo.id)
        }
    }

    /// Marks a todo as completed by session ID.
    func markComplete(sessionId: String) {
        guard let todo = todoService.todo(forSessionId: sessionId) else { return }

        if todo.type == .merge {
            completeMerge(mergeSessionId: sessionId)
        } else if todo.status == .inProgress {
            todoService.markCompleted(id: todo.id)
        }
    }

    /// Marks a todo as completed by todo ID.
    func markComplete(todoId: UUID) {
        todoService.markCompleted(id: todoId)
    }

    // MARK: - Worktree Cleanup

    func cleanupWorktree(for todoItem: TodoItem) {
        let uuid = todoItem.id.uuidString
        let basePath = NSString(string: "~/.local/share/ccterm/todo/\(uuid)")
            .expandingTildeInPath

        guard let metadata = todoItem.metadata else { return }

        for path in metadata.paths {
            let projectName = (path as NSString).lastPathComponent
            let worktreePath = (basePath as NSString).appendingPathComponent(projectName)
            GitUtils.removeWorktree(repoPath: path, worktreePath: worktreePath)
        }

        if let branch = todoItem.worktreeBranch {
            for path in metadata.paths {
                GitUtils.deleteBranch(at: path, branch: branch)
            }
        }

        try? FileManager.default.removeItem(atPath: basePath)
    }

    // MARK: - Merge Session

    @discardableResult
    func startMergeSession(todoIds: [UUID], targetBranch: String) async -> String? {
        let items = todoIds.compactMap { todoService.todo(forId: $0) }
        guard !items.isEmpty else { return nil }

        let mergeTitle = "Merge \(items.count) tasks into \(targetBranch)"
        let mergeTodo = todoService.createTodo(
            title: mergeTitle,
            type: .merge
        )
        todoService.updateMergedItemIds(todoIds.map(\.uuidString), for: mergeTodo.id)

        let cwd = items.first?.metadata?.paths.first ?? FileManager.default.currentDirectoryPath
        let config = SessionConfig(
            originPath: cwd,
            isWorktree: false,
            pluginDirs: nil,
            additionalDirs: nil,
            permissionMode: .default
        )

        let prompt = buildMergePrompt(items: items, targetBranch: targetBranch)

        do {
            let handle = try await sessionService.start(config: config)
            todoService.updateSessionId(handle.sessionId, for: mergeTodo.id)
            sessionService.updateSessionType(handle.sessionId, type: .todo, linkedTodoId: mergeTodo.id.uuidString)
            todoService.markInProgress(id: mergeTodo.id)
            handle.send(.text(prompt))
            return handle.sessionId
        } catch {
            NSLog("[TodoSessionCoordinator] Merge session failed: %@", "\(error)")
            return nil
        }
    }

    // MARK: - Post-Merge

    func completeMerge(mergeSessionId: String) {
        guard let mergeTodo = todoService.todo(forSessionId: mergeSessionId),
              let mergedIds = mergeTodo.mergedItemIds else { return }

        for idString in mergedIds {
            guard let uuid = UUID(uuidString: idString) else { continue }
            todoService.markMerged(id: uuid)

            if let item = todoService.todo(forId: uuid) {
                cleanupWorktree(for: item)
            }
        }

        todoService.markMerged(id: mergeTodo.id)
    }

    // MARK: - Private Methods

    private func buildPreprocessingPrompt(title: String, worktreePath: String, baseBranch: String) -> String {
        """
        You are acting as a task preprocessor. Your job is to refine and clarify a development task before execution begins.

        The user has submitted the following task:

        ---
        \(title)
        ---

        Working directory: \(worktreePath)
        Base branch: \(baseBranch)

        Please do the following:
        1. Read the relevant code in the working directory to understand the current state
        2. Rewrite the task description in precise, unambiguous technical language, referencing specific files, functions, or modules where applicable
        3. If the task is unclear or missing critical details, list your questions clearly and wait for the user to respond before proceeding
        4. If the task is clear, present your refined description and ask the user to confirm before you begin implementation

        Important:
        - Respond in the same language as the user's task description
        - Do NOT start implementing yet -- this is a planning and clarification phase only
        - Be concise and specific
        """
    }

    private func buildMergePrompt(items: [TodoItem], targetBranch: String) -> String {
        let branchList = items.map { "- \($0.worktreeBranch ?? "unknown"): \($0.title)" }.joined(separator: "\n")

        return """
        You are acting as a git merge operator. Your job is to merge completed feature branches into the target branch.

        Target branch: \(targetBranch)
        Branches to merge (in order):
        \(branchList)

        Please do the following:
        1. For each branch, merge it into the target branch
        2. If there are merge conflicts, attempt to resolve them automatically based on the intent of each branch's changes
        3. If you cannot resolve a conflict automatically, describe the conflict clearly and ask the user for guidance
        4. After all merges are complete, summarize what was merged and any issues encountered

        Important:
        - Respond in the same language as the task descriptions
        - Merge branches one at a time, committing each before proceeding to the next
        - If a merge fails and cannot be resolved, stop and report -- do not skip it
        """
    }
}
