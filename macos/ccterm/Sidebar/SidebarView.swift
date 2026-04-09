import SwiftUI

/// Sidebar 主容器。使用 List + Section 展示操作区、运行中、置顶、项目分组。
/// 选中状态由外部提供（source of truth 在 RootView），SidebarView 不持有。
struct SidebarView: View {
    let viewModel: SidebarViewModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            actionSection
            Section {
                runningSection
                pinnedSection
                projectSections
            }
            .opacity(viewModel.isLoaded ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: viewModel.isLoaded)
        }
        .listStyle(.sidebar)
        .task { await viewModel.loadInitially() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var actionSection: some View {
        Section {
            ForEach(SidebarActionKind.allCases) { action in
                SidebarActionRow(action: action)
                    .tag(SidebarSelection.action(action))
            }
        }
    }

    @ViewBuilder
    private var runningSection: some View {
        if !viewModel.runningSessions.isEmpty {
            let sectionId = "running"
            Section {
                ForEach(viewModel.isSectionExpanded(sectionId) ? viewModel.runningSessions : []) { session in
                    SidebarSessionRow(session: session, style: .running, viewModel: viewModel)
                        .tag(SidebarSelection.session(session.id))
                }
            } header: {
                collapsibleHeader(
                    title: String(localized: "Running"),
                    systemImage: "play.circle",
                    sectionId: sectionId,
                    accessory: {
                        Circle().fill(.green).frame(width: 6, height: 6)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if !viewModel.pinnedSessions.isEmpty {
            let sectionId = "pinned"
            Section {
                ForEach(viewModel.isSectionExpanded(sectionId) ? viewModel.pinnedSessions : []) { session in
                    SidebarSessionRow(session: session, style: .pinned, viewModel: viewModel)
                        .tag(SidebarSelection.session(session.id))
                }
            } header: {
                collapsibleHeader(title: String(localized: "Pinned"), systemImage: "pin", sectionId: sectionId)
            }
        }
    }

    @ViewBuilder
    private var projectSections: some View {
        ForEach(viewModel.projectGroups) { group in
            let sectionId = group.id
            Section {
                ForEach(viewModel.isSectionExpanded(sectionId) ? group.sessions : []) { session in
                    SidebarSessionRow(session: session, style: .project, viewModel: viewModel)
                        .tag(SidebarSelection.session(session.id))
                }
            } header: {
                collapsibleHeader(title: group.folderName, systemImage: "folder", sectionId: sectionId)
            }
        }
    }

    // MARK: - Collapsible Header

    @ViewBuilder
    private func collapsibleHeader<Accessory: View>(
        title: String,
        systemImage: String,
        sectionId: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        let expanded = viewModel.isSectionExpanded(sectionId)
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: SidebarMetrics.iconColumnWidth, alignment: .center)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            accessory()
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(expanded ? .degrees(90) : .degrees(0))
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleSection(sectionId) }
    }
}

/// Sidebar 布局常量。Action Row / Section Header / Session Row 共享，保证垂直对齐。
enum SidebarMetrics {
    /// icon 列宽度（Label icon 区域 / section header icon frame / session row 左侧占位）。
    static let iconColumnWidth: CGFloat = 16
}
