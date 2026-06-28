import AppKit

/// Shared "user pressed send" handler for the two view controllers that
/// own a send button:
///
/// - `ComposeSessionViewController` — the New Session compose card. The
///   session is still a draft, so `isFirstStart` is true: the draft is
///   promoted to a real session and the selection flips to `.session(_)`.
/// - `ChatSessionViewController` — the chat resting bar. The session is
///   already active, so this is a plain `send`.
///
/// Kept in one place (rather than duplicated on each VC) so the compose
/// and chat send paths can't drift. Logic is identical to the pre-split
/// `ChatSessionViewController.submit`.
@MainActor
func submitSessionInput(
    _ submission: Submission,
    sessionId: String,
    sessionManager: SessionManager,
    recentProjects: RecentProjectsStore,
    model: MainSelectionModel
) {
    let session = sessionManager.prepareDraftSession(sessionId)
    let isFirstStart = !session.hasRecord
    if isFirstStart {
        // The configurator's bindings have already written cwd /
        // originPath / useWorktree / sourceBranch onto `session.draft`,
        // so promotion picks them up verbatim. Only the `recentProjects`
        // bookkeeping and the home-fallback for users who somehow submit
        // with no folder picked live here.
        if session.cwd == nil, let draft = session.draft {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            draft.setCwd(home)
            draft.setOriginPath(home)
        }
        if let picked = session.originPath {
            recentProjects.markLaunched(picked, useWorktree: session.isWorktree)
        }
    }
    let mentions = submission.filePaths.map { "@\"\($0)\"" }.joined(separator: " ")
    let composedBody: String = {
        switch (mentions.isEmpty, submission.text.isEmpty) {
        case (true, _): return submission.text
        case (false, true): return mentions
        case (false, false): return mentions + " " + submission.text
        }
    }()
    if submission.images.isEmpty {
        session.send(text: composedBody)
    } else {
        session.send(
            images: submission.images,
            caption: composedBody.isEmpty ? nil : composedBody
        )
    }
    if isFirstStart {
        sessionManager.refreshRecords()
        // `promote` (not `select`) so a draft that's ALREADY the current
        // selection — a `/new` / `/clear` sidebar draft viewed on the
        // draft-landing page — still re-routes: its phase just flipped
        // `.draft → .active`, but the selection VALUE is unchanged, so a
        // plain `select` would no-op and the live transcript would never
        // mount. For the compose card (selection was `.newSession`) this is
        // a normal cross-kind transition and `promote` delegates to `select`.
        model.promote(to: sessionId)
        model.draftSessionId = nil
    }
}
