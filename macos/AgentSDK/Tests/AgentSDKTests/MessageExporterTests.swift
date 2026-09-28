import XCTest

@testable import AgentSDK

final class MessageExporterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Lines seen before the session id is known land at the top of that
    /// session's file, in order.
    func testHeldLinesFlushIntoTheSessionFile() throws {
        let exporter = MessageExporter(directory: directory)
        exporter.append(Data("a".utf8), sessionID: nil)
        exporter.append(Data("b".utf8), sessionID: "s1")
        exporter.append(Data("c".utf8), sessionID: "s1")
        exporter.close()

        XCTAssertEqual(try lines(in: "s1.jsonl"), ["a", "b", "c"])
    }

    /// A session that never learns its id (never ran a turn) still exports
    /// what it saw.
    func testCloseFlushesLinesWithoutASessionID() throws {
        let exporter = MessageExporter(directory: directory)
        exporter.append(Data("a".utf8), sessionID: nil)
        exporter.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("unidentified-"))
        XCTAssertEqual(try lines(in: files[0]), ["a"])
    }

    private func lines(in name: String) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
}
