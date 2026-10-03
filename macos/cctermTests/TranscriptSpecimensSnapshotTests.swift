import AgentSDK
import AppKit
import DisplayModels
import TranscriptKit
import XCTest

@testable import ccterm

/// The transcript views design b39b044 added or changed, each beside the
/// sheet's own specimen (`<scheme>-spec-<section>-<i>` in `make design-shots`),
/// built the way a session builds them — the CLI's messages through
/// `TranscriptPageBuilder` — with the specimen's words:
/// - `local`: a command as the user's bubble with its token (0–3), `!` commands (7);
/// - `prompts`: pasted pictures over the bubble (0–2);
/// - `voices`: a plugin between turns and while Claude worked, turns the CLI
///   continued on its own (3–5);
/// - `talkout`: the advisor, SendMessage, skills, worktrees, notifications (0–6);
/// - `talk`: questions with two-line options, several and multi-select,
///   answered with *Other*, talked over (1–3).
/// Review only — `TEST_LANGUAGE=en make test-unit FILTER=TranscriptSpecimensSnapshotTests`
/// after `make design-shots`, then `/tmp/ccterm-parity/<scheme>-spec-*.png`.
/// Needs the display awake.
@MainActor
final class TranscriptSpecimensSnapshotTests: XCTestCase {
    /// The transcript's side margin, cropped away: the sheet's column has none.
    private static let margin: CGFloat = 20

    private struct Specimen {
        var id: String
        var page: TranscriptPage
        var disclosure: RunDisclosure = .collapsed
    }

