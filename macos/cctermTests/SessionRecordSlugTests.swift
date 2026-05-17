import XCTest

@testable import ccterm

/// `SessionRecord.slug` is a 1:1 port of Claude CLI's `sanitizePath`
/// (sessionStoragePortable.ts in v2.1.88). It's the only function that
/// translates a Swift-side cwd into the directory name Claude CLI writes
/// under `~/.claude/projects/`. The match must be byte-identical or
/// `historyJSONLURL` can't find anything to load.
///
/// CLI algorithm:
///   `name.normalize('NFC').replace(/[^a-zA-Z0-9]/g, '-')`, then if
///   the result exceeds 200 chars, truncate to 200 and append
///   `-<djb2(name)>` in base 36.
///
/// Each test below pins down a specific case the JS `[^a-zA-Z0-9]`
/// regex handles distinctively — `.`/`/`/` ` (the basic punctuation),
/// CJK and emoji (the UTF-16-code-unit edge cases), arbitrary ASCII
/// symbols, and the long-path hash branch.
///
/// Regression target: a prior version of `slug` only translated `/` and
/// ` `, leaving `.` intact. Worktree sessions land at a cwd like
/// `/Users/x/code/repo/.claude/worktrees/foo`; the on-disk directory is
/// `-...-repo--claude-worktrees-foo` (double dash for `.`). After app
/// restart, clicking the worktree session rendered an empty transcript
/// — the JSONL did exist, the lookup just missed it by one character
/// class.
final class SessionRecordSlugTests: XCTestCase {

    // MARK: - Basic punctuation

    /// Pure ASCII path with no specials. Sanity check that the
    /// pre-existing behavior for `/` mapping is preserved.
    func testSlugBasicAsciiPath() {
        XCTAssertEqual(
            SessionRecord(sessionId: UUID().uuidString, cwd: "/Users/foo/my-project").slug,
            "-Users-foo-my-project"
        )
    }

    /// Space → `-`. Same rule as `/`. Verified against the real disk
    /// slug for `Library/Application Support/...`.
    func testSlugReplacesSpace() {
        XCTAssertEqual(
            SessionRecord(
                sessionId: UUID().uuidString,
                cwd: "/Users/x/Library/Application Support/ccterm/tmp"
            ).slug,
            "-Users-x-Library-Application-Support-ccterm-tmp"
        )
    }

    /// **Bug-1 regression case.** `.claude/worktrees/<name>` must
    /// produce `--claude-worktrees-<name>` (double dash for `.`). This
    /// matches the real on-disk slug at
    /// `~/.claude/projects/-Users-luoyangze-code-ccterm--claude-worktrees-musing-gould-f88134/`.
    func testSlugReplacesDotsInWorktreePath() {
        XCTAssertEqual(
            SessionRecord(
                sessionId: UUID().uuidString,
                cwd: "/Users/luoyangze/code/ccterm/.claude/worktrees/musing-gould-f88134"
            ).slug,
            "-Users-luoyangze-code-ccterm--claude-worktrees-musing-gould-f88134"
        )
    }

    /// `.` replacement isn't special-cased to `.claude` — any segment
    /// with a dot folds the same way.
    func testSlugReplacesArbitraryDots() {
        XCTAssertEqual(
            SessionRecord(sessionId: UUID().uuidString, cwd: "/tmp/some.weird.dir/proj").slug,
            "-tmp-some-weird-dir-proj"
        )
    }

    // MARK: - Symbols beyond `/`, `.`, space

    /// Arbitrary ASCII punctuation: colon, plus, parens, ampersand, etc.
    /// CLI regex `[^a-zA-Z0-9]` folds every one of them to `-`. Hyphens
    /// pass through (a `-` → `-` map is a no-op).
    func testSlugFoldsArbitraryAsciiSymbols() {
        XCTAssertEqual(
            SessionRecord(
                sessionId: UUID().uuidString,
                cwd: "/tmp/proj:1.0+rc(2)&final/x"
            ).slug,
            "-tmp-proj-1-0-rc-2--final-x"
        )
    }

