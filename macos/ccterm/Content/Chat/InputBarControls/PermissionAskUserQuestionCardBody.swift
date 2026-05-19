import AgentSDK
import SwiftUI

/// Body for `.askUserQuestion` permission requests. Upstream's
/// `AskUserQuestionPermissionRequest` is a 644-line full multi-step
/// question UI — navigation bar between questions, multi-select
/// state, image/paste support, syntax-highlighted code in option
/// labels. It only flows through the permission pipe because the
/// CLI plumbs interactive questions over the same approval channel.
///
/// **v1 in ccterm:** the input-bar overlay is the wrong surface for
/// a real question UI. Instead, we surface a one-line summary
/// ("Claude wants to ask you N questions") followed by the first
/// question text and a hint that "Allow once" delivers the user's
/// response via the transcript. The full question UI deserves its
/// own follow-up PR (probably a sheet) — flagged in the handoff.
///
/// "Allow always" maps to "answer the same way going forward" at
/// the CLI level, which is conceptually wrong for questions; the
/// shared decision-button row is left in place for consistency
/// across kinds but the user is expected to choose "Allow once".
struct PermissionAskUserQuestionCardBody: View {
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let preview = firstQuestion {
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if questionCount > 1 {
                Text(remainingHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    /// Decoded questions list from `rawInput["questions"]`. Each
    /// entry is the raw dict — we only read the `question` string,
    /// so a full Codable model would be overkill for the v1 surface.
    var questions: [[String: Any]] {
        (request.rawInput["questions"] as? [[String: Any]]) ?? []
    }

    var questionCount: Int { questions.count }

    /// First question text. Falls back to the first entry's literal
    /// representation when the dict shape is off — e.g. an older
    /// build that emits a flat string list.
    var firstQuestion: String? {
        guard let first = questions.first else { return nil }
        if let q = first["question"] as? String, !q.isEmpty {
            return q
        }
        return nil
    }

    var headline: String {
        let n = questionCount
        if n <= 0 {
            return String(localized: "Claude wants to ask you a question")
        }
        if n == 1 {
            return String(localized: "Claude wants to ask you a question")
        }
        return String(localized: "Claude wants to ask you \(n) questions")
    }

    var remainingHint: String {
        let extra = max(questionCount - 1, 0)
        return String(localized: "\(extra) more question(s) after this one")
    }
}

#Preview("Single question") {
    PermissionAskUserQuestionCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-1",
            toolName: "AskUserQuestion",
            input: [
                "questions": [
                    [
                        "question": "Which database driver should we use for the new service?"
                    ]
                ]
            ])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Multiple questions") {
    PermissionAskUserQuestionCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-2",
            toolName: "AskUserQuestion",
            input: [
                "questions": [
                    ["question": "Should we keep backwards-compatibility shims for the old API?"],
                    ["question": "Which timezone should the report default to?"],
                    ["question": "Do we ship a migration script in this PR?"],
                ]
            ])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Empty questions") {
    PermissionAskUserQuestionCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-3",
            toolName: "AskUserQuestion",
            input: [:])
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}
