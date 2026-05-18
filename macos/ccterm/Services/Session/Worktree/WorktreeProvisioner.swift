import Foundation

/// Runs the synchronous git work that `Worktree.create` does (fetch +
/// `git worktree add` + post-create extensions / hooks / file copies)
/// off the main thread and reports the outcome back as a `Result`.
///
/// Stateless: the handle owns its own `cwd` / `worktreeBranch` /
/// `status` writes — this type is just the I/O path. Pulled out of
/// `SessionHandle2+Start.swift` so the wrapping logic (nil origin →
/// notGitRepository, creator error → .failure) is testable without
/// firing a real git subprocess.
///
/// **Threading**: dispatches to `DispatchQueue.global(qos: .userInitiated)`
/// rather than `Task.detached`. The old code observed that
/// detached-task isolation inheritance still pinned the main actor for
/// the full duration of the git shell-outs — GCD has no such ambiguity.
/// See the original comment in `SessionHandle2.ensureStarted`.
enum WorktreeProvisioner {

    /// Underlying `git worktree add` call signature. Production wires
    /// `Worktree.create`; tests pass a closure that returns a canned
    /// `Worktree` or throws.
    typealias Creator =
        @Sendable (
            _ origin: String,
            _ sourceBranch: String?,
            _ preferredName: String
        ) throws -> Worktree

    /// Production creator — the real git invocation.
    static let defaultCreator: Creator = { origin, source, preferredName in
        try Worktree.create(
            from: origin,
            sourceBranch: source,
            preferredName: preferredName
        )
    }

    /// Provision a worktree off the main thread.
    ///
    /// - `origin == nil` short-circuits to `.failure(.notGitRepository)` —
    ///   the handle's worktree mode requires an originPath to fork from.
    /// - The `creator` runs on a background queue; the resulting
    ///   `Result` is returned to the awaiting (`@MainActor`) caller.
    /// - Anything thrown by `creator` is wrapped in `.failure(error)`.
    /// - Parameter creator: injection seam for tests. Production omits.
    static func provision(
        origin: String?,
        sourceBranch: String?,
        preferredName: String,
        creator: @escaping Creator = defaultCreator
    ) async -> Result<Worktree, Error> {
        await withCheckedContinuation {
            (cont: CheckedContinuation<Result<Worktree, Error>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let origin else {
                    cont.resume(
                        returning: .failure(
                            Worktree.Error.notGitRepository(path: "(nil originPath)")))
                    return
                }
                do {
                    let wt = try creator(origin, sourceBranch, preferredName)
                    cont.resume(returning: .success(wt))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }
    }
}
