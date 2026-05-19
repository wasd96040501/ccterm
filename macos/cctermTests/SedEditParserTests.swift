import XCTest

@testable import ccterm

/// Unit tests for the Swift port of upstream's `sedEditParser.ts`.
/// Covers the patterns Bash agents actually emit (simple `sed -i`),
/// fused-flag macOS variants, BRE/ERE conversion, and the negative
/// cases that should fall through to "show the literal command".
final class SedEditParserTests: XCTestCase {

    // MARK: - Parsing

    func testParsesSimpleInPlaceSubstitution() {
        let info = SedEditParser.parse("sed -i 's/foo/bar/g' file.swift")
        XCTAssertEqual(info?.filePath, "file.swift")
        XCTAssertEqual(info?.pattern, "foo")
        XCTAssertEqual(info?.replacement, "bar")
        XCTAssertEqual(info?.flags, "g")
        XCTAssertEqual(info?.extendedRegex, false)
    }

    func testParsesFusedDashIBackupSuffix() {
        // macOS uses `-i.bak`; this is the most common destructive
        // form on this codebase's dev machines.
        let info = SedEditParser.parse("sed -i.bak 's/foo/bar/' README.md")
        XCTAssertEqual(info?.filePath, "README.md")
        XCTAssertEqual(info?.pattern, "foo")
    }

    func testParsesMacOSEmptyBackupSuffix() {
        // `sed -i '' 's/...' file` — the empty suffix arg satisfies
        // BSD sed's mandatory `-i` argument.
        let info = SedEditParser.parse("sed -i '' 's/foo/bar/g' a.txt")
        XCTAssertEqual(info?.filePath, "a.txt")
        XCTAssertEqual(info?.flags, "g")
    }

    func testParsesExtendedRegexFlag() {
        let info = SedEditParser.parse("sed -E -i 's/foo+/bar/' f.txt")
        XCTAssertEqual(info?.extendedRegex, true)
        XCTAssertEqual(info?.pattern, "foo+")
    }

    func testRejectsNonSedCommand() {
        XCTAssertNil(SedEditParser.parse("awk '/foo/{print}' f.txt"))
    }

    func testRejectsSedWithoutInPlaceFlag() {
        // `sed 's/x/y/' file` reads to stdout. Treating this as a
        // file edit would be a lie — the file isn't touched.
        XCTAssertNil(SedEditParser.parse("sed 's/x/y/' f.txt"))
    }

    func testRejectsPipedCommands() {
        // ShellTokenizer bails on `|` so the parser never even sees
        // the substitution. Without this, a `sed -i ... | tee` chain
        // would mislead the diff view.
        XCTAssertNil(
            SedEditParser.parse("sed -i 's/x/y/' f.txt | tee out.txt"))
    }

    func testRejectsMultipleFiles() {
        XCTAssertNil(SedEditParser.parse("sed -i 's/x/y/' a.txt b.txt"))
    }

    func testRejectsExoticFlags() {
        // Flags we can't safely model (e.g. write-to-file `w`).
        XCTAssertNil(SedEditParser.parse("sed -i 's/x/y/w out.txt' f.txt"))
    }

    func testRejectsUnknownLongFlag() {
        XCTAssertNil(SedEditParser.parse("sed --quiet -i 's/x/y/' f.txt"))
    }

    func testRejectsAlternateDelimiter() {
        // Upstream only supports `/` as the substitution delimiter.
        XCTAssertNil(SedEditParser.parse("sed -i 's|x|y|g' f.txt"))
    }

    // MARK: - Substitution application

    func testApplyGlobalSubstitution() {
        let info = SedEditParser.parse("sed -i 's/foo/bar/g' f.txt")!
        XCTAssertEqual(
            info.apply(to: "foo foo foo"), "bar bar bar")
    }

    func testApplyFirstMatchOnlyWithoutGFlag() {
        let info = SedEditParser.parse("sed -i 's/foo/bar/' f.txt")!
        XCTAssertEqual(
            info.apply(to: "foo foo foo"), "bar foo foo")
    }

    func testApplyCaseInsensitiveFlag() {
        let info = SedEditParser.parse("sed -i 's/FOO/bar/gi' f.txt")!
        XCTAssertEqual(info.apply(to: "Foo foo FOO"), "bar bar bar")
    }

    func testBRESpecialCharsAreLiteral() {
        // Without -E, `+` is a literal plus. Without the BRE→ICU
        // dance the regex would treat `foo+` as a quantifier and
        // misreport "foo" alone as a match.
        let info = SedEditParser.parse("sed -i 's/foo+/X/g' f.txt")!
        XCTAssertEqual(info.apply(to: "foo foo+ bar"), "foo X bar")
    }

    func testEREPlusIsQuantifier() {
        let info = SedEditParser.parse("sed -E -i 's/fo+/X/g' f.txt")!
        XCTAssertEqual(info.apply(to: "fo foo fooo"), "X X X")
    }

    func testReplacementAmpersandIsMatch() {
        // `&` in the replacement = the matched text. Foundation's
        // template syntax uses `$0` — the parser bridges that.
        let info = SedEditParser.parse("sed -i 's/foo/[&]/g' f.txt")!
        XCTAssertEqual(info.apply(to: "foo bar"), "[foo] bar")
    }

    func testEscapedAmpersandIsLiteral() {
        let info = SedEditParser.parse("sed -i 's/foo/\\&/g' f.txt")!
        XCTAssertEqual(info.apply(to: "foo"), "&")
    }

    func testInvalidRegexFallsBackToOriginal() {
        // A pattern that doesn't compile (unbalanced `[`) shouldn't
        // crash — return the original content so the diff renders
        // zero hunks rather than a panic.
        let info = SedEditInfo(
            filePath: "x", pattern: "[unbalanced",
            replacement: "y", flags: "", extendedRegex: true)
        XCTAssertEqual(info.apply(to: "hello"), "hello")
    }
}
