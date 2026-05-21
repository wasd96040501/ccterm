import AgentSDK
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
    /// bar visually recessed from the transcript column (which caps at
    /// `BlockStyle.maxLayoutWidth = 780`). Sits below
    /// `NewSessionConfigurator.minWidth` (640) so the chat-mode bar
    /// reads as a more compact control than the compose card. Compose
    /// mode renders its own bar embedded inside the configurator card.
    fileprivate static let composeMaxWidth: CGFloat = 512
    /// Bottom inset of the input bar in chat mode (matches the previous
    /// `.padding(.bottom, 36)`).
    fileprivate static let chatBottomInset: CGFloat = 36
    /// Breathing room between the compose card / input bar and the
    /// detail pane's left/right edges. Matched on the chat-mode bar
    /// (`.padding(.horizontal, 20)` below) so neither layout reads
    /// "flush" against the sidebar divider or the window's right edge.
    fileprivate static let detailHorizontalInset: CGFloat = 20
    /// Breathing room above and below the compose card so it doesn't
    /// butt against the window's top chrome or the bottom edge of the
    /// detail pane at the smallest allowed window height.
    fileprivate static let detailVerticalInset: CGFloat = 20

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
    @Environment(NotificationService.self) private var notifications
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
            // `.frame(minWidth:)` on the detail *content* only constrains the
            // content itself — NavigationSplitView keeps allocating whatever
            // width it likes to the detail column. The only knob that actually
            // pins the column's own minimum (and, with the app scene's
            // `.windowResizability(.contentSize)`, propagates up to the
            // window's minimum size) is `navigationSplitViewColumnWidth`.
            //
            // The min/ideal here = the compose card's own min/ideal
            // (640 / 960 from `NewSessionConfigurator`) + the
            // `detailHorizontalInset` on each side. The extra 40pt
            // keeps the card from going flush against the sidebar
            // divider or the window's right edge even at the smallest
            // allowed window width.
            detailContent
                .navigationSplitViewColumnWidth(min: 680, ideal: 1000)
        }
        // The compose card lives in `ChatHistoryView`'s `.overlay { }`
        // — overlays match the underlying view's size, so the card's
        // intrinsic height (620) + `detailVerticalInset × 2` (40) is
        // NOT propagated up to the window content size. Pin the
        // SplitView's own `minHeight` to that total here so the
        // scene's `.windowResizability(.contentSize)` sees the right
        // floor and stops shrinking before the card touches an edge.
        .frame(
            minHeight: NewSessionConfigurator<EmptyView>.height
                + Self.detailVerticalInset * 2
        )
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
        // Wake the notification subsystem up exactly once on the
        // main-window mount. `bootstrap()` is internally guarded
        // against re-entry — re-mounting the root view is a no-op.
        .task {
            notifications.bootstrap()
        }
        // Compose-mode folder pick → draft.cwd. Done eagerly (not at
        // submit time) so `Session.cwd` reflects the configurator's
        // choice immediately — that's what the input bar's prewarm
        // task keys off, and what completion's trigger context reads.
        // The submit path still calls `setCwd` itself (with a home
        // fallback), so this is a no-op overwrite there.
        .task(id: draftCwd) {
            guard isComposeMode,
                let sid = draftSessionId,
                let cwd = draftCwd
            else { return }
            manager.prepareDraftSession(sid).draft?.setCwd(cwd)
        }
        // The user tapped a banner. Pull the corresponding session into
        // view and clear the request so a re-tap on the same id refires.
        .onChange(of: notifications.pendingActivationSessionId, initial: false) {
            _, newValue in
            guard let sid = newValue else { return }
            selectedSessionId = sid
            notifications.clearPendingActivation()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        #if DEBUG
        if selectedSessionId == SidebarView2.transcriptDemoTag {
            TranscriptDemoView()
        } else if selectedSessionId == SidebarView2.transcriptStressTag {
            TranscriptStressView()
        } else if selectedSessionId == SidebarView2.transcriptPerfTag {
            TranscriptPerfDemoView()
        } else if selectedSessionId == SidebarView2.permissionCardsDemoTag {
            PermissionCardsDemoView()
        } else {
            detailContentReleaseBranches
        }
        #else
        detailContentReleaseBranches
        #endif
    }

    @ViewBuilder
    private var detailContentReleaseBranches: some View {
        if selectedSessionId == SidebarView2.archiveTag {
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
            // `showsSearch` is off in compose mode (New Session tab): the
            // transcript sits as an unseen backdrop under the configurator
            // card, so a live search field in the window toolbar would
            // read as out-of-place chrome.
            ChatHistoryView(sessionId: sid, showsSearch: !isComposeMode)
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
                // Compose-mode backdrop: an ultra-faint dot grid over
                // the default windowBackgroundColor gives the otherwise
                // dead space a hint of structure. The card itself
                // (rendered on top) carries its own near-imperceptible
                // dot layer so the texture appears to *continue
                // through* the translucent material, reinforcing the
                // "floating panel" read rather than "window inside a
                // window."
                ZStack {
                    DotGridBackground()
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
                                // Compose mode shares one draft slot regardless of
                                // the lazily-allocated `draftSessionId` — that UUID
                                // gets regenerated on every fresh entry to the
                                // New Session tab, so keying drafts on it would
                                // lose the body across restarts.
                                draftKey: InputDraftStore.newSessionKey,
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
                    .padding(.horizontal, Self.detailHorizontalInset)
                    .padding(.vertical, Self.detailVerticalInset)
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    InputBarChrome(
                        sessionId: sid,
                        draftKey: sid,
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
                    .padding(.horizontal, Self.detailHorizontalInset)
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
    /// Attachment dispatch:
    /// - File paths are joined as `@"<absolute path>"` mentions and
    ///   spliced in front of the user's text. The quoted form is the
    ///   contract the CLI's `extractAtMentionedFiles` parser expects for
    ///   paths with spaces — the unquoted form truncates at the first
    ///   whitespace (so any path under `/Users/<First Last>/…` would be
    ///   silently mangled). Single-space separator between mentions and
    ///   the user's text follows the same convention as the bridge's
    ///   `resolveInboundAttachments`.
    /// - If there are no images, the composed body goes through
    ///   `send(text:)` as a single message.
    /// - With images, each image goes through `send(image:mediaType:caption:)`.
    ///   The first image carries the composed body as its caption; the
    ///   rest are sent caption-less (the runtime's default `[image]`
    ///   label kicks in) so the body isn't repeated. `LocalUserInput`
    ///   only carries one image per message, so multi-image sends fan
    ///   out into multiple `send(image:)` calls preserving drop order.
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
            // Single user message carrying caption + all images as a
            // content array — matches the JSONL wire shape (one entry
            // can have N base64 image blocks).
            session.send(
                images: submission.images,
                caption: composedBody.isEmpty ? nil : composedBody
            )
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
    let draftKey: String
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

    /// Cache key for the prewarm task. SwiftUI re-fires the `.task` only
    /// when this value changes, so it ends up firing once per (cwd /
    /// addDirs / pluginDirs) combination — both on the initial entry
    /// into the session and on every folder switch.
    private var prewarmKey: CompletionPrewarmer.Key {
        CompletionPrewarmer.Key(
            directory: session.cwd,
            additionalDirs: session.additionalDirectories,
            pluginDirs: session.pluginDirectories
        )
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
                onPillRect: onPillRect,
                directory: session.cwd,
                additionalDirs: session.additionalDirectories,
                pluginDirs: session.pluginDirectories,
                // Chat-mode passes the live list so the rule short-circuits
                // the temp-CLI fetch. Compose-mode leaves the array empty
                // until promotion — that's the signal for `nil` here,
                // routing through the prewarmed store cache instead.
                knownSlashCommands: session.hasRecord ? session.slashCommands : nil,
                draftKey: draftKey
            )
            InputBarSessionChrome(session: session)
        }
        // Single async-prewarm convergence point. Mirrors the
        // `GitProbe.loadHeavy` pattern used by the branch picker: kicks
        // off the background loads as soon as we know the cwd, both on
        // session entry and on every folder switch. The prewarmer fans
        // out into the file-index and slash-command stores; both back
        // their state with a serial queue so any `complete(...)` call
        // that lands before warm finishes blocks behind it.
        .task(id: prewarmKey) {
            CompletionPrewarmer.prewarm(prewarmKey)
        }
        // Permission card floats on top of the bar+chrome stack:
        // bottom-aligned with the chrome row, width pinned to this
        // VStack (which spans attach `+` → pill trailing edge), and
        // z-ordered above the input bar by virtue of being an overlay.
        // Each button forwards through `Session.respond(to:decision:)`,
        // which routes to `SessionRuntime.respond` → the per-request
        // closure that completes the CLI's awaiting promise and pops
        // the entry off `pendingPermissions`. `allowAlways` reuses the
        // request's CLI-supplied `permissionSuggestions` so the rule
        // matches what the agent itself proposed.
        .overlay(alignment: .bottom) {
            if let pending = session.pendingPermissions.first {
                PermissionCardView(
                    request: pending.request,
                    onAllowOnce: { session.respond(to: pending.id, decision: pending.request.allowOnce()) },
                    onAllowAlways: {
                        session.respond(to: pending.id, decision: pending.request.allowAlways())
                    },
                    onDeny: { session.respond(to: pending.id, decision: pending.request.deny()) },
                    onAllowWithInput: { updated in
                        session.respond(
                            to: pending.id,
                            decision: pending.request.allowOnce(updatedInput: updated))
                    }
                )
                .transition(
                    .scale(scale: 0.96, anchor: .bottom)
                        .combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: session.pendingPermissions.first?.id)
    }
}
