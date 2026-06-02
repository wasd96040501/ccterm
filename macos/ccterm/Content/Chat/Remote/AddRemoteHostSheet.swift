import AppKit
import SwiftUI

/// Add / edit an SSH remote host (design `remote-execution.md` §4). A SwiftUI
/// grouped `Form` styled like System Settings — connection fields, the
/// `RemoteClaudePolicy` radio, the `RemoteProxyMode` radio, and a Test Connection
/// section driven by `RemoteHostProbe`.
///
/// Pure form: it collects field values into a `RemoteHost` and hands it back via
/// `onSave`; persistence (`RemoteHostStore.upsert`) and activation live with the
/// presenter (`NewSessionConfigurator`), so the sheet needs no store of its own.
struct AddRemoteHostSheet: View {

    /// nil → add a new host; non-nil → edit it in place (same `id` on save).
    let editing: RemoteHost?
    /// Called with the assembled host when the user taps Save. The presenter
    /// upserts it and switches the active context to it.
    let onSave: (RemoteHost) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: Connection fields
    @State private var alias: String
    @State private var host: String
    @State private var user: String
    @State private var port: String
    @State private var identityFile: String
    @State private var remoteWorkdir: String

    // MARK: Policy
    private enum ClaudeKind: Hashable { case managed, useRemote }
    private enum ProxyKind: Hashable { case useExisting, ccTermRunsOne }
    @State private var claudeKind: ClaudeKind
    @State private var useRemotePath: String
    @State private var proxyKind: ProxyKind
    @State private var proxyHostPort: String

    // MARK: Test Connection
    @State private var probing = false
    @State private var checks: [RemoteHostProbe.Check] = []

