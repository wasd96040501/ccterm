import SwiftUI

/// Host-scoped context switcher for the compose card's Projects column (design
/// `remote-execution.md` §4a). A horizontally-scrolling capsule strip: `Local`
/// first, then one capsule per configured `RemoteHost`. Tapping a capsule sets
/// the active host (nil = local); the recents list / hero / recent-sessions all
/// scope to it. Only rendered when at least one remote host exists.
struct RemoteHostCapsuleStrip: View {
    let hosts: [RemoteHost]
    /// nil = Local.
    let activeHostId: String?
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HostCapsule(
                    systemImage: "desktopcomputer",
                    label: String(localized: "Local"),
                    isActive: activeHostId == nil
                ) { onSelect(nil) }

                ForEach(hosts) { host in
                    HostCapsule(
                        systemImage: "server.rack",
                        label: host.displayName,
                        isActive: activeHostId == host.id
                    ) { onSelect(host.id) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }
}

/// One pill in the strip. Active = accent fill; inactive = subtle recess that
/// darkens on hover — same family as the card's worktree / branch pills.
private struct HostCapsule: View {
    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    isActive
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.09 : 0.04))
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    Color(nsColor: .separatorColor).opacity(isActive ? 0 : 0.5), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Left-column content shown when a remote host is the active context (replaces
/// the local recents list, which is local-path-only until M8's per-host recents).
/// A compact card summarizing the host's connection + policy, with Edit / Remove.
struct RemoteHostDetailPanel: View {
    let host: RemoteHost
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tint)
                    Text(host.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                infoRow(icon: "network", text: connectionString)
                if let wd = host.remoteWorkdir, !wd.isEmpty {
                    infoRow(icon: "folder", text: wd)
                }
                infoRow(icon: claudeIcon, text: claudeText)
                infoRow(icon: "arrow.up.arrow.down", text: proxyText)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Label(String(localized: "Edit Host…"), systemImage: "pencil")
                }
                Spacer(minLength: 0)
                Button(role: .destructive, action: onRemove) {
                    Label(String(localized: "Remove"), systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Derived display

    private var connectionString: String {
        var s = host.host
        if let u = host.user, !u.isEmpty { s = "\(u)@\(s)" }
        if let p = host.port { s += ":\(p)" }
        return s
    }

    private var claudeIcon: String {
        switch host.claudePolicy {
        case .managed: return "shippingbox"
        case .useRemote: return "terminal"
        }
    }

    private var claudeText: String {
        switch host.claudePolicy {
        case .managed:
            return String(localized: "Managed claude")
        case .useRemote(let path):
            if let path, !path.isEmpty { return path }
            return String(localized: "Remote's own claude")
        }
    }

    private var proxyText: String {
        switch host.proxy {
        case .useExisting(let hostPort):
            return String(localized: "Proxy: \(hostPort ?? "127.0.0.1:1081")")
        case .ccTermRunsOne:
            return String(localized: "CCTerm-run proxy")
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
