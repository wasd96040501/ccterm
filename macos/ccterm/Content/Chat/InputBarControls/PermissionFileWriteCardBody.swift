import AgentSDK
import Foundation

/// Per-kind **data getters** for `.fileEdit` and `.fileWrite` permission
/// requests (`FileEditPermissionRequest` / `FileWritePermissionRequest`): the
/// resolved `filePath` / `basename` / `fileExists`, the one-line subtitle
/// ("Edit / Create / Overwrite basename"), and the `DiffBlock` preview. The
/// SwiftUI chrome (subtitle + `DiffView` in `BoundedHeightScrollView`, with the
/// nil-diff fallback hint) now lives in the AppKit `PermissionFileWriteCardBodyView`;
/// D8 stripped the dead SwiftUI `body`/`#Preview`.
///
/// **Edit** — diff is rendered against the snippet pair
/// (`old_string` → `new_string`) rather than the full file content.
/// The card's job is to make the change *legible*; the file context
/// (offset, surrounding lines) is more transcript-territory and
/// would need a sync file read that the upstream avoids on slow
/// networked filesystems.
///
/// **Write** — diff is rendered against the file's current content
/// (sync `String(contentsOf:)`) vs the request's `content`. When the
/// file doesn't exist the diff is constructed in `isNewFile` mode
/// (`oldString = nil`), which `DiffLayout` paints as a line-numbered
/// view of the new content without `+`-insertion chrome.
struct PermissionFileWriteCardBody {
    let request: PermissionRequest
    let kind: PermissionCardKind

    /// Maximum visible height for the embedded `DiffView`. Hit it and
    /// the wrapper switches from intrinsic sizing to scroll.
    static let diffMaxHeight: CGFloat = 240

    // MARK: - Data

    /// `filePath` (snake_case `file_path`) is the canonical key in
    /// every relevant tool's input schema (Edit / Write / MultiEdit /
    /// FileWrite). Some pre-v2 builds emit `filePath` in camelCase;
    /// both are accepted.
    var filePath: String? {
        if let v = request.rawInput["file_path"] as? String, !v.isEmpty { return v }
        if let v = request.rawInput["filePath"] as? String, !v.isEmpty { return v }
        return nil
    }

    var basename: String? { filePath.map { ($0 as NSString).lastPathComponent } }

    /// `true` once we've verified there's a regular file at
    /// `filePath`. Drives "Create" vs "Overwrite" for Write.
    var fileExists: Bool {
        guard let filePath else { return false }
        return FileManager.default.fileExists(atPath: filePath)
    }

    /// One-line action subtitle, e.g. `"Edit Foo.swift"` /
    /// `"Create Bar.md"`. Returns `nil` when we can't even derive a
    /// basename — the body then prints a fallback hint instead.
    var subtitle: String? {
        guard let basename else { return nil }
        switch kind {
        case .fileEdit:
            return String(localized: "Edit \(basename)")
        case .fileWrite:
            return fileExists
                ? String(localized: "Overwrite \(basename)")
                : String(localized: "Create \(basename)")
        default:
            return nil
        }
    }

    /// Resolved diff for the `DiffView`. `nil` when we lack the
    /// minimum inputs (no `file_path`, or Edit with no `old_string` /
    /// `new_string`); the body then prints a fallback hint.
    var diffBlock: DiffBlock? {
        guard let filePath else { return nil }
        switch kind {
        case .fileEdit:
            return editDiffBlock(filePath: filePath)
        case .fileWrite:
            return writeDiffBlock(filePath: filePath)
        default:
            return nil
        }
    }

    private func editDiffBlock(filePath: String) -> DiffBlock? {
        let oldString = (request.rawInput["old_string"] as? String) ?? ""
        let newString = (request.rawInput["new_string"] as? String) ?? ""
        // An empty old_string with a non-empty new_string is the
        // upstream "append to new file" idiom — treat as new-file
        // mode so the gutter renders without `+` chrome. Otherwise
        // we show a snippet diff: short on context, but it's the
        // exact text the agent asked to replace.
        if oldString.isEmpty && !newString.isEmpty {
            return DiffBlock(filePath: filePath, oldString: nil, newString: newString)
        }
        return DiffBlock(filePath: filePath, oldString: oldString, newString: newString)
    }

    private func writeDiffBlock(filePath: String) -> DiffBlock? {
        let newContent = (request.rawInput["content"] as? String) ?? ""
        // ENOENT → new file. Any other read error (permissions, IO)
        // falls through to "new file" too — the agent could still
        // succeed at the write under the CLI's privileges, and the
        // user can decide based on the proposed content alone.
        let oldContent: String?
        if fileExists {
            oldContent =
                (try? String(contentsOfFile: filePath, encoding: .utf8))
                ?? (try? String(contentsOfFile: filePath, encoding: .ascii))
        } else {
            oldContent = nil
        }
        return DiffBlock(filePath: filePath, oldString: oldContent, newString: newContent)
    }
}
