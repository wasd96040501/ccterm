import AgentSDK
import AppKit
import Components
import DisplayModels
import XCTest

@testable import ccterm

/// The new kinds of work, the dividers that say why, a plugin's caption, and a
/// picture's document — light above dark. Review only — `make test-unit
/// FILTER=WorkKindsSnapshotTests`, then open `/tmp/ccterm-screenshots/WorkKinds-*.png`.
@MainActor
final class WorkKindsSnapshotTests: XCTestCase {
    func testTheRunsOfTheNewKinds() {
        var s = MessageScript()
        s.advisor("a1", .redacted)
        s.reply("One.")
        s.advisor("a2", .result(text: "Split the tab bar first, then the rest.", stopReason: nil))
        s.reply("Two.")
        s.advisor("a3", .error(code: "overloaded"))
        s.reply("Three.")
        s.call("s", "Skill", #"{"skill":"dataviz"}"#)
        s.result("s")
        s.call("w", "EnterWorktree", #"{"name":"fix-tabs"}"#)
        s.result("w")
        s.call("m", "SendMessage", #"{"to":"team-lead","summary":"Status","message":"Done."}"#)
        s.result("m")
        s.call("n", "PushNotification", #"{"message":"Build finished"}"#)
        s.result("n")
        PageSnapshot.render(
            s.page, widths: [560, 340], height: 420, disclosure: .expanded, name: "WorkKinds-runs", test: self)
    }

    func testTheDividersAndCaptions() {
        var s = MessageScript()
        s.prompt("Go")
        let page = TranscriptPage(
            entries: [
                .divider(SessionDivider(id: "a", kind: .continued(.usageLimitReset), prompt: "Continue.")),
                .divider(SessionDivider(id: "b", kind: .continued(.planApproved), prompt: "Plan.")),
                .divider(SessionDivider(id: "c", kind: .continued(.goal), prompt: "Goal set: ship")),
                .divider(SessionDivider(id: "d", kind: .continued(.automatic), prompt: "Go on.")),
                .divider(SessionDivider(id: "e", kind: .restarted(account: "Work", model: "Opus 4.5"))),
                .agentMessage(
                    AgentMessage(
                        id: "p1", sender: .plugin(name: "ralph-loop", duringTurn: false), name: "ralph-loop",
                        text: "Continue.", line: WorkLineWriter(workingDirectory: nil).line(forReportFrom: "x"))),
                .agentMessage(
                    AgentMessage(
                        id: "p2", sender: .plugin(name: "ralph-loop", duringTurn: true), name: "ralph-loop",
                        text: "Mind the tests.", line: WorkLineWriter(workingDirectory: nil).line(forReportFrom: "x"))),
            ])
        PageSnapshot.render(page, widths: [560, 340], height: 460, name: "WorkKinds-dividers", test: self)
    }
}
