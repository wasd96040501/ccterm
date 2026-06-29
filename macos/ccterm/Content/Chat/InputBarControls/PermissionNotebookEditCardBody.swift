import AgentSDK
import Foundation

/// Body for `.notebookEdit` permission requests. Mirrors the
/// upstream `NotebookEditPermissionRequest` shape: a subtitle that
/// names the action (insert / delete / replace), the cell type
/// (markdown / python), and a monospaced preview of `new_source`.
///
/// For "delete" mode `new_source` is typically empty, so the body
/// instead surfaces the `cell_id` so the user knows which cell is
/// being removed. A full pre-edit diff (parse the .ipynb,
/// extract the cell, render old vs. new) is deferred until a
/// follow-up — the v1 card mirrors the same trust budget as the
/// shell body: "see what the agent proposes, then decide."
struct PermissionNotebookEditCardBody {
    let request: PermissionRequest

    // MARK: - Data

    var notebookPath: String? {
        (request.rawInput["notebook_path"] as? String)
            ?? (request.rawInput["notebookPath"] as? String)
    }

    var basename: String? { notebookPath.map { ($0 as NSString).lastPathComponent } }

    /// One of "insert" / "delete" / "replace" (the upstream tool's
    /// `edit_mode` enum). Defaults to "replace" since that's the
    /// upstream default when the field is missing.
    var editMode: String {
        ((request.rawInput["edit_mode"] as? String)
            ?? (request.rawInput["editMode"] as? String)
                ?? "replace")
    }

    /// "markdown" or "code" — the upstream `cell_type` field.
    var cellType: String? {
        (request.rawInput["cell_type"] as? String)
            ?? (request.rawInput["cellType"] as? String)
    }

    var cellId: String? {
        (request.rawInput["cell_id"] as? String)
            ?? (request.rawInput["cellId"] as? String)
    }

    var subtitle: String? {
        guard let basename else { return nil }
        switch editMode {
        case "insert": return String(localized: "Insert cell into \(basename)")
        case "delete": return String(localized: "Delete cell from \(basename)")
        default: return String(localized: "Edit cell in \(basename)")
        }
    }

    var cellLabel: String? {
        guard let cellId else { return nil }
        let typeText: String
        switch cellType {
        case "markdown": typeText = String(localized: "markdown")
        case "code"?, nil: typeText = String(localized: "python")
        default: typeText = cellType ?? ""
        }
        return String(localized: "Cell \(cellId) · \(typeText)")
    }

    /// `new_source` is the new content the cell will hold after the
    /// edit. For "delete" this is typically empty — the body then
    /// shows only the cell label.
    var sourcePreview: String? {
        let raw =
            (request.rawInput["new_source"] as? String)
            ?? (request.rawInput["newSource"] as? String)
        return raw?.isEmpty == false ? raw : nil
    }
}
