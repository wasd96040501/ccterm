import AgentSDK
import SwiftUI

/// Body for `.webFetch` permission requests. Mirrors
/// `WebFetchPermissionRequest` upstream: prominent URL, a domain
/// chip so the user can pattern-match "this is the domain Allow
/// always would whitelist", and the agent's `prompt` rendered as
/// secondary text below.
///
/// The CLI's "Yes, and don't ask again for <hostname>" branch maps
/// to our shared "Allow always" button, which forwards the request's
/// `permissionSuggestions` (those typically encode `domain:<host>`).
/// No per-domain branching at the button level — the rule the
/// request would install is opaque, just like every other kind.
struct PermissionWebFetchCardBody: View {
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(url ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let host = hostname {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(host)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let prompt = prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    var url: String? {
        let raw = request.rawInput["url"] as? String
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Parsed hostname for the domain chip. `nil` if `url` isn't a
    /// valid URL with a host component — the upstream falls back to
    /// the raw string in that case; we just hide the chip.
    var hostname: String? {
        guard let url, let parsed = URL(string: url) else { return nil }
        return parsed.host
    }

    var prompt: String? {
        let raw = request.rawInput["prompt"] as? String
        return (raw?.isEmpty == false) ? raw : nil
    }
}
