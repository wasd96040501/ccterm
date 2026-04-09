import Foundation

// MARK: - Protocol

/// A rule that detects whether a trigger character at the current cursor position
/// should start a completion session. Each rule encapsulates trigger detection and
/// session construction for one completion type.
protocol CompletionTriggerRule {
    func match(
        text: String,
        cursorLocation: Int,
        context: CompletionTriggerContext
    ) -> CompletionEngine.CompletionSession?
}

/// Data and action closures passed to trigger rules each time `checkTrigger` runs.
struct CompletionTriggerContext {
    let directory: String?
    let additionalDirs: [String]
    let pluginDirs: [String]
    let slashCommandProvider: ((_ query: String, _ completion: @escaping ([SlashCommandStore.Match]) -> Void) -> Void)?
    /// Called when a directory is picked (sets selectedDirectory, branch, etc.).
    let onDirectoryPicked: ((_ path: String) -> Void)?
}

// MARK: - Helpers

extension CompletionTriggerRule {
    /// Returns true if `char` is at `cursorLocation - 1` and preceded by whitespace or at start.
    func isTriggerPosition(text: String, cursorLocation: Int, for char: Character) -> Bool {
        guard cursorLocation > 0, cursorLocation <= text.count else { return false }
        let index = text.index(text.startIndex, offsetBy: cursorLocation - 1)
        guard text[index] == char else { return false }

        if cursorLocation == 1 { return true }
        let prevIndex = text.index(text.startIndex, offsetBy: cursorLocation - 2)
        return text[prevIndex].isWhitespace || text[prevIndex].isNewline
    }
}

// MARK: - Slash Command

struct SlashCommandTriggerRule: CompletionTriggerRule {
    func match(text: String, cursorLocation: Int, context: CompletionTriggerContext) -> CompletionEngine.CompletionSession? {
        guard cursorLocation == 1,
              cursorLocation <= text.count,
              text[text.startIndex] == "/" else { return nil }

        let makeReplacement: (any CompletionItem, String, Int, Bool) -> (range: NSRange, replacement: String) = { item, _, wordEnd, _ in
            (range: NSRange(location: 0, length: wordEnd), replacement: item.displayText + " ")
        }

        if let slashProvider = context.slashCommandProvider {
            return .init(anchorLocation: 0, provider: { query, cb in slashProvider(query, cb) }, makeReplacement: makeReplacement)
        }

        // No session-provided commands: fall back to SlashCommandStore if directory exists
        if let dir = context.directory {
            let pluginDirs = context.pluginDirs
            return .init(
                anchorLocation: 0,
                provider: { query, cb in
                    SlashCommandStore.shared.complete(query: query, path: dir, pluginDirs: pluginDirs, knownCommands: nil, completion: cb)
                },
                makeReplacement: makeReplacement
            )
        }

        // No directory at all
        return .init(anchorLocation: 0, emptyReasonOverride: .noDirectory, provider: { _, cb in cb([]) }, makeReplacement: makeReplacement)
    }
}

// MARK: - Directory Pick (@ when no directory)

struct DirectoryPickTriggerRule: CompletionTriggerRule {
    func match(text: String, cursorLocation: Int, context: CompletionTriggerContext) -> CompletionEngine.CompletionSession? {
        guard context.directory == nil,
              isTriggerPosition(text: text, cursorLocation: cursorLocation, for: "@") else { return nil }

        let anchorLoc = cursorLocation - 1
        let onPicked = context.onDirectoryPicked

        return .init(
            anchorLocation: anchorLoc,
            headerText: "请先选择工作目录（输入搜索 ~/ 下目录）· Tab / Enter · → drill down",
            provider: { query, cb in
                DirectoryCompletionProvider.provide(query: query, completion: cb)
            },
            makeReplacement: { item, _, wordEnd, keepSession in
                let length = wordEnd - anchorLoc
                let range = NSRange(location: anchorLoc, length: length)
                if keepSession {
                    // → drill down: 填入路径继续搜索子目录
                    return (range: range, replacement: "@" + item.displayText + "/")
                } else {
                    // Tab / Enter: 最终确认
                    return (range: range, replacement: "")
                }
            },
            onItemConfirmed: { item in
                guard let dirItem = item as? DirectoryCompletionItem else { return }
                onPicked?(dirItem.path)
            }
        )
    }
}

// MARK: - File Mention (@ when directory exists)

struct FileMentionTriggerRule: CompletionTriggerRule {
    func match(text: String, cursorLocation: Int, context: CompletionTriggerContext) -> CompletionEngine.CompletionSession? {
        guard let dir = context.directory,
              isTriggerPosition(text: text, cursorLocation: cursorLocation, for: "@") else { return nil }

        let anchorLoc = cursorLocation - 1
        let allDirs: [String] = {
            var dirs = [dir]
            dirs.append(contentsOf: context.additionalDirs)
            return dirs
        }()

        return .init(
            anchorLocation: anchorLoc,
            headerText: "Tab / Enter to confirm · → to drill down",
            provider: { query, cb in
                if allDirs.count > 1 {
                    FileCompletionStore.shared.complete(query: query, in: allDirs, completion: cb)
                } else {
                    FileCompletionStore.shared.complete(query: query, in: dir, completion: cb)
                }
            },
            makeReplacement: { item, _, wordEnd, _ in
                let length = wordEnd - anchorLoc
                let path = item.displayText
                let needsQuote = path.contains(" ")
                let replacement = needsQuote ? "@\"\(path)\" " : "@\(path) "
                return (range: NSRange(location: anchorLoc, length: length), replacement: replacement)
            },
            customWordRange: Self.quoteAwareWordRange,
            transformQuery: Self.stripQuotes
        )
    }

    // MARK: - Quote-Aware Helpers

    /// Word range that understands `@"quoted path"`. Scans past closing quote before looking for whitespace.
    private static func quoteAwareWordRange(_ text: String, _ anchor: Int) -> Range<Int> {
        guard anchor < text.count else { return anchor..<anchor }
        let afterAnchor = text.index(text.startIndex, offsetBy: anchor + 1)
        guard afterAnchor < text.endIndex else { return anchor..<text.count }

        // Check if word starts with a quote
        if text[afterAnchor] == "\"" {
            // Scan past the opening quote
            let afterQuote = text.index(after: afterAnchor)
            if afterQuote < text.endIndex,
               let closeQuote = text[afterQuote...].firstIndex(of: "\"") {
                // Found closing quote — word ends after the closing quote
                let afterClose = text.index(after: closeQuote)
                return anchor..<text.distance(from: text.startIndex, to: afterClose)
            }
            // No closing quote — word extends to end of text
            return anchor..<text.count
        }

        // No quote — default: scan to whitespace
        let rest = text[afterAnchor...]
        if let spaceIdx = rest.firstIndex(where: { $0.isWhitespace || $0.isNewline }) {
            return anchor..<text.distance(from: text.startIndex, to: spaceIdx)
        }
        return anchor..<text.count
    }

    /// Strip surrounding quotes from the raw query for fzf matching.
    private static func stripQuotes(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("\"") { s = String(s.dropFirst()) }
        if s.hasSuffix("\"") { s = String(s.dropLast()) }
        return s
    }
}
