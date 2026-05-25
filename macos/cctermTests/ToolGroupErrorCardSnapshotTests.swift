import AppKit
import XCTest

@testable import ccterm

/// Visual self-check for the uniform tool-result error card. Mounts a
/// real transcript (production attach sequence via `MountedTranscript`),
/// expands a group whose children each failed, and writes a PNG of the
/// rendered red error cards under `/tmp/ccterm-screenshots/`.
///
/// Review-only — skipped on the default suite + CI (filename suffix).
/// Run: `make test-unit FILTER=ToolGroupErrorCardSnapshotTests`
/// then `open /tmp/ccterm-screenshots/ToolGroupErrorCard.png`.
@MainActor
final class ToolGroupErrorCardSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testErrorCardsRender() {
        let controller = Transcript2Controller()

        let groupId = UUID()
        let bashId = UUID()
        let genericId = UUID()
        let editId = UUID()
        let group = ToolGroupBlock(
            activeTitle: "Running tools",
            expandedActiveTitle: "Running 3 tools",
            completedTitle: "Ran 3 tools",
            children: [
                .bash(
                    BashChild(
                        id: bashId,
                        label: "Ran 'rm …'",
                        activeLabel: "Running 'rm …'",
                        command: "rm -rf /protected/path",
                        stdout: nil,
                        stderr: nil,
                        errorText:
                            "Permission to use Bash has been denied. The command tried to remove a protected path.")),
                .fileEdit(
                    FileEditChild(
                        id: editId,
                        label: "Edit Greeter.swift",
                        activeLabel: "Editing Greeter.swift",
                        filePath: "Greeter.swift",
                        diff: DiffBlock(
                            filePath: "Greeter.swift",
                            oldString: "let greeting = \"Hi\"",
                            newString: "let greeting = \"Hello\""),
                        errorText:
                            "String to replace not found in file. The file may have changed since it was read.")),
                .generic(
                    GenericChild(
                        id: genericId,
                        label: "Used Skill",
                        activeLabel: "Using Skill",
                        errorText: "Unknown skill: commit")),
            ])
        let block = Block(id: groupId, kind: .toolGroup(group))
        controller.apply(.append([block]))

        let mounted = MountedTranscript.mount(
            controller: controller, size: CGSize(width: 720, height: 900))
        defer { mounted.teardown() }

        // Expand the group and every child so the error cards lay out.
        // `toggleFold` no-ops before the table is bound, so this runs
        // post-mount.
        for id in [groupId, bashId, editId, genericId] {
            controller.coordinator.toggleFold(id: id)
        }
        mounted.drain(seconds: 0.3)

        let view = mounted.scroll
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            return XCTFail("bitmapImageRepForCachingDisplay returned nil")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)

        let url = ViewSnapshot.writePNG(image, name: "ToolGroupErrorCard")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "ToolGroupErrorCard.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 700)
    }
}
