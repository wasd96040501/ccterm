import AgentSDK
import Foundation
import SwiftUI

/// Body for `.sedEdit` permission requests — Bash commands of the
/// form `sed -i 's/foo/bar/g' file`. Mirrors `SedEditPermissionRequest`
/// upstream: read the target file, apply the substitution, and show
/// the resulting full-file diff via the same `DiffView` the
/// transcript uses for Edit/Write previews.
///
/// When the parser can't make sense of the command (alternate
/// delimiter, multiple `-e` expressions, shell metacharacters), the
/// dispatch layer routes the request to `PermissionShellCardBody`
/// instead — the user still sees the literal sed command. This body
/// only takes over when we have enough structure to render a diff.
struct PermissionSedEditCardBody: View {
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let diff = diffBlock {
                ScrollView(.vertical, showsIndicators: true) {
                    DiffView(diff: diff)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } else {
                Text(String(localized: "Could not preview sed substitution"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let command {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    var command: String? {
        let raw = request.rawInput["command"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// Parsed substitution info, `nil` when the command doesn't fit
    /// the supported subset (e.g. multi-file sed, glob args). The
    /// body then falls back to printing the literal command — same
    /// affordance as PermissionShellCardBody.
    var info: SedEditInfo? {
        guard let command else { return nil }
        return SedEditParser.parse(command)
    }

    var basename: String? {
        info.map { ($0.filePath as NSString).lastPathComponent }
    }

    var subtitle: String? {
        guard let basename else { return nil }
        return String(localized: "Edit \(basename)")
    }

    /// Constructs the diff: reads the file, applies the substitution,
    /// hands the old/new text to `DiffBlock`. Returns `nil` when we
    /// can't read the file — same envelope `PermissionFileWriteCardBody`
    /// uses for its missing-file branch.
    var diffBlock: DiffBlock? {
        guard let info else { return nil }
        let oldContent =
            (try? String(contentsOfFile: info.filePath, encoding: .utf8))
            ?? (try? String(contentsOfFile: info.filePath, encoding: .ascii))
        guard let oldContent else { return nil }
        let newContent = info.apply(to: oldContent)
        // Identical pre/post means the substitution didn't match
        // anything — surface the diff anyway so the user sees the
        // file the agent intended to touch. DiffView renders zero
        // hunks cleanly.
        return DiffBlock(
            filePath: info.filePath,
            oldString: oldContent,
            newString: newContent)
    }
}
