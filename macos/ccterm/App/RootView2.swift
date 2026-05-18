import SwiftUI

/// Root view: Sidebar + read-only ChatHistoryView. Selection is held locally,
/// not in AppState or any router.
struct RootView2: View {
    static fileprivate let detailCoordSpace = "RootView2.detail"
    /// Height of the top fade-blur scrim covering the transcript's top edge.
    /// Fixed (not derived from `safeAreaInsets`) — the transcript runs flush
    /// to the window's top, and a constant fade range keeps the visual weight
    /// of the scrim consistent regardless of window height.
    fileprivate static let topFadeScrimHeight: CGFloat = 80
    /// Width clamp for the resting input bar in chat mode — keeps the
    /// bar visually recessed from the transcript column. Compose mode
    /// renders its own (wider) bar embedded inside the configurator
    /// card, so this constant applies to the chat-mode resting bar
    /// only.
    fileprivate static let composeMaxWidth: CGFloat = 544
    /// Bottom inset of the input bar in chat mode (matches the previous
    /// `.padding(.bottom, 36)`).
    fileprivate static let chatBottomInset: CGFloat = 36

    @State private var selectedSessionId: String? = SidebarView2.newSessionTag
    @State private var draftSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Frame of the round attach button, in `detailCoordSpace`. The
    /// bottom scrim cuts a *Circle* hole here.
    @State private var attachRect: CGRect = .zero
    /// Frame of the rounded-rectangle pill, in `detailCoordSpace`. The
    /// bottom scrim cuts a *RoundedRectangle* hole here. Reported
    /// separately from `attachRect` so the 8pt gap between attach and
    /// pill is NOT cut — the gradient bridges them naturally there.
    @State private var pillRect: CGRect = .zero
    /// User-selected source folder for the draft. Becomes the handle's
    /// `originPath` (and `cwd` when not worktree). nil → home fallback at
    /// submit, matching the legacy behavior.
    @State private var draftCwd: String?
    /// Compose-time toggle for worktree provisioning. Ignored when the
    /// chosen folder isn't a git repo (NewSessionConfigurator disables it).
    @State private var draftUseWorktree: Bool = false
    /// Source branch fed into `Worktree.create`'s `sourceBranch` argument.
    /// nil → repo's current branch (Worktree falls back to detached check).
    @State private var draftSourceBranch: String?
    @Environment(SessionManager.self) private var manager
    @Environment(RecentProjectsStore.self) private var recents
    /// Compose mode is "the New Session tab is selected." Once `submit`
    /// flips `selectedSessionId` to the concrete draft UUID, this turns
    /// false and the animated layout settles the input bar at the
    /// detail-pane bottom.
    private var isComposeMode: Bool {
        selectedSessionId == SidebarView2.newSessionTag
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView2(selection: $selectedSessionId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            detailContent
                .frame(minWidth: 400)
        }
        .frame(minWidth: 800, minHeight: 480)
        .alert(
            "Failed to launch CLI",
            isPresented: Binding(
                get: { manager.lastLaunchFailure != nil },
                set: { if !$0 { manager.clearLaunchFailure() } }
            ),
            presenting: manager.lastLaunchFailure
        ) { _ in
            Button("OK", role: .cancel) { manager.clearLaunchFailure() }
        } message: { failure in
            Text(failure.message)
        }
        .task(id: selectedSessionId) {
            // Lazily allocate draftSessionId on entering the NewSession tab.
            // Don't regenerate when already set — preserves the user's unsent draft
            // (text, attachment, and the compose-card config below).
            if selectedSessionId == SidebarView2.newSessionTag, draftSessionId == nil {
                draftSessionId = UUID().uuidString.lowercased()
                // Pre-fill with the last successfully launched project so a
                // fresh draft is one click away from sending. The store
                // validates `lastLaunchedPath` against disk on load, so a
                // deleted folder won't survive the cold start; if the path
                // disappeared mid-session, NewSessionConfigurator's git
                // probe drops it again.
                draftCwd = recents.lastLaunchedPath
                draftUseWorktree = draftCwd.flatMap { recents.useWorktree(for: $0) } ?? false
                draftSourceBranch = nil
            }
        }
        .onChange(of: selectedSessionId, initial: false) { oldValue, newValue in
            // The sidebar's only signal for "session viewed" is selection.
            // Drop focus on the previous session and acquire it on the new
            // one so `Session.setFocused(true)` clears `hasUnread` (the
            // blue dot in the sidebar status slot).
            if let old = oldValue, let prev = manager.existingSession(old) {
                prev.setFocused(false)
            }
            if let new = newValue, let next = manager.session(new) {
                next.setFocused(true)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedSessionId == SidebarView2.transcriptDemoTag {
            TranscriptDemoView()
        } else if selectedSessionId == SidebarView2.transcriptStressTag {
            TranscriptStressView()
        } else if selectedSessionId == SidebarView2.archiveTag {
            // Unarchive bounces the selection to the restored session so
            // the user lands on the chat history they brought back. The
            // record state has already flipped to `.created` inside
            // `manager.unarchive`, so the regular `effectiveSessionId`
            // path picks it up.
            ArchiveView(onUnarchive: { sid in
                withAnimation(.smooth(duration: 0.25)) {
                    selectedSessionId = sid
                }
            })
        } else if let sid = effectiveSessionId {
            // `.id(sid)` pins ChatHistoryView identity across the NewSession →
            // History transition: sid is stable (the draft UUID becomes the
            // history sessionId after the first send), so SwiftUI doesn't
            // rebuild the NSView. The bottom InputBarView2 plays both the
            // "draft launcher" and "history continuation" roles — its
            // onSubmit closure branches on `handle.hasRecord` to trigger the
            // first-start side effects only when needed.
            ChatHistoryView(sessionId: sid)
                .id(sid)
                .overlay(alignment: .top) {
                    // Top fade scrim, mirror of the bottom one: same
                    // windowBackgroundColor LinearGradient, direction
                    // reversed (opaque at top → clear 80pt down). The
                    // transcript runs flush to the window's top edge (no
                    // contentInsets.top), so this softens the seam between
                    // window chrome and the first visible row.
                    FadeScrim(.topToBottom, height: Self.topFadeScrimHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .overlay(alignment: .bottom) {
                    // Fade scrim: a standalone gradient at the detail pane
                    // bottom, z-ordered above the transcript and below the
                    // input bar. Two holes are cut — a Circle for the
                    // attach button and a RoundedRectangle for the pill —
                    // so each control's glass/material refracts the
                    // transcript directly. The 8pt gap between attach and
                    // pill is intentionally NOT cut, so the scrim's
                    // gradient bridges them rather than leaving a
                    // hard-edged slot.
                    FadeScrim(.bottomToTop, height: 160)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .mask {
                            Color.white
                                .overlay {
                                    if attachRect != .zero {
                                        Circle()
                                            .fill(.black)
                                            .frame(width: attachRect.width, height: attachRect.height)
                                            .position(x: attachRect.midX, y: attachRect.midY)
                                            .blendMode(.destinationOut)
                                    }
                                    if pillRect != .zero {
                                        RoundedRectangle(cornerRadius: InputBarView2.cornerRadius, style: .continuous)
                                            .fill(.black)
                                            .frame(width: pillRect.width, height: pillRect.height)
                                            .position(x: pillRect.midX, y: pillRect.midY)
                                            .blendMode(.destinationOut)
                                    }
                                }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                }
                .overlay {
                    // Compose card sits centered in the detail pane, the
                    // input bar is pinned to the same bottom resting
                    // position used in chat mode. Splitting them keeps the
                    // bar's structural identity AND its layout position
                    // stable across the New Session → started-session
                    // transition; only the centered card fades in/out.
                    composeStack(sid: sid)
                }
                .coordinateSpace(name: Self.detailCoordSpace)
                .ignoresSafeArea(edges: .top)
        } else {
            Color.clear
        }
    }

    /// Compose mode embeds the input bar inside the configurator's
    /// right column, so the bar reads as part of the card surface
    /// instead of a floating control 100+ pt below it. Chat mode keeps
    /// the resting bar bottom-anchored as before. The two branches
    /// construct distinct `InputBarChrome` instances by design — the
    /// mode flip happens once per session (on first send), text and
    /// attachments are cleared on send, so there is no state to carry
    /// across the boundary. The compose-mode bar passes no-op rect
    /// callbacks (there is no transcript scrim to cut holes in).
    @ViewBuilder
    private func composeStack(sid: String) -> some View {
        ZStack {
            if isComposeMode {
                NewSessionConfigurator(
                    folderPath: $draftCwd,
                    useWorktree: $draftUseWorktree,
                    sourceBranch: $draftSourceBranch,
                    onResumeSession: { resumeSessionId in
                        // Mirror `submit(...)`'s success path: animate the
                        // compose card out via `isComposeMode`, then drop
                        // the draft id so re-entering New Session next
                        // time starts fresh.
                        withAnimation(.smooth(duration: 0.42)) {
                            selectedSessionId = resumeSessionId
                            draftSessionId = nil
                        }
                    },
                    inputBar: {
                        InputBarChrome(
                            sessionId: sid,
                            coordSpace: Self.detailCoordSpace,
                            // Compose mode requires a picked folder before send
                            // arms; chat mode never gates on this.
                            submitEnabled: draftCwd != nil,
                            onSubmit: { submission in submit(submission, sessionId: sid) },
                            onAttachRect: { _ in },
                            onPillRect: { _ in }
                        )
                    }
                )
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    InputBarChrome(
                        sessionId: sid,
                        coordSpace: Self.detailCoordSpace,
                        submitEnabled: true,
                        onSubmit: { submission in submit(submission, sessionId: sid) },
                        onAttachRect: { rect in attachRect = rect },
                        onPillRect: { rect in pillRect = rect }
                    )
                    .frame(
                        minWidth: BlockStyle.minLayoutWidth,
                        maxWidth: Self.composeMaxWidth
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, Self.chatBottomInset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.42), value: isComposeMode)
    }

    /// The currently displayed sessionId, derived from the tab + draft.
    private var effectiveSessionId: String? {
        if selectedSessionId == SidebarView2.newSessionTag {
            return draftSessionId
        }
        return selectedSessionId
    }

    /// Input bar send callback. `prepareDraft` is get-or-create even for an
    /// existing record — draft and history follow the same path. On the first
    /// message (draft launch), apply the user-picked configurator state
    /// (origin path / cwd / worktree flag / source branch) before
    /// `ensureStarted` runs; on subsequent messages, take the same branch
    /// and forward directly to the handle.
    ///
    /// Image-bearing submissions take the `send(image:mediaType:caption:)`
    /// route; text-only submissions take `send(text:)`. The caption is the
    /// trimmed text when both are present, otherwise the default `[image]`
    /// label from the handle.
    private func submit(_ submission: InputBarView2.Submission, sessionId: String) {
        let session = manager.prepareDraftSession(sessionId)
        let isFirstStart = !session.hasRecord
        if isFirstStart {
            // Fresh draft picks up the compose card's choices. Falls back
            // to home so `Process.run()`'s chdir always succeeds when the
            // user submits without picking a folder. Worktree provisioning
            // reads `originPath` and `sourceBranch` inside `ensureStarted`'s
            // fresh path. The draft-only setters live on `SessionDraft`,
            // reached through the façade's `draft` accessor — non-nil
            // while the session is still in `.draft` phase, which it is
            // until the first `send(...)` below triggers promotion.
            let chosen = draftCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            if let draft = session.draft {
                draft.setOriginPath(chosen)
                draft.setCwd(chosen)
                draft.setWorktree(draftUseWorktree)
                if draftUseWorktree {
                    draft.setSourceBranch(draftSourceBranch)
                }
            }
            // Surface the project in next session's recents list and
            // remember it as the default for the next New Session card.
            // Only when the user explicitly picked a folder — home
            // fallback isn't a "project".
            if let picked = draftCwd {
                recents.markLaunched(picked, useWorktree: draftUseWorktree)
            }
        }
        if let image = submission.image {
            let caption = submission.text.isEmpty ? nil : submission.text
            session.send(image: image.data, mediaType: image.mediaType, caption: caption)
        } else {
            session.send(text: submission.text)
        }
        if isFirstStart {
            manager.refreshRecords()
            // `withAnimation` so the compose-mode flip drives the same
            // `composeStack`'s `.animation(value: isComposeMode)` channel,
            // making the configurator fade and the bar settle in one
            // visible motion.
            withAnimation(.smooth(duration: 0.42)) {
                selectedSessionId = sessionId
                draftSessionId = nil
            }
        }
    }
}

// MARK: - InputBarChrome

/// Per-session wrapper around `InputBarView2`. Resolves the
/// `Session` so the bar can read `isRunning` (send↔stop swap)
/// and call `interrupt()`, and hosts the session-scoped chrome row
/// (`InputBarSessionChrome`) directly below the bar — kept *outside*
/// the pill so the bar itself stays "pure UI" and the chrome row can
/// align its left/right edges with the bar (attach button on the left,
/// pill's trailing edge on the right). The running indicator now lives
/// at the tail of the transcript (`Transcript2Controller.setLoading`).
private struct InputBarChrome: View {
    let sessionId: String
    let coordSpace: String
    let submitEnabled: Bool
    let onSubmit: (InputBarView2.Submission) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void

    @Environment(SessionManager.self) private var manager

    /// Resolved synchronously per render. `prepareDraftSession` is
    /// idempotent get-or-create (pure in-memory), and returns the same
    /// instance `ChatHistoryView` holds. Caching it in `@State` +
    /// `.task(id:)` caused a one-frame gap on session switch — the
    /// chrome row was absent until the task fired, so it visibly popped
    /// in. With a computed property the chrome is present on the first
    /// frame.
    private var session: Session {
        manager.prepareDraftSession(sessionId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InputBarSessionChrome.barSpacing) {
            InputBarView2(
                onSubmit: onSubmit,
                onStop: { session.interrupt() },
                isRunning: session.isRunning,
                submitEnabled: submitEnabled,
                coordSpace: coordSpace,
                onAttachRect: onAttachRect,
                onPillRect: onPillRect
            )
            InputBarSessionChrome(session: session)
        }
    }
}
