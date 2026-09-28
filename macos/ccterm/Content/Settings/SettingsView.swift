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
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 660, height: 420)
    }
}

private enum SettingsSection: CaseIterable {
    case general

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("customCLICommand") private var customCLICommand: String = ""

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
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
