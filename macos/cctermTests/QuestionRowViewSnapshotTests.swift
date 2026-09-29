import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// `QuestionRowView` in every state, light above dark, beside the design
/// (07-talk.md "AskUserQuestion"; preview.css `.qa`). Review only —
/// `make test-unit FILTER=QuestionRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/QuestionRowView.png`.
@MainActor
final class QuestionRowViewSnapshotTests: XCTestCase {
    private func question(_ json: String, answers: [String: String], waiting: Bool = false) throws -> Question {
        let input = try JSONDecoder().decode(
            Tools.AskUserQuestion.Input.self, from: Data(#"{"questions":\#(json)}"#.utf8))
        let use = ToolUseBlock(id: "q", name: "AskUserQuestion", input: MessageScript.json("{}"))
        let call = ToolCall(
            use: use, result: nil, kind: .other, state: waiting ? .waiting(reason: nil) : .done, startedAt: nil,
            finishedAt: nil)
        return Question(call: call, questions: input.questions, answers: answers)
    }

    private static let one =
        #"[{"question":"Which library should we use for date formatting?","header":"Auth method","options":[{"label":"date-fns","description":"Small, tree-shakeable"},{"label":"Moment","description":""}],"multiSelect":false}]"#
    private static let several =
        #"[{"question":"Which platforms should the first release support, and is there anything about the split editor we should settle before then?","header":"Targets","options":[{"label":"macOS","description":"14 and later"},{"label":"iOS","description":""},{"label":"visionOS","description":"Later"}],"multiSelect":true},{"question":"Ship it?","header":"Release","options":[{"label":"Yes","description":""},{"label":"No","description":"Wait for the next build"}],"multiSelect":false}]"#

    private func models() throws -> [Question] {
        [
            try question(Self.one, answers: ["Which library should we use for date formatting?": "date-fns"]),
            try question(
                Self.several,
                answers: [
                    "Which platforms should the first release support, and is there anything about the split editor we should settle before then?":
                        "macOS, iOS",
                    "Ship it?": "Yes",
                ]),
            try question(Self.one, answers: [:], waiting: true),
            try question(Self.several, answers: [:], waiting: true),
        ]
    }

    private func panel(_ appearance: NSAppearance.Name, width: CGFloat) throws -> NSView {
        let models = try models()
        let pad: CGFloat = 20
        let gap: CGFloat = 14
        let heights = models.map { QuestionRowView.height(for: $0, width: width) }
        let height = heights.reduce(0, +) + gap * CGFloat(models.count - 1) + 2 * pad
        let panel = FlippedView(frame: NSRect(x: 0, y: 0, width: width + 2 * pad, height: height))
        panel.appearance = NSAppearance(named: appearance)
        panel.wantsLayer = true
        panel.appearance?.performAsCurrentDrawingAppearance {
            panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        var y = pad
        for (model, rowHeight) in zip(models, heights) {
            let view = QuestionRowView()
            view.configure(with: model)
            view.frame = NSRect(x: pad, y: y, width: width, height: rowHeight)
            panel.addSubview(view)
            y += rowHeight + gap
        }
        return panel
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    func testEveryState() throws {
        var panels: [NSView] = []
        for width: CGFloat in [520, 320] {
            panels.append(try panel(.aqua, width: width))
            panels.append(try panel(.darkAqua, width: width))
        }
        let total = NSSize(
            width: panels[0].frame.width + panels[2].frame.width,
            height: panels[0].frame.height + panels[1].frame.height)
        let root = FlippedView(frame: NSRect(origin: .zero, size: total))
        panels[0].setFrameOrigin(NSPoint(x: 0, y: 0))
        panels[1].setFrameOrigin(NSPoint(x: 0, y: panels[0].frame.height))
        panels[2].setFrameOrigin(NSPoint(x: panels[0].frame.width, y: 0))
        panels[3].setFrameOrigin(NSPoint(x: panels[0].frame.width, y: panels[2].frame.height))
        panels.forEach(root.addSubview)
        let controller = NSViewController()
        controller.view = root

        let image = ViewSnapshot.renderViewController(controller, size: total)
        let url = ViewSnapshot.writePNG(image, name: "QuestionRowView")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(image.size, total)
    }
}