    // MARK: - Non-ASCII

    /// CJK characters live in the BMP — each is **one** UTF-16 code
    /// unit, so each one becomes a single `-` (not multiple). Verified
    /// against the JS regex behavior on `'/x/我的'`.
    func testSlugFoldsCJKToSingleDashEach() {
        // "/x/我的" → utf16 [0x2F, 0x78, 0x2F, 0x6211, 0x7684] → "-x---"
        XCTAssertEqual(
            SessionRecord(sessionId: UUID().uuidString, cwd: "/x/我的").slug,
            "-x---"
        )
    }

    /// Supplementary-plane scalars (emoji) are encoded as a UTF-16
    /// surrogate **pair**, so the JS regex replaces each half — one
    /// emoji becomes **two** `-`. Lock this down because the Swift
    /// `unicodeScalars` view would naively produce a single `-` for the
    /// same input; we deliberately walk `utf16` to mirror the CLI.
    func testSlugFoldsEmojiToTwoDashes() {
        // "/x/😀" → utf16 [0x2F, 0x78, 0x2F, 0xD83D, 0xDE00] → "-x---"
        XCTAssertEqual(
            SessionRecord(sessionId: UUID().uuidString, cwd: "/x/😀").slug,
            "-x---"
        )
    }

    /// Accented Latin letters (`é`, `ñ`, `ü`, ...) are non-alphanumeric
    /// to JS regex's plain `[a-zA-Z0-9]` class — they're not ASCII
    /// letters. Each precomposed form is one code unit → one `-`.
    /// NFC normalization ensures `é` doesn't decompose into `e + ◌́`
    /// (two units, which would emit `e-` instead of `-`).
    func testSlugFoldsAccentedLetters() {
        XCTAssertEqual(
            SessionRecord(sessionId: UUID().uuidString, cwd: "/tmp/café/x").slug,
            "-tmp-caf--x"
        )
    }

    // MARK: - Length cap + hash branch

    /// At exactly the cap (200 chars after sanitization) no hash is
    /// appended — only `> 200` triggers truncation.
    func testSlugAtExactCapNoHash() {
        // Build a path whose sanitized form is exactly 200 chars: one
        // leading `-` (from `/`) + 199 letters.
        let path = "/" + String(repeating: "a", count: 199)
        let slug = SessionRecord(sessionId: UUID().uuidString, cwd: path).slug
        XCTAssertEqual(slug?.count, 200)
        XCTAssertEqual(slug, "-" + String(repeating: "a", count: 199))
    }

    /// One past the cap → truncate to 200 + `-` + djb2(name) in base
    /// 36. Verifies both the length and the deterministic hash value.
    ///
    /// Computed offline against the CLI's djb2 impl over the original
    /// (un-sanitized, NFC-normalized) name. djb2 of
    /// `/` followed by 200 `a`s is reproducible.
    func testSlugOverCapAppendsDjb2Hash() {
        // 201-char path: `/` + 200 `a`s. Sanitized → `-` + 200 `a`s
        // (length 201), exceeds cap.
        let name = "/" + String(repeating: "a", count: 200)
        let slug = SessionRecord(sessionId: UUID().uuidString, cwd: name).slug
        let expectedHash = referenceDjb2HashBase36(name)
        let expectedPrefix = "-" + String(repeating: "a", count: 199)
        XCTAssertEqual(slug, "\(expectedPrefix)-\(expectedHash)")
    }

    // MARK: - Nil

    func testSlugReturnsNilWhenCwdMissing() {
        XCTAssertNil(SessionRecord(sessionId: UUID().uuidString, cwd: nil).slug)
    }

    // MARK: - Helpers

    /// Reference impl of the CLI's djb2 (hash.ts) for cross-checking
    /// the hash branch. Mirrors the production impl exactly — Int32
    /// signed wrap, abs lifted into Int64 so Int32.min survives,
    /// base-36 stringified.
    private func referenceDjb2HashBase36(_ str: String) -> String {
        var hash: Int32 = 0
        for unit in str.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        return String(abs(Int64(hash)), radix: 36)
    }
}
