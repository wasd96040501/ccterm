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
    @Environment(SessionManager2.self) private var manager

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
            // Don't regenerate when already set — preserves the user's unsent draft.
            if selectedSessionId == SidebarView2.newSessionTag, draftSessionId == nil {
                draftSessionId = UUID().uuidString.lowercased()
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedSessionId == SidebarView2.transcriptDemoTag {
            TranscriptDemoView()
        } else if selectedSessionId == SidebarView2.transcriptStressTag {
            TranscriptStressView()
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
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color(nsColor: .windowBackgroundColor).opacity(0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.topFadeScrimHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
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
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0),
                            Color(nsColor: .windowBackgroundColor),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 160)
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
                                    RoundedRectangle(cornerRadius: InputBarView2.cornerRadius)
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
                .overlay(alignment: .bottom) {
                    // Width: minimum follows NativeTranscript2's content
                    // band; maximum sits 80pt narrower than the transcript
                    // (624 → 544) so the bar visibly recesses from the
                    // text column instead of feeling like another block.
                    // `InputBarView2` reports two frames — attach button
                    // and pill — in detail coord space; the scrim cuts
                    // two independent holes from them.
                    InputBarChrome(
                        sessionId: sid,
                        coordSpace: Self.detailCoordSpace,
                        onSubmit: { submission in submit(submission, sessionId: sid) },
                        onAttachRect: { rect in attachRect = rect },
                        onPillRect: { rect in pillRect = rect }
                    )
                    .frame(
                        minWidth: BlockStyle.minLayoutWidth,
                        maxWidth: 544
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 36)
                }
                .coordinateSpace(name: Self.detailCoordSpace)
                .ignoresSafeArea(edges: .top)
        } else {
            Color.clear
        }
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
    /// message (draft launch), set a default cwd and flip selection from
    /// `newSessionTag` to the concrete sessionId; subsequent messages take the
    /// same branch and forward directly to the handle.
    ///
    /// Image-bearing submissions take the `send(image:mediaType:caption:)`
    /// route; text-only submissions take `send(text:)`. The caption is the
    /// trimmed text when both are present, otherwise the default `[image]`
    /// label from the handle.
    private func submit(_ submission: InputBarView2.Submission, sessionId: String) {
        let handle = manager.prepareDraft(sessionId)
        let isFirstStart = !handle.hasRecord
        if isFirstStart {
            // Fresh draft has no cwd fallback — user hasn't picked a directory.
            // Default to home so CLI `Process.run()`'s chdir always succeeds.
            // (Previously hardcoded to ~/dev, which launchFailed on machines
            // lacking that directory and dragged subsequent resumes down with it.)
            handle.setCwd(FileManager.default.homeDirectoryForCurrentUser.path)
        }
        if let image = submission.image {
            let caption = submission.text.isEmpty ? nil : submission.text
            handle.send(image: image.data, mediaType: image.mediaType, caption: caption)
        } else {
            handle.send(text: submission.text)
        }
        if isFirstStart {
            manager.refreshRecords()
            selectedSessionId = sessionId
            draftSessionId = nil
        }
    }
}

// MARK: - InputBarChrome

/// Input bar chrome: LoadingPill (running) stacked above InputBarView2.
///
/// Owns the source of truth for `SessionHandle2.isRunning`, shared by the pill
/// visibility and the bar's send↔stop button toggle. The pill floats at the
/// bar's top-left via natural `VStack` layout; geometry reporting only reports
/// the bar itself, so the scrim hole isn't enlarged by the pill.
private struct InputBarChrome: View {
    let sessionId: String
    let coordSpace: String
    let onSubmit: (InputBarView2.Submission) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void

    @Environment(SessionManager2.self) private var manager
    @State private var handle: SessionHandle2?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if handle?.isRunning == true {
                LoadingPillView2()
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            InputBarView2(
                onSubmit: onSubmit,
                onStop: { handle?.interrupt() },
                isRunning: handle?.isRunning ?? false,
                coordSpace: coordSpace,
                onAttachRect: onAttachRect,
                onPillRect: onPillRect
            )
        }
        .animation(.smooth(duration: 0.25), value: handle?.isRunning ?? false)
        .task(id: sessionId) {
            // `prepareDraft` is idempotent get-or-create for both fresh and
            // historical sessions, returning the same handle instance that
            // ChatHistoryView holds. @Observable on `isRunning` drives
            // re-render automatically.
            handle = manager.prepareDraft(sessionId)
        }
    }
}