    init(editing: RemoteHost? = nil, onSave: @escaping (RemoteHost) -> Void) {
        self.editing = editing
        self.onSave = onSave
        _alias = State(initialValue: editing?.alias ?? "")
        _host = State(initialValue: editing?.host ?? "")
        _user = State(initialValue: editing?.user ?? "")
        _port = State(initialValue: editing?.port.map(String.init) ?? "")
        _identityFile = State(initialValue: editing?.identityFile ?? "")
        _remoteWorkdir = State(initialValue: editing?.remoteWorkdir ?? "")

        switch editing?.claudePolicy {
        case .useRemote(let path):
            _claudeKind = State(initialValue: .useRemote)
            _useRemotePath = State(initialValue: path ?? "")
        default:  // .managed or new
            _claudeKind = State(initialValue: .managed)
            _useRemotePath = State(initialValue: "")
        }

        switch editing?.proxy {
        case .ccTermRunsOne:
            _proxyKind = State(initialValue: .ccTermRunsOne)
            _proxyHostPort = State(initialValue: "")
        case .useExisting(let hostPort):
            _proxyKind = State(initialValue: .useExisting)
            _proxyHostPort = State(initialValue: hostPort ?? "")
        case nil:
            _proxyKind = State(initialValue: .useExisting)
            _proxyHostPort = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                claudeSection
                proxySection
                testSection
            }
            .formStyle(.grouped)
            .navigationTitle(
                editing == nil ? String(localized: "Add SSH Host") : String(localized: "Edit SSH Host")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .disabled(trimmed(host).isEmpty)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 560, idealHeight: 600)
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            TextField(String(localized: "Alias"), text: $alias, prompt: Text(verbatim: host.isEmpty ? "devbox" : host))
            TextField(
                String(localized: "Host"), text: $host, prompt: Text(String(localized: "Hostname or ssh config alias")))
            TextField(String(localized: "User"), text: $user, prompt: Text(String(localized: "Default")))
            TextField(String(localized: "Port"), text: $port, prompt: Text(verbatim: "22"))
            HStack {
                TextField(
                    String(localized: "Identity File"), text: $identityFile,
                    prompt: Text(String(localized: "ssh-agent / config")))
                Button(String(localized: "Choose…")) { chooseIdentityFile() }
            }
            TextField(
                String(localized: "Working Directory"), text: $remoteWorkdir,
                prompt: Text(verbatim: "~/src"))
        } header: {
            Text(String(localized: "Connection"))
        } footer: {
            Text(String(localized: "Leave fields blank to inherit from your ~/.ssh/config."))
                .foregroundStyle(.secondary)
        }
    }

    private var claudeSection: some View {
        Section {
            Picker("", selection: $claudeKind) {
                Text(String(localized: "Let CCTerm manage it")).tag(ClaudeKind.managed)
                Text(String(localized: "Use the remote's own")).tag(ClaudeKind.useRemote)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if claudeKind == .useRemote {
                TextField(
                    String(localized: "Claude Path"), text: $useRemotePath,
                    prompt: Text(String(localized: "Auto-detect")))
            }
        } header: {
            Text(String(localized: "Claude on the Remote"))
        } footer: {
            Text(
                claudeKind == .managed
                    ? String(
                        localized:
                            "CCTerm installs its own pinned claude and forwards this Mac's credential into the launch. No remote setup needed."
                    )
                    : String(
                        localized:
                            "Trust the claude already on the remote. CCTerm downloads nothing and forwards no credential — the remote's own login is used."
                    )
            )
            .foregroundStyle(.secondary)
        }
    }

    private var proxySection: some View {
        Section {
            Picker("", selection: $proxyKind) {
                Text(String(localized: "Reuse a local HTTP proxy")).tag(ProxyKind.useExisting)
                Text(String(localized: "Let CCTerm run one")).tag(ProxyKind.ccTermRunsOne)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if proxyKind == .useExisting {
                TextField(
                    String(localized: "Proxy"), text: $proxyHostPort,
                    prompt: Text(verbatim: "127.0.0.1:1081"))
            }
        } header: {
            Text(String(localized: "API Egress"))
        } footer: {
            Text(
                String(
                    localized:
                        "The remote reaches the Anthropic API by tunneling through a proxy on this Mac over ssh -R."
                )
            )
            .foregroundStyle(.secondary)
        }
    }

    private var testSection: some View {
        Section {
            Button(action: runProbe) {
                HStack(spacing: 8) {
                    if probing {
                        ProgressView().controlSize(.small)
                    }
                    Text(String(localized: "Test Connection"))
                }
            }
            .disabled(trimmed(host).isEmpty || probing)

            ForEach(checks) { check in
                checkRow(check)
            }
        } header: {
            Text(String(localized: "Test Connection"))
        }
    }

    @ViewBuilder
    private func checkRow(_ check: RemoteHostProbe.Check) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName(check.status))
                .foregroundStyle(iconColor(check.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(check.label)
                    .font(.system(size: 12, weight: .medium))
                Text(check.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private func iconName(_ status: RemoteHostProbe.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        }
    }

    private func iconColor(_ status: RemoteHostProbe.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }

    // MARK: - Actions

    private func runProbe() {
        let target = makeHost()
        probing = true
        checks = []
        Task {
            let result = await RemoteHostProbe().run(target)
            checks = result
            probing = false
        }
    }

    private func save() {
        let target = makeHost()
        guard !target.host.isEmpty else { return }
        onSave(target)
        dismiss()
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = String(localized: "Choose an SSH identity file")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            identityFile = url.path
        }
    }

    /// Assemble a `RemoteHost` from the current field values. Preserves the
    /// existing `id` when editing so sessions already bound to it keep working.
    private func makeHost() -> RemoteHost {
        let claudePolicy: RemoteClaudePolicy =
            claudeKind == .managed ? .managed : .useRemote(path: trimmedOrNil(useRemotePath))
        let proxy: RemoteProxyMode =
            proxyKind == .useExisting ? .useExisting(hostPort: trimmedOrNil(proxyHostPort)) : .ccTermRunsOne
        return RemoteHost(
            id: editing?.id ?? UUID().uuidString,
            alias: trimmed(alias),
            host: trimmed(host),
            user: trimmedOrNil(user),
            port: Int(trimmed(port)),
            identityFile: trimmedOrNil(identityFile),
            remoteWorkdir: trimmedOrNil(remoteWorkdir),
            claudePolicy: claudePolicy,
            proxy: proxy)
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = trimmed(s)
        return t.isEmpty ? nil : t
    }
}

#Preview {
    AddRemoteHostSheet(editing: nil, onSave: { _ in })
}
