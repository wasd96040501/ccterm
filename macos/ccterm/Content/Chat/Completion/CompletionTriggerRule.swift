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
    ) -> CompletionState.CompletionSession?
}

/// Data passed to each trigger rule. Built fresh per
/// `checkTrigger` call so rule logic sees the latest config and
/// directory choices without any stateful subscription dance.
struct CompletionTriggerContext {
    /// Working directory the bar should search files / slash commands
    /// against. `nil` in compose-mode before the user picks a folder —
    /// neither @ nor / completes anything in that state.
    let directory: String?
    /// Extra workspace dirs joined with `directory` for the multi-dir
    /// file lookup. Each match carries a `lastPathComponent` badge so
    /// the user can tell sources apart.
    let additionalDirs: [String]
    /// Plugin search dirs forwarded to the slash command store so its
    /// per-key cache differentiates configurations that change `plugins`
    /// without changing `cwd`.
    let pluginDirs: [String]
    /// When non-nil and non-empty, the slash rule short-circuits the
    /// store and filters this list synchronously — chat-mode sessions
    /// whose CLI has already returned an `initialize` response carry
    /// the command list directly, so a temp-CLI fetch would be wasted.
    /// Nil signals "no live list yet"; the rule falls through to the
    /// `SlashCommandStore`'s per-cwd cache, which serves both
    /// compose-mode and the brief window after a chat session attaches
    /// but before its CLI has answered `initialize`. Callers should
    /// collapse an empty live list to `nil` rather than forwarding it
    /// here — otherwise the rule would render an empty popup instead
    /// of routing through the store.
    let knownSlashCommands: [SlashCommand]?
    /// Dispatcher for CCTerm-native builtin commands (`/new`, `/clear`).
    /// Non-nil only where builtins should be offered — the chat resting
    /// bar and the draft-landing bar. Nil on the New Session compose card
    /// (builtins are redundant there) and in headless contexts. When nil
    /// the slash rule offers no builtins and behaves exactly as before.
    let onBuiltinCommand: ((BuiltinSlashCommand) -> Void)?
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
    func match(
        text: String, cursorLocation: Int, context: CompletionTriggerContext
    ) -> CompletionState.CompletionSession? {
        guard cursorLocation == 1,
            cursorLocation <= text.count,
            text[text.startIndex] == "/"
        else { return nil }

        let onBuiltin = context.onBuiltinCommand

        // Builtin items (`/new`, `/clear`) are offered only when the host
        // bar wired a dispatcher; the compose card passes nil → none shown.
        // Filtered by the typed query so `/ne` narrows to `/new`.
        func builtinItems(matching query: String) -> [any CompletionItem] {
            guard onBuiltin != nil else { return [] }
            let q = query.lowercased()
            return BuiltinSlashCommand.allCases
                .filter { q.isEmpty || $0.rawValue.contains(q) }
                .map { BuiltinCompletionItem(command: $0) }
        }

        let makeReplacement: (any CompletionItem, String, Int) -> (range: NSRange, replacement: String) = {
            item, _, wordEnd in
            // A builtin fires its action on confirm and clears the typed
            // "/cmd"; a CLI command splices "/name " so the user can keep
            // typing arguments before sending.
            if item is BuiltinCompletionItem {
                return (range: NSRange(location: 0, length: wordEnd), replacement: "")
            }
            return (range: NSRange(location: 0, length: wordEnd), replacement: item.displayText + " ")
        }

        // Confirm-time side effect: dispatch the builtin's action. CLI
        // commands have none — their text replacement is the whole effect.
        let onItemConfirmed: (any CompletionItem) -> Void = { item in
            if let builtin = (item as? BuiltinCompletionItem)?.command {
                onBuiltin?(builtin)
            }
        }

        // No cwd → no CLI source to ask, but builtins need no directory, so
        // still surface them. Fall back to the "noDirectory" hint only when
        // builtins are disabled too.
        guard let dir = context.directory else {
            let builtinsAtRoot = builtinItems(matching: "")
            return .init(
                anchorLocation: 0,
                emptyReasonOverride: builtinsAtRoot.isEmpty ? .noDirectory : nil,
                provider: { query, cb in cb(builtinItems(matching: query)) },
                makeReplacement: makeReplacement,
                onItemConfirmed: onItemConfirmed
            )
        }

        let pluginDirs = context.pluginDirs
        let known = context.knownSlashCommands
        let builtinNames = Set(BuiltinSlashCommand.allCases.map(\.rawValue))

        return .init(
            anchorLocation: 0,
            provider: { query, cb in
                let builtins = builtinItems(matching: query)
                SlashCommandStore.shared.complete(
                    query: query,
                    path: dir,
                    pluginDirs: pluginDirs,
                    knownCommands: known
                ) { matches in
                    // Builtins lead the list and shadow any same-named CLI
                    // command so the popup never shows a duplicate.
                    let cliItems: [any CompletionItem] =
                        onBuiltin == nil
                        ? matches
                        : matches.filter { !builtinNames.contains($0.name) }
                    cb(builtins + cliItems)
                }
            },
            makeReplacement: makeReplacement,
            onItemConfirmed: onItemConfirmed
        )
    }
}

// MARK: - File Mention (@ when directory exists)

struct FileMentionTriggerRule: CompletionTriggerRule {
    func match(
        text: String, cursorLocation: Int, context: CompletionTriggerContext
    ) -> CompletionState.CompletionSession? {
        guard let dir = context.directory,
            isTriggerPosition(text: text, cursorLocation: cursorLocation, for: "@")
        else { return nil }

        let anchorLoc = cursorLocation - 1
        let allDirs: [String] = {
            var dirs = [dir]
            dirs.append(contentsOf: context.additionalDirs)
            return dirs
        }()

        return .init(
            anchorLocation: anchorLoc,
            headerText: String(localized: "Tab / Enter to confirm"),
            provider: { query, cb in
                if allDirs.count > 1 {
                    FileCompletionStore.shared.complete(query: query, in: allDirs) { matches in
                        cb(matches)
                    }
                } else {
                    FileCompletionStore.shared.complete(query: query, in: dir) { matches in
                        cb(matches)
                    }
                }
            },
            makeReplacement: { item, _, wordEnd in
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
                let closeQuote = text[afterQuote...].firstIndex(of: "\"")
            {
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
