import SwiftUI

/// 会话行。有独立 @State isHovered，提取为独立文件。
struct SidebarSessionRow: View {
    let session: SidebarSession
    let style: SessionRowStyle
    let viewModel: SidebarViewModel

    @Environment(SessionManager2.self) private var manager
    @Environment(\.markdownTheme) private var markdownTheme

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            leadingIndicator
            titleAndSubtitle
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                hoverButtonsContent
            }
            .opacity(isHovered ? 1 : 0)
            .frame(width: isHovered ? nil : 0)
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                prewarm()
            }
        }
        .contextMenu { contextMenuItems }
    }

    /// Hover prewarm — 把目标 session 已加载过的 messages 喂给
    /// `TranscriptRowBuilder.prepareAll`,让 `TranscriptPrepareCache.shared`
    /// 预先填充 **Prepared**（parse + prebuild + diff hunks）。用户真点进去
    /// 时 parse 命中，layout 仍按当前精确 width 在 setEntries 路径上算。
    ///
    /// 严格 best-effort：
    /// - 只 prewarm 已缓存的 handle(`existingSession`)——不触发 loadHistory,
    ///   避免 hover 一个从未打开过的会话凭空做重 I/O。
    /// - Width:prewarm 里算出来的 layout 会被丢弃（cache 不存 layout），
    ///   任何一个合理 width 都可以。用当前 theme 的 `maxContentWidth`。
    /// - Theme:从环境拿当前 markdown theme,不硬编码 `.default`。
    private func prewarm() {
        guard let handle = manager.existingSession(session.id) else { return }
        let entries = handle.messages
        guard !entries.isEmpty else { return }
        let transcriptTheme = TranscriptTheme(markdown: markdownTheme)
        let width = transcriptTheme.maxContentWidth
        Task.detached(priority: .utility) {
            _ = TranscriptRowBuilder.prepareAll(
                entries: entries,
                theme: transcriptTheme,
                width: width)
        }
    }

    // MARK: - Subviews

    /// 固定宽度的左侧指示区，宽度与 section header icon 列对齐。未读时显示蓝点，否则留空。
    private var leadingIndicator: some View {
        ZStack {
            if viewModel.unreadSessionIds.contains(session.id) {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: SidebarMetrics.iconColumnWidth)
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.record.title)
                .font(.system(size: 13))
                .lineLimit(1)

            if hasSubtitle {
                HStack(spacing: 4) {
                    if showCapsule, let folderName = session.folderName {
                        let color = viewModel.folderColor(for: folderName)
                        Text(folderName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(color.opacity(0.12)))
                            .foregroundStyle(color)
                    }

                    if let branch = session.branch {
                        Text(branch)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if session.isWorktree {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hoverButtonsContent: some View {
        switch style {
        case .running:
                Button {
                    viewModel.stopSession(session.id)
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)

                pinButton

                archiveButton

            case .pinned:
                pinButton

                archiveButton

            case .project:
                pinButton

                archiveButton
        }
    }

    private var pinButton: some View {
        Button {
            if session.record.isPinned {
                viewModel.unpinSession(sessionId: session.id)
            } else {
                viewModel.pinSession(sessionId: session.id)
            }
        } label: {
            Image(systemName: session.record.isPinned ? "pin.slash" : "pin")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 20)
    }

    private var archiveButton: some View {
        Button {
            viewModel.archiveSession(session.id)
        } label: {
            Image(systemName: "archivebox")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let cwd = session.record.cwd {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
            }
        }
        if let branch = session.branch {
            Button("Copy Branch") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch, forType: .string)
            }
        }
        if let cwd = session.record.cwd {
            Button("Open in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
            }
        }
        if let jsonlURL = viewModel.jsonlFileURL(for: session.id) {
            Button("Reveal JSONL in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([jsonlURL])
            }
        }

        Divider()

        if session.record.isPinned {
            Button("Unpin") {
                viewModel.unpinSession(sessionId: session.id)
            }
        } else {
            Button("Pin") {
                viewModel.pinSession(sessionId: session.id)
            }
        }

        Button("Archive") {
            viewModel.archiveSession(session.id)
        }
    }

    // MARK: - Helpers

    private var showCapsule: Bool {
        style == .running || style == .pinned
    }

    private var hasSubtitle: Bool {
        showCapsule || session.branch != nil || session.isWorktree
    }
}
