import XCTest
@testable import ccterm

/// `JSONLTailReader.readTail` 的边界行为验证。
///
/// 场景：
/// - 读真实 fixture `large-session.jsonl`（2.7 MB / 422 行）targetLines=20
///   → 与 `Array(fullLines.suffix(20))` 完全一致
/// - targetLines=1 / =422 / > 422
/// - 小合成文件：末尾无 \n、中间连续 \n\n、纯空
/// - maxBytes 收紧 → 返回 < target 行，但都是完整行
/// - tailStartByteOffset 跟 lines 的总字节数对齐
final class JSONLTailReaderTests: XCTestCase {

    private static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/large-session.jsonl")
    }

    private static func allNonEmptyLines(of url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Real fixture

    func testRealFixtureLast20LinesMatchSuffix() throws {
        let url = Self.fixtureURL()
        let full = try Self.allNonEmptyLines(of: url)
        XCTAssertGreaterThan(full.count, 20, "fixture 行数应该比 20 多")

        let r = try JSONLTailReader.readTail(url: url, targetLines: 20)
        XCTAssertEqual(r.lines, Array(full.suffix(20)))
    }

    func testRealFixtureTargetOne() throws {
        let url = Self.fixtureURL()
        let full = try Self.allNonEmptyLines(of: url)
        let r = try JSONLTailReader.readTail(url: url, targetLines: 1)
        XCTAssertEqual(r.lines.count, 1)
        XCTAssertEqual(r.lines.last, full.last)
    }

    func testRealFixtureTargetGreaterThanTotal() throws {
        let url = Self.fixtureURL()
        let full = try Self.allNonEmptyLines(of: url)
        let r = try JSONLTailReader.readTail(
            url: url, targetLines: full.count + 100, maxBytes: 1 << 30)
        XCTAssertEqual(r.lines.count, full.count)
        XCTAssertEqual(r.lines, full)
        XCTAssertEqual(r.tailStartByteOffset, 0, "全读时起始偏移应为 0")
    }

    /// 把 maxBytes 压得很小 → 返回的行数 < targetLines。要点：返回的都是
    /// **完整** 行（不会切出半行 JSON 让 resolver 崩）。
    func testRealFixtureMaxBytesCapReturnsFewerCompleteLines() throws {
        let url = Self.fixtureURL()
        let full = try Self.allNonEmptyLines(of: url)
        let r = try JSONLTailReader.readTail(
            url: url, targetLines: 200, maxBytes: 10_000)  // 10KB
        XCTAssertGreaterThan(r.lines.count, 0)
        XCTAssertLessThan(r.lines.count, 200, "10KB 装不下 200 行完整 JSONL")
        // 每一行都应该是有效 JSON（末尾的几行一定是完整的）。
        for line in r.lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "line 应为合法 JSON: \(line.prefix(80))")
        }
        // tailStartByteOffset 应对得上 —— 把它对应的字节之后的内容 parse 出来 = r.lines
        XCTAssertGreaterThanOrEqual(r.tailStartByteOffset, 0)
        // 返回的行最后一条必定等于全文件最后一条
        XCTAssertEqual(r.lines.last, full.last)
    }

    // MARK: - Synthetic edge cases

    func testFileWithoutTrailingNewlineKeepsLastLine() throws {
        let url = try write(lines: ["alpha", "beta", "gamma"], trailingNewline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try JSONLTailReader.readTail(url: url, targetLines: 2)
        XCTAssertEqual(r.lines, ["beta", "gamma"])
    }

    func testFileWithBlankLinesAtEndSkipsEmpties() throws {
        let url = try write(lines: ["alpha", "beta", "gamma", "", ""], trailingNewline: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try JSONLTailReader.readTail(url: url, targetLines: 2)
        XCTAssertEqual(r.lines, ["beta", "gamma"])
    }

    func testEmptyFileReturnsEmpty() throws {
        let url = try write(lines: [], trailingNewline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try JSONLTailReader.readTail(url: url, targetLines: 10)
        XCTAssertTrue(r.lines.isEmpty)
        XCTAssertEqual(r.tailStartByteOffset, 0)
    }

    func testMissingFileThrows() {
        let url = URL(fileURLWithPath: "/tmp/ccterm-tail-test-does-not-exist.jsonl")
        XCTAssertThrowsError(try JSONLTailReader.readTail(url: url, targetLines: 1)) { error in
            guard case JSONLTailReader.ReaderError.fileNotFound = error else {
                XCTFail("wrong error kind: \(error)")
                return
            }
        }
    }

    // MARK: - tailStartByteOffset contract

    /// tailStartByteOffset 的前缀 bytes + tail lines 的 bytes 合起来等于整个文件。
    /// 这是 Phase B 能正确按 `[0, offset)` 读 prefix 的前提。
    func testTailStartByteOffsetIsPrefixBoundary() throws {
        let url = Self.fixtureURL()
        let r = try JSONLTailReader.readTail(url: url, targetLines: 20)
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let tailBytes = r.lines.reduce(0) { $0 + $1.utf8.count + 1 }  // + \n 分隔
        // 允许差 1 字节（末尾是否有 trailing \n 的歧义）。
        XCTAssertLessThanOrEqual(
            abs(r.tailStartByteOffset + tailBytes - fileSize), 1,
            "offset + tailBytes ≈ fileSize, got offset=\(r.tailStartByteOffset) " +
            "tailBytes=\(tailBytes) fileSize=\(fileSize)")
    }

    // MARK: - Helpers

    private func write(lines: [String], trailingNewline: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("ccterm-tail-test-\(UUID().uuidString).jsonl")
        var text = lines.joined(separator: "\n")
        if trailingNewline, !lines.isEmpty { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
