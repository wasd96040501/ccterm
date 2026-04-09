import SwiftUI

struct PluginDirPickerView: View {
    let workingDirectory: String?
    let onDismiss: () -> Void

    @State private var directories: [String] = []
    @State private var enabledSet: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Plugins").font(.headline)
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Divider()

            if directories.isEmpty {
                Text("No plugin directories")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List {
                    ForEach(directories, id: \.self) { dir in
                        Toggle(isOn: binding(for: dir)) {
                            Text(URL(fileURLWithPath: dir).lastPathComponent).help(dir)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { PluginDirStore.removeDirectory(directories[i]) }
                        reload()
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 80, maxHeight: 200)
            }

            Divider()
            Button { addDirectory() } label: {
                Label("Add Directory…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 260)
        .onAppear { reload() }
        .onDisappear { onDismiss() }
    }

    private func reload() {
        directories = PluginDirStore.directories
        if let path = workingDirectory {
            enabledSet = PluginDirStore.enabledSet(forPath: path)
        } else {
            enabledSet = PluginDirStore.enabledSet
        }
    }

    private func binding(for dir: String) -> Binding<Bool> {
        Binding(
            get: { enabledSet.contains(dir) },
            set: { newValue in
                if newValue {
                    enabledSet.insert(dir)
                } else {
                    enabledSet.remove(dir)
                }
                if let path = workingDirectory {
                    PluginDirStore.saveEnabledDirectories(
                        directories.filter { enabledSet.contains($0) },
                        forPath: path
                    )
                } else {
                    PluginDirStore.setEnabled(dir, enabled: newValue)
                }
            }
        )
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a plugin directory")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            PluginDirStore.addDirectory(url.path)
            reload()
        }
    }
}
