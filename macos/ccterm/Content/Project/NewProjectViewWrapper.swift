import SwiftUI

/// 新项目页面（临时占位，后续用完整 SwiftUI 重写）。
struct NewProjectViewWrapper: View {

    let chatRouter: ChatRouter

    @State private var folders: [ProjectFolder] = []
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New Project")
                            .font(.system(size: 22, weight: .bold))
                        Text("Add working directories to start multi-directory collaboration")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    // Folder list
                    ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                Text(folder.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if folder.isGit, let branch = folder.branch {
                                Text(branch)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                folders.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                    }

                    // Add folder button
                    Button {
                        addFolder()
                    } label: {
                        Label("Add Directory", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
            }

            // Input bar area
            HStack(spacing: 8) {
                TextField("Describe your project task…", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendMessage() }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(folders.isEmpty || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            guard !folders.contains(where: { $0.path == path }) else { continue }
            let isGit = GitUtils.isGitRepository(at: path)
            let branch = isGit ? GitUtils.currentBranch(at: path) : nil
            folders.append(ProjectFolder(path: path, branch: branch, isGit: isGit, isWorktree: false))
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let primary = folders.first else { return }

        let addDirs = folders.dropFirst().map(\.path)
        let session = chatRouter.currentSession
        session.selectedDirectory = primary.path
        session.isWorktree = primary.isWorktree
        session.additionalDirectories = addDirs
        chatRouter.submitMessage(text)
        inputText = ""
    }
}
