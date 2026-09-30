import XCTest

@testable import ccterm

/// Every shape of a local command's row, light above dark
/// (design/transcript/05-local.md). Review only — `make test-unit
/// FILTER=CapsuleRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/CapsuleRowView.png`.
@MainActor
final class CapsuleRowViewSnapshotTests: XCTestCase {
    func testEveryShape() {
        let models = [
            LocalCommand(
                id: "1", command: .slash(name: "/model", arguments: "opus"), output: "Set model to opus",
                errorOutput: ""),
            LocalCommand(
                id: "2", command: .slash(name: "/skill-creator:skill-creator", arguments: "make a skill"), output: "",
                errorOutput: ""),
            LocalCommand(
                id: "3", command: .slash(name: "/usage", arguments: ""),
                output: "Plan: Max\nWeek: 41%\nToday: 7%\nReset: Tue", errorOutput: ""),
            LocalCommand(
                id: "4", command: .slash(name: "/login", arguments: ""), output: "", errorOutput: "Not logged in"),
            LocalCommand(
                id: "5", command: .shell("git status"), output: "On branch main\nnothing to commit\nclean\n",
                errorOutput: ""),
            LocalCommand(id: "6", command: .shell("pwd"), output: "/Users/me/repo\n", errorOutput: ""),
            LocalCommand(id: "7", command: .shell("false"), output: "", errorOutput: "exit 1"),
        ]
        RowSnapshot.render(CapsuleRowView.self, models, name: "CapsuleRowView", test: self)
    }
}
