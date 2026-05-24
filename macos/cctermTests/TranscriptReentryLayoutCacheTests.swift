import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Asserts the "single source-phase tick = single width per id"
/// property against the canonical `TranscriptScrollViewFactory` attach
/// sequence (bare NSView container — no production VC, no demo VC).
/// Sibling tests in `TranscriptHostReentryLayoutCacheTests` drive the
/// production `ChatSessionViewController` and the AppKit demo VCs
/// through the same property; the three together guard both the
/// factory itself AND every caller's adherence to the documented
/// attach order.
///
/// Not a snapshot — text-only `(writes, widths, stages)` attachment —
/// so the file no longer carries the `Snapshot` suffix and runs on the
/// default CI suite as a merge gate.
@MainActor
final class TranscriptReentryLayoutCacheTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let blockCount = 60
    private static let windowSize = CGSize(width: 720, height: 800)

    private func makeBlocks() -> [Block] {
        (0..<Self.blockCount).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "line \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }

    private struct Write {
        let id: UUID
        let width: CGFloat
        let stage: String
    }

    func testReentryDoesNotRelayoutSameBlockAtMultipleWidthsInOneTick() throws {
        let controller = Transcript2Controller()
        controller.setHistory(makeBlocks())
        XCTAssertEqual(controller.blockIds.count, Self.blockCount)
        let coordinator = controller.coordinator

        var writes: [Write] = []
        // `currentStage` names the step CURRENTLY executing — set before
        // each call so a write fired during that call is attributed
        // correctly.
        var currentStage = "factory.make"
        coordinator.onLayoutCacheWriteForDebug = { id, width in
            writes.append(Write(id: id, width: width, stage: currentStage))
        }
        defer { coordinator.onLayoutCacheWriteForDebug = nil }

        let scroll = TranscriptScrollViewFactory.make(controller: controller)

        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: Self.windowSize),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        currentStage = "addSubview"
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        currentStage = "layoutSubtreeIfNeeded"
        container.layoutSubtreeIfNeeded()

        currentStage = "bindData"
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)

        currentStage = "scrollToTail"
        controller.scrollToTail()

        let oneTickWrites = writes

        defer {
            window.contentView = nil
            window.close()
        }

        let widthsPerId = Dictionary(grouping: oneTickWrites, by: \.id)
            .mapValues { Set($0.map(\.width)) }
        let offenders = widthsPerId.filter { $0.value.count > 1 }

        let totalWrites = oneTickWrites.count
        let uniqueIds = widthsPerId.count
        let distinctWidths = Set(oneTickWrites.map(\.width)).sorted()
        let writesPerStage = Dictionary(
            grouping: oneTickWrites, by: \.stage
        ).mapValues(\.count).sorted { $0.key < $1.key }
        let widthsPerStage = Dictionary(
            grouping: oneTickWrites, by: \.stage
        ).mapValues { Set($0.map(\.width)).sorted() }.sorted { $0.key < $1.key }

        var report = """
            reentry layoutCache write trace — one source-phase tick
            ────────────────────────────────────────────────────────────
            total writes        = \(totalWrites)
            unique block ids    = \(uniqueIds)  (fixture has \(Self.blockCount))
            distinct widths     = \(distinctWidths)
            writes per stage    = \(writesPerStage.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            widths per stage    = \(widthsPerStage.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
            """

        if !offenders.isEmpty {
            // First-seen-wins; can't use Dictionary(uniqueKeysWithValues:) —
            // when offenders exist, the same id appears multiple times and
            // that initializer traps on duplicates.
            var firstIndexById: [UUID: Int] = [:]
            for (i, w) in oneTickWrites.enumerated() where firstIndexById[w.id] == nil {
                firstIndexById[w.id] = i
            }
            let lines =
                offenders
                .sorted { (firstIndexById[$0.key] ?? .max) < (firstIndexById[$1.key] ?? .max) }
                .prefix(10)
                .map { id, widths in
                    let sorted = widths.sorted()
                    return "  \(id.uuidString.prefix(8))… widths=\(sorted)"
                }
            report += "\n\nOFFENDERS (\(offenders.count) ids, first 10):\n"
            report += lines.joined(separator: "\n")
        }

        let attachment = XCTAttachment(string: report)
        attachment.name = "reentry-cache-writes"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(
            offenders.isEmpty,
            "Re-entry typeset \(offenders.count) block(s) at multiple widths "
                + "inside one source phase. distinctWidths=\(distinctWidths).")
    }
}
