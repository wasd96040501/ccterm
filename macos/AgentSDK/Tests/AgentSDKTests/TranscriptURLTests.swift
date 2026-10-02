import XCTest

@testable import AgentSDK

/// `SessionDirectory.transcriptURL`: the CLI's project-folder naming.
final class TranscriptURLTests: XCTestCase {
    private let directory = SessionDirectory(url: URL(fileURLWithPath: "/projects"))

    private func folder(_ path: String) -> String {
        directory.transcriptURL(forSession: "id", workingDirectory: URL(fileURLWithPath: path))
            .deletingLastPathComponent().lastPathComponent
    }

    func testEveryCharacterOutsideLettersAndDigitsBecomesADash() {
        XCTAssertEqual(folder("/nonexistent/dev/my_app.v2"), "-nonexistent-dev-my-app-v2")
        XCTAssertEqual(folder("/nonexistent/日本"), "-nonexistent---")
        XCTAssertEqual(folder("/nonexistent/😀"), "-nonexistent---")
    }

    func testTheFileIsTheSessionIDInThatFolder() {
        let url = directory.transcriptURL(forSession: "abc", workingDirectory: URL(fileURLWithPath: "/nonexistent/x"))
        XCTAssertEqual(url.path, "/projects/-nonexistent-x/abc.jsonl")
    }

    func testSymlinksAreResolvedAsTheCLIsWorkingDirectoryIs() {
        XCTAssertEqual(folder("/tmp"), "-private-tmp")
    }

    /// The expected hash was computed apart from the implementation, by the
    /// CLI's rule: `hash * 31 + unit` over the path in 32 bits, abs, base 36.
    func testALongPathIsCutAndHashed() {
        let path = "/x" + String(repeating: "/abcdefghij", count: 25)
        let cut = String(path.map { $0 == "/" ? "-" : $0 }.prefix(200))
        XCTAssertEqual(folder(path), cut + "-ocltit")
    }

    func testAPathAtTheLimitIsKept() {
        XCTAssertEqual(folder("/" + String(repeating: "a", count: 199)).count, 200)
    }
}
