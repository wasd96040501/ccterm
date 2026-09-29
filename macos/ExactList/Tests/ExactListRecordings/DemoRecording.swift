import AppKit
import ExactListDemoSupport
import ExactListTestSupport

/// One recording: a demo scenario, run in the demo's content off screen after
/// an optional setup, and captured by `WindowRecorder` into
/// `/tmp/exactlist-recordings/<name>/` (SPEC §13).
@MainActor
struct DemoRecording {

    /// The directory name, and what `make record-list FILTER=` matches.
    var name: String
    var scenario: DemoScenario
    /// How long after the action to capture, at most 3 s.
    var seconds: TimeInterval
    /// Which seconds after the action the sheet shows at 60 Hz.
    var sheet: ClosedRange<TimeInterval> = 0...0.5
    /// Puts the content in the state the recording starts from.
    var prepare: (DemoContentViewController) async throws -> Void = { _ in }

    /// One per scenario, plus the states a change needs looked at.
    static let all: [DemoRecording] = [
        // The first append lands at 0.35 s; the sheet shows it and the next.
        DemoRecording(name: "stream", scenario: .stream, seconds: 3, sheet: 0.3...0.8),
        // Deep in 10 000 rows, after an animated width change has reflowed them.
        DemoRecording(
            name: "stream-after-load-and-resize", scenario: .stream, seconds: 3, sheet: 0.3...0.8,
            prepare: { content in
                content.run(.loadLarge)
                content.run(.toggleSidebar)
                try await Task.sleep(nanoseconds: 800_000_000)
            }),
        DemoRecording(name: "grow-last-row", scenario: .growLastRow, seconds: 2),
        DemoRecording(name: "toggle-expand", scenario: .toggleClicked, seconds: 1),
        // Collapses what the first toggle expanded.
        DemoRecording(
            name: "toggle-collapse", scenario: .toggleClicked, seconds: 1,
            prepare: { content in
                content.run(.toggleClicked)
                try await Task.sleep(nanoseconds: 800_000_000)
            }),
        // The first churn lands at 0.5 s.
        DemoRecording(name: "churn-above", scenario: .churnAbove, seconds: 2, sheet: 0.45...0.95),
        DemoRecording(name: "toggle-sidebar", scenario: .toggleSidebar, seconds: 1),
        DemoRecording(name: "load-large", scenario: .loadLarge, seconds: 1),
        // From the tail of the demo's 60 rows.
        DemoRecording(name: "scroll-to-top", scenario: .scrollToTop, seconds: 1.5, sheet: 0...0.7),
        // Across 10 000 rows the resize left stale: each frame measures the
        // rows it brings into view.
        DemoRecording(
            name: "scroll-to-top-after-load-and-resize", scenario: .scrollToTop, seconds: 1.5, sheet: 0...0.7,
            prepare: { content in
                content.run(.loadLarge)
                content.run(.toggleSidebar)
                try await Task.sleep(nanoseconds: 800_000_000)
            }),
    ]

    /// Mounts the demo's content in a recordable stage, prepares it, lets it
    /// settle, then records the scenario.
    @available(macOS 14, *)
    func record() async throws -> WindowRecorder.Recording {
        let size = NSSize(width: 900, height: 640)
        let stage = ListStage(size: size, recordable: true)
        defer { stage.teardown() }
        let content = DemoContentViewController()
        stage.window.contentViewController = content
        stage.window.setContentSize(size)
        await stage.settle()
        try await prepare(content)
        await stage.settle()
        try await Task.sleep(nanoseconds: 300_000_000)
        return try await WindowRecorder.record(stage.window, named: name, seconds: seconds, sheet: sheet) {
            content.run(scenario)
        }
    }
}
