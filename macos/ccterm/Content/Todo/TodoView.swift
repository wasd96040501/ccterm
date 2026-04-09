import SwiftUI

// MARK: - TodoView

struct TodoView: View {

    @ObservedObject var todoService: TodoService
    let todoSessionCoordinator: TodoSessionCoordinator
    let sessionService: SessionService
    var onJumpToSession: ((String) -> Void)?

    @State private var expansions: [TodoGroup: Bool] = [:]
    @State private var selectedCompletedIds: Set<UUID> = []
    @State private var inputTitle = ""
    @State private var inputPath: String?
    @State private var inputBranch: String?
    @State private var showBranchPicker = false
    @State private var branchPickerContext: BranchPickerContext?
    @State private var showFolderPicker = false
    @State private var shakePathButton = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                headerSection
                ForEach(TodoGroup.allCases) { group in
                    let items = self.items(for: group)
                    todoGroupSection(group: group, items: items)
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .popover(item: $branchPickerContext) { context in
            BranchPickerView(
                branches: context.branches,
                currentBranch: context.currentBranch,
                onSelect: { branch in
                    context.onSelect(branch)
                    branchPickerContext = nil
                }
            )
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tasks")
                .font(.system(size: 22, weight: .bold))
            Text("Manage your development tasks")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Group Section

    @ViewBuilder
    private func todoGroupSection(group: TodoGroup, items: [TodoItem]) -> some View {
        let isFirst = (group == TodoGroup.allCases.first)
        let isExpanded = Binding(
            get: { expansions[group] ?? group.defaultExpanded(isEmpty: items.isEmpty) },
            set: { expansions[group] = $0 }
        )

        VStack(spacing: 0) {
            if !isFirst {
                Divider().padding(.bottom, 4)
            }
            groupHeader(group: group, itemCount: items.count, isExpanded: isExpanded)

            if isExpanded.wrappedValue {
                groupContent(group: group, items: items)
            }
        }
    }

    private func groupHeader(group: TodoGroup, itemCount: Int, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(group.themeColor)
                Text("(\(itemCount))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoFeedbackButtonStyle())
    }

    @ViewBuilder
    private func groupContent(group: TodoGroup, items: [TodoItem]) -> some View {
        if items.isEmpty && group != .pending {
            Text(group.emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 38)
                .frame(height: 28, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(items) { item in
            TodoItemRow(
                item: item,
                group: group,
                needsAttention: needsAttention(item),
                isSelected: selectedCompletedIds.contains(item.id),
                mergedItemTitles: mergedItemTitles(for: item, in: group),
                onCircleClick: { handleCircleClick(item, group: group) },
                onClick: { handleItemClick(item, group: group) },
                menuItems: { menuItems(for: item, in: group) }
            )
        }

        if group == .pending {
            todoInputRow
        }

        if group == .completed && !selectedCompletedIds.isEmpty {
            mergeButton
        }
    }

    // MARK: - Input Row

    private var todoInputRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .strokeBorder(Color(.systemGray), lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Describe your task...", text: $inputTitle, onCommit: submitTodo)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                HStack(spacing: 6) {
                    pathButton
                    branchButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var pathButton: some View {
        Button {
            showFolderPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                Text(inputPath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "Select Path"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(inputPath != nil ? .primary : .secondary)
        }
        .buttonStyle(NoFeedbackButtonStyle())
        .popover(isPresented: $showFolderPicker) {
            FolderPickerPopover(
                title: String(localized: "Select Directory"),
                description: String(localized: "Select task working directory"),
                userDefaultsKey: "todo.folderPicker",
                onConfirm: { primary, _ in
                    guard let primary else { return }
                    inputPath = primary.path
                    inputBranch = GitUtils.currentBranch(at: primary.path)
                    showFolderPicker = false
                }
            )
        }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .modifier(ShakeModifier(trigger: shakePathButton))
    }

    @ViewBuilder
    private var branchButton: some View {
        if let path = inputPath {
            Button {
                showBranchPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .medium))
                    Text(inputBranch ?? "main")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(NoFeedbackButtonStyle())
            .popover(isPresented: $showBranchPicker) {
                BranchPickerView(
                    branches: GitUtils.listBranches(at: path),
                    currentBranch: GitUtils.currentBranch(at: path),
                    onSelect: { branch in
                        inputBranch = branch
                        showBranchPicker = false
                    }
                )
            }
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    // MARK: - Merge Button

    private var mergeButton: some View {
        HStack {
            Spacer()
            Button("Merge Selected") {
                handleMerge()
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
    }

    // MARK: - Data Helpers

    private func items(for group: TodoGroup) -> [TodoItem] {
        switch group {
        case .deleted:
            return todoService.deletedTodos()
        default:
            guard let status = group.status else { return [] }
            return todoService.todos(status: status)
        }
    }

    private func needsAttention(_ item: TodoItem) -> Bool {
        guard let sessionId = item.sessionId,
              let handle = sessionService.handle(for: sessionId) else { return false }
        return !handle.pendingPermissions.isEmpty
    }

    private func mergedItemTitles(for item: TodoItem, in group: TodoGroup) -> [String]? {
        guard group == .archived, item.type == .merge, let ids = item.mergedItemIds else { return nil }
        return ids.compactMap { idString in
            guard let uuid = UUID(uuidString: idString) else { return nil }
            return todoService.todo(forId: uuid)?.title
        }
    }

    // MARK: - Actions

    private func submitTodo() {
        let title = inputTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        guard let path = inputPath else {
            shakePathButton.toggle()
            return
        }

        let metadata = TodoMetadata(
            paths: [path],
            gitBranch: inputBranch,
            pluginDirs: nil
        )
        let item = todoService.createTodo(title: title, metadata: metadata)
        todoSessionCoordinator.startTodoSession(for: item)
        inputTitle = ""
    }

    private func handleCircleClick(_ item: TodoItem, group: TodoGroup) {
        guard group == .inProgress else { return }
        todoService.markCompleted(id: item.id)
    }

    private func handleItemClick(_ item: TodoItem, group: TodoGroup) {
        if group == .completed {
            if selectedCompletedIds.contains(item.id) {
                selectedCompletedIds.remove(item.id)
            } else {
                selectedCompletedIds.insert(item.id)
            }
        } else if let sessionId = item.sessionId {
            switch group {
            case .needsConfirmation, .inProgress, .archived:
                onJumpToSession?(sessionId)
            default:
                break
            }
        }
    }

    private func handleMerge() {
        let ids = Array(selectedCompletedIds)
        guard !ids.isEmpty else { return }

        let items = ids.compactMap { todoService.todo(forId: $0) }
        guard let repoPath = items.first?.metadata?.paths.first else { return }

        let branches = GitUtils.listBranches(at: repoPath)
        let current = GitUtils.currentBranch(at: repoPath)
        branchPickerContext = BranchPickerContext(
            branches: branches,
            currentBranch: current,
            onSelect: { [ids] branch in
                Task {
                    if let sessionId = await todoSessionCoordinator.startMergeSession(todoIds: ids, targetBranch: branch) {
                        selectedCompletedIds.removeAll()
                        onJumpToSession?(sessionId)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func menuItems(for item: TodoItem, in group: TodoGroup) -> some View {
        switch group {
        case .pending:
            Button("Delete") { deleteTodo(item) }

        case .needsConfirmation:
            if item.sessionId != nil {
                Button("Go to Session") { jumpToSession(item) }
            }
            Button("Delete") { deleteTodo(item) }

        case .inProgress:
            if item.sessionId != nil {
                Button("Go to Session") { jumpToSession(item) }
            }
            Button("Mark Complete") { todoService.markCompleted(id: item.id) }
            Button("Delete") { deleteTodo(item) }

        case .completed:
            if item.sessionId != nil {
                Button("Go to Session") { jumpToSession(item) }
            }
            Button("Delete") { deleteTodo(item) }

        case .archived:
            if item.sessionId != nil {
                Button("Go to Session") { jumpToSession(item) }
            }

        case .deleted:
            Button("Restore") { todoService.restoreTodo(id: item.id) }
            Button("Permanently Delete") { todoService.permanentlyDelete(id: item.id) }
        }
    }

    private func deleteTodo(_ item: TodoItem) {
        if item.worktreeBranch != nil {
            DispatchQueue.global(qos: .utility).async {
                todoSessionCoordinator.cleanupWorktree(for: item)
            }
        }
        todoService.deleteTodo(id: item.id)
    }

    private func jumpToSession(_ item: TodoItem) {
        guard let sessionId = item.sessionId else { return }
        onJumpToSession?(sessionId)
    }
}

// MARK: - NoFeedbackButtonStyle

private struct NoFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - BranchPickerContext

private final class BranchPickerContext: Identifiable {
    let id = UUID()
    let branches: [String]
    let currentBranch: String?
    let onSelect: (String) -> Void

    init(branches: [String], currentBranch: String?, onSelect: @escaping (String) -> Void) {
        self.branches = branches
        self.currentBranch = currentBranch
        self.onSelect = onSelect
    }
}
