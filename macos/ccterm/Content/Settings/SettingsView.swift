import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView()
            case .debug:
                DebugSettingsView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 660, height: 420)
    }
}

private enum SettingsSection: CaseIterable {
    case general
    case debug

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .debug: return String(localized: "Debug")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .debug: return "ladybug"
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("customCLICommand") private var customCLICommand: String = ""
    @AppStorage("sendKeyBehavior") private var sendKeyBehaviorRaw: String = SendKeyBehavior.commandEnter.rawValue

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Launch Command")
                    Spacer()
                    TextField("", text: $customCLICommand, prompt: Text("claude"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 300)
                }
            } footer: {
                Text("Specify the command to launch Claude. Leave empty to auto-detect `claude` in your system.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Send message with", selection: $sendKeyBehaviorRaw) {
                    ForEach(SendKeyBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

private struct DebugSettingsView: View {
    @AppStorage(SessionExportDefaults.enabledKey) private var exportSessionJSONL: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Export session JSONL", isOn: $exportSessionJSONL)
            } footer: {
                Text("Save the raw message stream to ~/.cache/ccterm/export. Takes effect for newly started sessions.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Debug")
    }
}