    func testTheSpecimensAgainstTheDesign() async throws {
        for scheme in DesignParity.Scheme.allCases {
            for specimen in try specimens() {
                let part = try DesignParity.part(specimen.id, scheme)
                let image = try await column(specimen, part: part, scheme: scheme)
                let attachment = XCTAttachment(contentsOfFile: try DesignParity.write(specimen.id, scheme, ours: image))
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    // MARK: - The specimens

    private func specimens() throws -> [Specimen] {
        [
            Specimen(id: "spec-local-0", page: page { command(&$0, "/model", "opus", output: "Set model to opus") }),
            Specimen(
                id: "spec-local-1",
                page: page {
                    command(&$0, "/effort", "maximum")
                    $0.user("<local-command-stderr>Unknown effort level: maximum</local-command-stderr>")
                    command(&$0, "/skill-creator:skill-creator", "")
                }),
            Specimen(
                id: "spec-local-2",
                page: page {
                    command(
                        &$0, "/dataviz",
                        "Pull the latest code. This PR is only about designing live-session interaction — the New tab, the + on every tab bar, and the composer."
                    )
                }),
            Specimen(
                id: "spec-local-3",
                page: page {
                    command(
                        &$0, "/context", "",
                        output:
                            "61k / 200k tokens (31%)\n\n- System prompt: 3.1k\n- Tools: 14.2k\n- Messages: 43.9k")
                }),
            Specimen(
                id: "spec-local-7",
                page: page {
                    $0.user("<bash-input>git status --short</bash-input>")
                    $0.user(
                        "<bash-stdout> M design/transcript/preview.js\n M design/transcript/preview.css\n?? design/transcript/shots/\n M macos/Makefile</bash-stdout><bash-stderr></bash-stderr>"
                    )
                    $0.user("<bash-input>git branch --show-current</bash-input>")
                    $0.user("<bash-stdout>transcript-views-design</bash-stdout><bash-stderr></bash-stderr>")
                }),
            Specimen(
                id: "spec-prompts-0",
                page: page {
                    $0.prompt(
                        "[Image #1] The top of the transcript is cut off near the toolbar — is the composer pushing it up?",
                        images: [ImageFixture.png(width: 1440, height: 900)], pasteIDs: [1])
                }),
            Specimen(
                id: "spec-prompts-1",
                page: page {
                    $0.prompt(
                        "[Image #2] is the build log, [Image #3] the window right after. Which one is wrong?",
                        images: [
                            ImageFixture.png(width: 1200, height: 760, hue: 0.65),
                            ImageFixture.png(width: 900, height: 1100, hue: 0.1),
                        ], pasteIDs: [2, 3])
                }),
            Specimen(
                id: "spec-prompts-2",
                page: page {
                    $0.prompt("[Image #1]", images: [ImageFixture.png(width: 1440, height: 900)], pasteIDs: [1])
                }
            ),
            Specimen(
                id: "spec-voices-3",
                page: page {
                    $0.user(plugin("taskcut", "Continue.", duringTurn: false), origin: "plugin")
                    $0.reply("Picking up item 9b: plugin prompts, then pasted images.")
                }),
            Specimen(
                id: "spec-voices-4",
                page: page {
                    edit(&$0, "e", "design/transcript/preview.js", added: 12, removed: 3)
                    bash(&$0, "b", "node check.js", "Run the sheet's checks")
                    $0.user(
                        plugin(
                            "ralph-loop", "The tests on main are red; fix them before the next item.", duringTurn: true),
                        origin: "plugin")
                    bash(&$0, "c", "make test-unit", "Run the unit tests")
                }),
            Specimen(
                id: "spec-voices-5",
                page: dividers {
                    $0.prompt("Go on with the list.")
                    $0.reply("On it.")
                    $0.user(
                        "Your claude.ai usage limit has reset. Continue the task you were working on when the limit was reached; do not repeat work that is already complete.",
                        origin: "auto-continuation")
                    $0.reply("Continuing.")
                    $0.user(
                        "The user approved the ultraplan in the browser. Implement it.", origin: "auto-continuation")
                }),
            Specimen(id: "spec-talkout-0", page: page { $0.advisor("v", .redacted) }),
            Specimen(
                id: "spec-talkout-1",
                page: page {
                    edit(
                        &$0, "e", "macos/TranscriptKit/Sources/TranscriptKit/TranscriptView.swift", added: 4, removed: 2
                    )
                    $0.advisor("v", .redacted)
                    bash(&$0, "k", "make test-kit", "Run the kit tests")
                }, disclosure: .expanded),
            Specimen(
                id: "spec-talkout-2",
                page: page {
                    $0.advisor(
                        "v",
                        .result(
                            text:
                                "Check the narrow split before you change the default: at 320 pt the run rows wrap, and a 14-pt gap reads as a new paragraph there.\n\nKeep `EditorAreaTests` on its own value; it pins the editor, not the transcript.",
                            stopReason: nil), model: "claude-opus-5-5")
                }),
            Specimen(
                id: "spec-talkout-3",
                // Two runs of one, as the sheet has them: a reply between, left out.
                page: runs {
                    $0.advisor("v", .result(text: "", stopReason: "refusal"))
                    $0.reply("Then I'll go ahead.")
                    $0.advisor("w", .error(code: "overloaded"))
                }),
            Specimen(
                id: "spec-talkout-4",
                page: page {
                    message(
                        &$0, "m", to: "team-lead", summary: "Row gap is public; tests pass",
                        "`TranscriptView.rowSpacing` is public now and defaults to 14 pt.")
                }),
            Specimen(
                id: "spec-talkout-5",
                page: page {
                    message(
                        &$0, "m", to: "team-lead", summary: "Row gap is public; tests pass",
                        "`TranscriptView.rowSpacing` is public now and defaults to 14 pt.")
                    message(
                        &$0, "q", to: "qa", summary: "Please check a 320-pt split",
                        "Could you look at the transcript in a 320-pt split with the new gap?")
                }, disclosure: .expanded),
            Specimen(
                id: "spec-talkout-6",
                page: page {
                    $0.call("s", "Skill", #"{"skill":"dataviz"}"#)
                    $0.result("s", "Launching skill: dataviz")
                    $0.call("w", "EnterWorktree", #"{"name":"quiet-otter"}"#)
                    $0.result(
                        "w", "Created worktree at /r/.claude/worktrees/quiet-otter on branch worktree-quiet-otter")
                    $0.call("n", "PushNotification", #"{"message":"Tests pass — ready for review"}"#)
                    $0.result("n", "Notification sent")
                }, disclosure: .expanded),
            Specimen(id: "spec-talk-1", page: try question(Self.rowGap, answers: [:], waiting: true)),
            Specimen(id: "spec-talk-2", page: try question(Self.scopeAndChecks, answers: [:], waiting: true)),
            Specimen(
                id: "spec-talk-3",
                page: TranscriptPage(entries: [
                    try questionEntry(
                        Self.rowGap,
                        answers: ["What should the default gap between rows be?": "13 pt — between the two"],
                        id: "q1"),
                    try questionEntry(Self.rowGap, answers: [:], id: "q2", talkedOver: true),
                ])),
        ]
    }

    // MARK: - Building pages

    private func page(_ write: (inout MessageScript) -> Void) -> TranscriptPage {
        var script = MessageScript()
        write(&script)
        return script.page
    }

    /// Only the runs of `write`'s page.
    private func runs(_ write: (inout MessageScript) -> Void) -> TranscriptPage {
        TranscriptPage(entries: page(write).entries.filter { if case .run = $0 { true } else { false } })
    }

    /// Only the dividers of `write`'s page: the turns around them are there
    /// for the CLI's messages to be what they are, and the specimen draws none.
    private func dividers(_ write: (inout MessageScript) -> Void) -> TranscriptPage {
        TranscriptPage(entries: page(write).entries.filter { if case .divider = $0 { true } else { false } })
    }

    private func command(_ s: inout MessageScript, _ name: String, _ arguments: String, output: String? = nil) {
        s.user(
            "<command-name>\(name)</command-name><command-message>\(name)</command-message><command-args>\(arguments)</command-args>"
        )
        if let output { s.user("<local-command-stdout>\(output)</local-command-stdout>") }
    }

    /// A plugin's prompt as the CLI relays it.
    private func plugin(_ name: String, _ text: String, duringTurn: Bool) -> String {
        duringTurn
            ? """
            The \(name) plugin sent a message while you were working:
            \(text)

            This is how Claude Code surfaces prompts a plugin submits mid-turn — within the running turn, often alongside the next tool result. Address the message above as you continue this turn.
            """
            : """
            The \(name) plugin sent a message:
            \(text)

            This is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above.
            """
    }

    /// An Edit of `path` that adds `added` lines and removes `removed`.
    private func edit(_ s: inout MessageScript, _ id: String, _ path: String, added: Int, removed: Int) {
        let old = (1...removed).map { "old line \($0)" }.joined(separator: "\\n")
        let new = (1...added).map { "new line \($0)" }.joined(separator: "\\n")
        s.call(id, "Edit", #"{"file_path":"/r/\#(path)","old_string":"\#(old)","new_string":"\#(new)"}"#)
        s.result(id, "The file has been updated.")
    }

    private func bash(_ s: inout MessageScript, _ id: String, _ command: String, _ description: String) {
        s.call(id, "Bash", #"{"command":"\#(command)","description":"\#(description)"}"#)
        s.result(id, "ok")
    }

    private func message(_ s: inout MessageScript, _ id: String, to: String, summary: String, _ text: String) {
        s.call(id, "SendMessage", #"{"to":"\#(to)","summary":"\#(summary)","message":"\#(text)"}"#)
        s.result(id, "Message sent to \(to)")
    }

    // MARK: - Questions

    private static let rowGap =
        #"[{"header":"Row gap","question":"What should the default gap between rows be?","options":[{"label":"14 pt","description":"Today's value"},{"label":"12 pt","description":"Same as between paragraphs"},{"label":"16 pt","description":"Roomier"}],"multiSelect":false}]"#

    private static let scopeAndChecks =
        #"[{"header":"Scope","question":"The gap is hard-coded in two places besides the view. Which of them should read the new property, and which should keep their own value?","options":[{"label":"Both read rowSpacing","description":"TranscriptView and EditorArea always agree, and a change in one place moves both. The tests that pin 14 pt need updating."},{"label":"Only TranscriptView","description":"EditorArea keeps its own 14 pt for now; the two can drift, which is fine while it has no transcript of its own."},{"label":"Neither — a theme value","description":"Move the gap into the theme, which both read. Most work, and the theme has no spacing values yet."}],"multiSelect":false},{"header":"Checks","question":"What should run before the PR?","options":[{"label":"Unit tests","description":"make test-unit and make test-kit"},{"label":"Snapshot of a narrow split","description":"TranscriptSnapshotTests at 320 pt"},{"label":"The demo app","description":"make demo-kit, to look at it by hand"}],"multiSelect":true}]"#

    private func question(_ json: String, answers: [String: String], waiting: Bool) throws -> TranscriptPage {
        TranscriptPage(entries: [try questionEntry(json, answers: answers, id: "q", waiting: waiting)])
    }

    /// A question as the page holds it: waiting for its answer, answered, or
    /// talked over (*Chat About This*: the CLI's clarify feedback as the result).
    private func questionEntry(
        _ json: String, answers: [String: String], id: String, waiting: Bool = false, talkedOver: Bool = false
    ) throws -> TranscriptEntry {
        let input = try JSONDecoder().decode(
            Tools.AskUserQuestion.Input.self, from: Data(#"{"questions":\#(json)}"#.utf8))
        let use = ToolUseBlock(id: id, name: "AskUserQuestion", input: MessageScript.json("{}"))
        let state: ToolCallState =
            waiting
            ? .waiting(reason: nil)
            : talkedOver
                ? .failed(
                    message:
                        "The user wants to clarify these questions. This means they may have additional information, context or questions for you. Start by asking them what they would like to clarify."
                ) : .done
        let call = ToolCall(use: use, result: nil, kind: .other, state: state, startedAt: nil, finishedAt: nil)
        return .question(Question(call: call, questions: input.questions, answers: answers), call: call)
    }

    // MARK: - Capture

    /// The page's rows as the screen shows them, in a column `part.width` wide
    /// on the window's background, from the first row's top down to the last
    /// row's foot (or the part's height, whichever is more).
    private func column(
        _ specimen: Specimen, part: DesignParity.Part, scheme: DesignParity.Scheme
    ) async throws
        -> NSImage
    {
        let host = PageSnapshot.Host(page: specimen.page, disclosure: specimen.disclosure)
        let size = NSSize(width: part.width + 2 * Self.margin, height: max(part.height + 160, 360))
        let window = CompositedCapture.mount(host, size: size, appearance: scheme.appearance)
        defer {
            window.contentViewController = nil
            window.close()
        }
        scheme.appearance?.performAsCurrentDrawingAppearance {
            host.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.transcript.numberOfRows, 0, "\(specimen.id): the transcript shows no rows")
        // `rect(ofRow:)` measures y down from the transcript's top, which is the window's.
        let rows = (0..<host.transcript.numberOfRows).map { host.transcript.rect(ofRow: $0) }
            .reduce(NSRect.null) { $0.union($1) }
        let image = try await CompositedCapture.pointImage(of: window)
        let height = max(part.height, ceil(rows.height))
        let crop = NSRect(x: Self.margin, y: size.height - rows.minY - height, width: part.width, height: height)
        let out = NSImage(size: crop.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: crop.size), from: crop, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
