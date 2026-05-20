import AppKit
import SwiftUI

/// Sandbox tab focused on the **scroll-time** cost of an expanded
/// `toolGroup` row whose single `fileEdit` child carries a many-screen
/// diff. The host transcript is otherwise routine (200 paragraph blocks
/// above the group, 80 below) so the viewport is always crossing a
/// mixture of small cells + the giant entry view as the user scrolls.
///
/// Reproduces the report "diff view scrolling drops frames even with no
/// running, no expand". Both fold flags are toggled on at mount time,
/// the tool group is `.completed` (so no shimmer animation contributes
/// to render cost), nothing streams.
///
/// The mount also flips `Transcript2PerfLog.enabled = true` for the
/// duration the view is alive. Hot paths in `BlockCellView` /
/// `ToolGroupEntryView` / `Transcript2Coordinator` emit info-level
/// entries under category `Transcript2Perf`; an external
/// `log stream --predicate '...'` (see `Transcript2PerfLog.swift`)
/// captures them while reproducing the jank.
struct TranscriptPerfDemoView: View {
    @State private var controller = Transcript2Controller()
    @State private var seeded = false

    var body: some View {
        NativeTranscript2View(controller: controller)
            .frame(minWidth: 320, minHeight: 240)
            .overlay(alignment: .bottom) { statusBar }
            .task {
                #if DEBUG
                Transcript2PerfLog.enabled = true
                #endif
                guard !seeded else { return }
                seeded = true
                let blocks = Self.makeBlocks()
                controller.setHistory(blocks)
                // Expand the group and the lone fileEdit child so the
                // giant diff body is the resting state — scrolling
                // exercises the over-screen entry view immediately
                // without a user click. Both ids must be addressed
                // separately because `toggleFold` operates one fold
                // surface at a time (group-level + child-level).
                controller.coordinator.toggleFold(id: Self.toolGroupBlockId)
                controller.coordinator.toggleFold(id: Self.fileEditChildId)
            }
            .onDisappear {
                #if DEBUG
                // Leave the flag clean for any non-demo tab the user
                // navigates to next; otherwise a real session's scroll
                // path would inherit the trace volume.
                Transcript2PerfLog.enabled = false
                #endif
            }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "speedometer").foregroundStyle(.secondary)
            Text(
                "\(controller.blockCount) blocks · diff = \(Self.diffLineCount) lines · trace ON (category Transcript2Perf)"
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(.bottom, 20)
    }
}

// MARK: - Content generation

extension TranscriptPerfDemoView {
    /// Stable ids so the `.task` block can address fold state without
    /// scanning `controller.blockIds` at runtime.
    fileprivate static let toolGroupBlockId = UUID()
    fileprivate static let fileEditChildId = UUID()

    /// Diff body line count target. Chosen large enough that even on a
    /// 5K display the entry view's frame.height blows past the IOSurface
    /// max-texture-size guess (≈16k px on Apple Silicon) at 1× backing
    /// scale, and trivially overflows at 2× Retina backing. ~700 lines
    /// × 16pt line-height ≈ 11200pt → 22400px at @2x.
    fileprivate static let diffLineCount = 700

    /// Number of paragraph blocks rendered above the giant tool group.
    fileprivate static let leadingParagraphCount = 200

    /// Number of paragraph blocks rendered below the tool group.
    fileprivate static let trailingParagraphCount = 80

    fileprivate static func makeBlocks() -> [Block] {
        var blocks: [Block] = []
        blocks.reserveCapacity(
            leadingParagraphCount + trailingParagraphCount + 4)

        blocks.append(
            Block(
                id: UUID(),
                kind: .heading(
                    level: 1,
                    inlines: [.text("Transcript Perf · Diff Scroll Stress")])))
        blocks.append(
            Block(
                id: UUID(),
                kind: .paragraph(
                    inlines: [
                        .text(
                            "Group + child are auto-expanded on mount. Scroll up "
                                + "and down across the diff card and watch the "
                                + "log stream under category Transcript2Perf — "
                                + "see Transcript2PerfLog.swift for the predicate.")
                    ])))

        for i in 0..<leadingParagraphCount {
            blocks.append(paragraph(index: i, prefix: "lead"))
        }

        blocks.append(makeToolGroupBlock())

        for i in 0..<trailingParagraphCount {
            blocks.append(paragraph(index: i, prefix: "tail"))
        }

        return blocks
    }

