import AgentSDK
import Foundation
import SwiftUI

/// Body for `.skill` permission requests. Mirrors
/// `SkillPermissionRequest` upstream: the skill name as the
/// headline, the optional `args` rendered monospaced underneath, and
/// a working-directory chip so the user can see the per-cwd scope
/// "Allow always" would install.
///
/// Upstream pulls the cwd from `originalCwd` on the tool-use
/// confirmation; that field doesn't reach us as part of `rawInput`,
/// so we fall back to the process's current working directory —
/// same value the CLI would have echoed when the request was
/// queued.
struct PermissionSkillCardBody: View {
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let args, !args.isEmpty {
                Text(args)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let cwdLabel {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(cwdLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    /// The skill name (`"commit"`, `"review-pr"`, …). Falls through
    /// `skill` → `skillName` for older camelCase builds.
    var skill: String? {
        let raw =
            (request.rawInput["skill"] as? String)
            ?? (request.rawInput["skillName"] as? String)
        return raw?.isEmpty == false ? raw : nil
    }

    var args: String? {
        let raw = request.rawInput["args"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// Headline subtitle. Quotes the skill name to match upstream's
    /// `Use skill "X"?` phrasing — the quotes also visually separate
    /// the skill identifier from the surrounding verb.
    var headline: String {
        if let skill {
            return String(localized: "Use skill \"\(skill)\"")
        }
        return String(localized: "Use skill")
    }

    /// Basename of the working directory the "Allow always" rule
    /// would scope to. Empty / unreadable cwd hides the chip rather
    /// than rendering a misleading "/" — the rule would still install
    /// against whatever cwd the CLI sees.
    var cwdLabel: String? {
        let cwd = FileManager.default.currentDirectoryPath
        guard !cwd.isEmpty else { return nil }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }
}
