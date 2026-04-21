import AgentSDK
import Foundation

/// 把一串 `MessageEntry` 映射到 `[TranscriptRowItem]`——纯函数,同输入同输出。
///
/// 规则(对齐 plan §E):
/// - `.single(.user)` 有 plainText → `UserBubbleRowItem`
/// - `.single(.user)` 其他(比如 tool_result) → 跳过,不渲染
/// - `.single(.assistant)` 仅 text → `AssistantMarkdownRowItem`
/// - `.single(.assistant)` 仅 tool_use → 按顺序 `PlaceholderRowItem("[Tool: N]")`
/// - `.single(.assistant)` text + tool_use 混合 → 按 block 顺序拆成 markdown + placeholders
/// - `.single(.assistant)` 只含 thinking / unknown → 跳过
/// - `.group` → 单条 `PlaceholderRowItem("[Tools × N]")`
enum MessageEntryTranscriber {

    static func make(entries: [MessageEntry], theme: MarkdownTheme) -> [TranscriptRowItem] {
        let transcriptTheme = TranscriptTheme(markdown: theme)
        var out: [TranscriptRowItem] = []

        for entry in entries {
            switch entry {
            case .single(let single):
                append(from: single, theme: transcriptTheme, into: &out)
            case .group(let group):
                let label = "[Tools × \(group.items.count)]"
                out.append(PlaceholderRowItem(
                    label: label,
                    theme: transcriptTheme,
                    stable: group.id))
            }
        }
        return out
    }

    // MARK: - Single

    private static func append(
        from single: SingleEntry,
        theme: TranscriptTheme,
        into out: inout [TranscriptRowItem]
    ) {
        switch single.payload {
        case .localUser(let input):
            if let text = input.text, !text.isEmpty {
                out.append(UserBubbleRowItem(
                    text: text, theme: theme, stable: single.id))
            }
            return

        case .remote(let message):
            switch message {
            case .user(let u):
                if let text = userPlainText(u), !text.isEmpty {
                    out.append(UserBubbleRowItem(
                        text: text, theme: theme, stable: single.id))
                }
                // tool_result / image-only / empty → skip
            case .assistant(let a):
                appendAssistant(
                    blocks: a.message?.content ?? [],
                    entryId: single.id,
                    theme: theme,
                    into: &out)
            default:
                break  // system / result / unknown → not rendered
            }
        }
    }

    /// Walk assistant blocks in order, merging adjacent text blocks into one
    /// `AssistantMarkdownRowItem` and emitting a `PlaceholderRowItem` for each
    /// tool_use. Thinking / unknown blocks are ignored.
    private static func appendAssistant(
        blocks: [Message2AssistantMessageContent],
        entryId: UUID,
        theme: TranscriptTheme,
        into out: inout [TranscriptRowItem]
    ) {
        var textBuffer: [String] = []
        var textStartIndex = 0

        func flushText(endIndex: Int) {
            guard !textBuffer.isEmpty else { return }
            let source = textBuffer.joined(separator: "\n\n")
            textBuffer.removeAll()
            out.append(AssistantMarkdownRowItem(
                source: source,
                theme: theme,
                stable: "\(entryId.uuidString)-md-\(textStartIndex)" as String))
            textStartIndex = endIndex
        }

        for (idx, block) in blocks.enumerated() {
            switch block {
            case .text(let t):
                if let s = t.text, !s.isEmpty {
                    if textBuffer.isEmpty { textStartIndex = idx }
                    textBuffer.append(s)
                }
            case .toolUse(let u):
                flushText(endIndex: idx)
                out.append(PlaceholderRowItem(
                    label: "[Tool: \(u.caseName)]",
                    theme: theme,
                    stable: "\(entryId.uuidString)-tool-\(idx)" as String))
            case .thinking, .unknown:
                continue
            }
        }
        flushText(endIndex: blocks.count)
    }

    // MARK: - User plaintext

    /// Concatenate visible text from Message2User's `.string` / `.array` content.
    /// Image / tool_result parts are ignored — user bubbles only show typed text.
    private static func userPlainText(_ user: Message2User) -> String? {
        switch user.message?.content {
        case .string(let s)?:
            return s
        case .array(let items)?:
            let parts = items.compactMap { item -> String? in
                if case .text(let t) = item { return t.text }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        default:
            return nil
        }
    }
}