    /// One synthetic paragraph block. Deterministic — the wording
    /// rotates through a small pool keyed by `index` so the same demo
    /// session renders the same content on every relaunch, which
    /// keeps log-stream diffs across runs cleanly comparable.
    fileprivate static func paragraph(index i: Int, prefix: String) -> Block {
        let pool = [
            "Apple Silicon's unified memory architecture continues to set the bar "
                + "for laptop-class inference performance. The Pacific revision "
                + "extends LPDDR5X capacity to 192GB in a single SoC envelope and "
                + "introduces a dedicated tensor scheduler in the ANE complex.",
            "国内厂商在自研工具链上取得了关键性进展。某厂商透露其新一代 EDA 套件"
                + "已通过 7nm 节点的全流程验证,流片良率在最新一批晶圆上稳定在 78% 附近,"
                + "比上一代提升约 12 个百分点。",
            "Robotics researchers at three independent labs converged on a similar "
                + "policy-gradient recipe this week. Despite different reward "
                + "shaping, all three converged within 4M frames on the BipedalWalker "
                + "benchmark — a hint that the lower bound for this class of "
                + "task is approaching saturation.",
            "Quantum networking trials on the Boston metro fiber loop reached a "
                + "new milestone: 12 hours of continuous entanglement distribution "
                + "with a fidelity floor above 0.93 at every measurement window.",
        ]
        let body = pool[i % pool.count]
        return Block(
            id: UUID(),
            kind: .paragraph(
                inlines: [.text("[\(prefix)#\(i + 1)] \(body)")]))
    }

    fileprivate static func makeToolGroupBlock() -> Block {
        let (oldString, newString) = makeDiffStrings()
        let child = FileEditChild(
            id: fileEditChildId,
            label: "Edit Sources/Analyzer.swift",
            activeLabel: "Editing Sources/Analyzer.swift",
            filePath: "Sources/Analyzer.swift",
            diff: DiffBlock(
                filePath: "Sources/Analyzer.swift",
                oldString: oldString,
                newString: newString))
        return Block(
            id: toolGroupBlockId,
            kind: .toolGroup(
                ToolGroupBlock(
                    activeTitle: "Editing Sources/Analyzer.swift",
                    expandedActiveTitle: "Editing 1 file",
                    completedTitle: "Edited 1 file",
                    children: [.fileEdit(child)])))
    }

    /// Synthesize an old/new pair that produces ~`diffLineCount` body
    /// rows after diffing. Keeps a Swift-ish flavour so
    /// `LanguageDetection` resolves to `swift` and `highlight.js` emits
    /// keyword / string / number tokens on most lines, exercising the
    /// per-line token-array path in `DiffLayout` + the highlight
    /// storage's `lineMap` writeback.
    ///
    /// Strategy: build a long block of code-shaped lines, then in a
    /// scattered set of positions change one identifier so every fourth
    /// hunk produces add/del rows on top of the context background. The
    /// result is the kind of "log/stack-trace-density" diff a real
    /// large refactor produces.
    fileprivate static func makeDiffStrings() -> (String, String) {
        var oldLines: [String] = []
        var newLines: [String] = []
        oldLines.reserveCapacity(diffLineCount + 32)
        newLines.reserveCapacity(diffLineCount + 32)

        for i in 0..<diffLineCount {
            let base = codeLine(at: i, version: .old)
            oldLines.append(base)
            // ~25% of lines mutate. The remaining 75% stay context —
            // exercises gutter + line-number column paint width without
            // overwhelming the diff with add/del bands.
            if i % 4 == 0 {
                newLines.append(codeLine(at: i, version: .new))
            } else {
                newLines.append(base)
            }
        }
        // Append a small batch of pure-add lines at the end so the
        // green `+` column has glyphs to render in the lower band too.
        for i in 0..<32 {
            newLines.append(
                "    logger.debug(\"diagnostic event #\(i) emitted\")")
        }
        return (oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"))
    }

    private enum CodeVersion { case old, new }

    /// Generate one synthetic Swift-ish line at `index`. Cycles through
    /// a small set of statement shapes so per-line content varies
    /// (varying token counts, varying widths) — the diff body's worst
    /// case is uniform-width context lines that all hit the same wrap
    /// boundary; mixing shapes is closer to a real file.
    private static func codeLine(at index: Int, version: CodeVersion) -> String {
        let shapes: [(_ i: Int, _ ver: CodeVersion) -> String] = [
            { i, _ in "// MARK: - Section \(i / 8) · helper #\(i)" },
            { i, v in
                let name = v == .old ? "process" : "processV2"
                return
                    "    let \(name)Result_\(i) = try await runner.invoke(symbol: \"sym_\(i)\")"
            },
            { i, v in
                let lvl = v == .old ? ".info" : ".debug"
                return
                    "    logger.log(level: \(lvl), \"frame[\(i)] latency=\\(latency)ms\")"
            },
            { i, _ in
                "    guard let payload = decoder.decode(Payload.self, from: data\(i)) else { continue }"
            },
            { i, v in
                let suffix = v == .old ? "" : " // tuned 2026-05"
                return
                    "    metrics[\"sample.\(i % 31)\"] = Double(\(i * 7) % 1000) / 1000.0\(suffix)"
            },
            { i, _ in
                "        case .case_\(i)(let v): aggregate += Int64(v.magnitude) &* 0x\(String(i % 0xFFFF, radix: 16))"
            },
            { i, _ in
                "    // accumulator pulled across line \(i) — see Analyzer.md#section-\(i / 12)"
            },
            { i, _ in
                "    let url\(i) = URL(string: \"https://example.com/api/v3/items/\\(itemId_\(i))/diagnostics\")"
            },
        ]
        return shapes[index % shapes.count](index, version)
    }
}

#Preview {
    TranscriptPerfDemoView()
        .frame(width: 900, height: 720)
        .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
