import AppKit
import SwiftUI

/// Sandbox tab for exercising `NativeTranscript2` with realistic content.
///
/// Holds a deliberately mixed feed (English + Chinese tech-news prose, several
/// images) so the renderer is hit with multi-script line-breaking,
/// vertically-tall paragraphs, and aspect-fit images at the same time. A
/// floating control panel at the bottom lets you grow / shrink the block
/// list to verify diff animations and resize behavior under load.
struct TranscriptDemoView: View {
    @State private var controller: Transcript2Controller
    /// Monotonic counter for extra-pool cycling. Decoupled from
    /// `blockCount` so deletions don't reset the cycle (which would
    /// otherwise pin every appended block to `extraPool[0]` once the live
    /// count dropped below `initialBlocks.count`).
    @State private var extraAddCount: Int = 0
    /// Current status of the running-demo tool group. Driven by the
    /// "Toggle Status" control-bar button so a click flips the group
    /// header title between the progressive form (`activeTitle`) and
    /// the past-tense form (`completedTitle`). The transition runs
    /// through `Transcript2Coordinator.setStatus`, which now queues a
    /// `CATransition.fade` on the host cell layer — that's the change
    /// this button is here to demonstrate.
    @State private var runningGroupStatus: ToolStatus = .running

    /// Default initializer for production callers (sidebar selection).
    /// Tests can pass a pre-seeded controller via `init(controller:)`
    /// to bypass the `.task`-driven seed path — AppKit's appearance
    /// signals are unreliable for offscreen hosted-test windows, so
    /// state-injection is the supported test seam. The `.task` body
    /// below is idempotent on `blockCount == 0`, so a pre-loaded
    /// controller simply skips it.
    @MainActor
    init(controller: Transcript2Controller? = nil) {
        _controller = State(initialValue: controller ?? Transcript2Controller())
    }

    var body: some View {
        NativeTranscript2View(controller: controller)
            .frame(minWidth: 320, minHeight: 240)
            .overlay(alignment: .bottom) { controlPanel }
            .task {
                // Idempotent: only seed once. Survives Preview re-renders
                // that would otherwise re-fire a side-effecting `@State`
                // default closure.
                if controller.blockCount == 0 {
                    controller.setHistory(Self.initialBlocks)
                    // Mark the third toolGroup live. Status flows through
                    // the dedicated `setToolStatus` channel so the rows
                    // already in the table refresh granularly — no
                    // Block.Kind replacement, no highlight invalidation.
                    // Mixed per-child statuses prove sibling rendering
                    // stays independent: only the bash row picks up the
                    // running palette + progressive label.
                    controller.setToolStatus(
                        id: Self.runningGroupBlockId, status: .running)
                    controller.setToolStatus(
                        id: Self.runningReadChildId, status: .completed)
                    controller.setToolStatus(
                        id: Self.runningGrepChildId, status: .completed)
                    controller.setToolStatus(
                        id: Self.runningBashChildId, status: .running)
                }
            }
    }

    private var controlPanel: some View {
        HStack(spacing: 10) {
            Button {
                let next = Self.extraBlock(at: extraAddCount)
                controller.apply(.insert(after: controller.blockIds.last, [next]))
                extraAddCount += 1
            } label: {
                Label("Add Message", systemImage: "plus.circle.fill")
            }
            Button {
                if controller.blockCount > 1,
                    let lastId = controller.blockIds.last
                {
                    controller.apply(.remove(ids: [lastId]))
                }
            } label: {
                Label("Remove Message", systemImage: "minus.circle.fill")
            }
            .disabled(controller.blockCount <= 1)

            Divider().frame(height: 16)

            // Flips the running-demo tool group between `.running`
            // and `.completed`, which swaps the group header's title
            // (`activeTitle` ↔ `completedTitle`) and recolours the
            // bash child. Both writes route through `setToolStatus`,
            // which now queues a `CATransition.fade` on the host
            // cell — the visible change should crossfade, not pop.
            Button {
                let next: ToolStatus =
                    (runningGroupStatus == .running) ? .completed : .running
                runningGroupStatus = next
                controller.setToolStatus(
                    id: Self.runningGroupBlockId, status: next)
                controller.setToolStatus(
                    id: Self.runningBashChildId, status: next)
            } label: {
                Label(
                    runningGroupStatus == .running
                        ? "Mark Completed" : "Mark Running",
                    systemImage: "wand.and.stars")
            }

            Divider().frame(height: 16)

            Text("\(controller.blockCount)")
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

// MARK: - Demo content

extension TranscriptDemoView {
    /// Built once at first access. Stable `Block.id`s + stable `NSImage`
    /// instances so the diff sees no churn across re-renders. Exposed
    /// at module-internal scope so unit tests can pre-seed a
    /// `Transcript2Controller` with the same payload the `.task`-
    /// driven path would have installed.
    static let initialBlocks: [Block] = makeInitialBlocks()

    /// Hardcoded extra entries appended by the "Add Message" button. Cycled
    /// through by `currentCount` so each click visibly adds something new.
    fileprivate static let extraPool: [Block.Kind] = [
        .paragraph(
            inlines: plain(
                "Update — A late-breaking note from one of the framework "
                    + "maintainers suggests the Pacific instruction extensions ship "
                    + "with two undocumented opcodes used internally for scheduling. "
                    + "Apple has not commented on whether these will be exposed to "
                    + "third-party developers."
            )),
        .heading(level: 2, inlines: plain("更新 · 后续动态")),
        .paragraph(
            inlines: plain(
                "据多家媒体跟进报道,前述监管新规将在公开征求意见 30 天后正式生效。"
                    + "目前已有 7 家企业提交了书面反馈,主要集中在过渡期长度和数据保存格式两个方面。"
                    + "监管部门表示会在听证会后整理意见并公布最终版本。"
            )),
        .paragraph(
            inlines: plain(
                "Side note — Several open-source projects have begun publishing "
                    + "matrix-multiplication kernels tuned for the new memory "
                    + "subsystem. Early benchmarks show 1.4x–1.7x improvements on "
                    + "INT8 GEMM workloads compared with hand-tuned NEON intrinsics, "
                    + "though the gap narrows considerably at larger problem sizes "
                    + "where memory-bandwidth ceiling dominates."
            )),
    ]

    fileprivate static func extraBlock(at addIndex: Int) -> Block {
        let kind = extraPool[addIndex % extraPool.count]
        return Block(id: UUID(), kind: kind)
    }

    fileprivate static func makeInitialBlocks() -> [Block] {
        let icons = DemoIcons()
        return userBubbleShowcase() + markdownShowcase() + [
            heading("Tech News — April 2026"),
            para(
                "Apple unveiled the next generation of its M-series silicon at a "
                    + "low-key briefing on Monday, drawing immediate comparisons "
                    + "with the data-center accelerators dominating the AI inference "
                    + "market. The new chip, internally codenamed Pacific, sits "
                    + "between the M5 Max and the long-rumored M5 Ultra and is the "
                    + "first Apple Silicon design to ship with on-die 3D-stacked "
                    + "memory. Engineering sources familiar with the project say "
                    + "the architecture is optimized for sustained throughput on "
                    + "transformer workloads, with a unified compiler stack that "
                    + "bridges the existing Metal Performance Shaders and Core ML "
                    + "graph runtimes."
            ),
            para(
                "Reaction across the developer community has been mixed. While "
                    + "the raw memory bandwidth figures — reportedly approaching "
                    + "1.2 TB/s aggregate — outperform last year's Hopper revision "
                    + "in narrow benchmarks, the lack of CUDA compatibility "
                    + "continues to frustrate teams that have built their tooling "
                    + "around Nvidia's stack. A handful of frameworks, notably MLX "
                    + "and Burn, have already shipped beta builds targeting the "
                    + "Pacific instruction extensions, but mainstream PyTorch users "
                    + "will likely wait several quarters before seeing comparable "
                    + "support."
            ),
            image(icons.cpu),

            heading("Quantum networking turns a corner"),
            para(
                "A team of researchers at the Delft University of Technology "
                    + "published results this week claiming the first error-"
                    + "corrected entanglement swap across a 60-kilometer fiber-"
                    + "optic span. The experiment uses a chain of three diamond-"
                    + "defect quantum memories, each stabilized by a low-"
                    + "temperature cryostat, and it's the longest such "
                    + "demonstration to operate continuously for more than 24 "
                    + "hours without manual recalibration. The paper, currently "
                    + "undergoing peer review, suggests that the hardware floor "
                    + "for usable metropolitan quantum networks may be lower than "
                    + "previously assumed."
            ),
            para(
                "Industry analysts are cautious. Quantum networking remains "
                    + "constrained by the unforgiving physics of single-photon "
                    + "transmission, and the energy budget per successful "
                    + "entanglement event is still measured in millijoules, not "
                    + "nanojoules. Even so, the combination of falling cryostat "
                    + "costs and improving photonic-integrated-circuit yields is "
                    + "starting to make commercial deployment plausible — at "
                    + "least for the niche of trusted-node-free key distribution, "
                    + "where the value proposition is genuinely unmatched by "
                    + "classical cryptography."
            ),
            image(icons.network),

            heading("Robotaxis hit a regulatory wall"),
            para(
                "California's Department of Motor Vehicles indefinitely "
                    + "suspended the city-wide deployment permits of two robotaxi "
                    + "operators after a string of high-profile incidents in San "
                    + "Francisco. The order applies to fleets operating without a "
                    + "human safety driver and follows a formal complaint from "
                    + "the city attorney that detailed nineteen instances of "
                    + "vehicles obstructing emergency response over a four-month "
                    + "window. Both operators have indicated they will request an "
                    + "administrative hearing, but in the meantime their "
                    + "commercial services are limited to driver-supervised "
                    + "operations only."
            ),
            para(
                "The episode underscores the widening gap between technical "
                    + "capability and operational maturity. The vehicles "
                    + "themselves perform well on freeway segments and during "
                    + "off-peak hours, but their ability to negotiate the dense, "
                    + "unpredictable interactions of downtown traffic — double-"
                    + "parked delivery vans, jaywalking pedestrians, fire trucks "
                    + "running lights — remains a frequent failure mode. Solving "
                    + "this last 5% of cases is widely believed to require either "
                    + "a substantial change in vehicle behavior policies or, more "
                    + "controversially, dedicated infrastructure that pedestrians "
                    + "and human drivers are expected to respect."
            ),

            heading("国产芯片新进展"),
            para(
                "国内某头部芯片厂商在本周举办的设计自动化大会上披露了其下一代 7nm 工艺平台的关键参数。"
                    + "该平台基于自主可控的 EDA 工具链,已经完成了第一轮风险流片,"
                    + "初步测试结果显示在等效晶体管密度上达到了海外同代工艺的 92% 水平,"
                    + "但在最高频率下的功耗略高约 18%。"
                    + "该厂商表示,下一代工艺将在 18 个月内进入量产阶段,"
                    + "并将重点服务于通用计算和数据中心市场。"
            ),
            para(
                "业内观察人士对这一进展看法不一。一方面,"
                    + "能在国产 EDA 工具链上完整跑通 7nm 设计流程,本身就是一项里程碑式的工程成就。"
                    + "另一方面,工艺成熟度、良率爬坡所需要的时间,"
                    + "以及围绕该工艺的 IP 生态建设,仍然是制约商业化进程的关键变量。"
                    + "多家分析机构在最新报告中指出,未来三年内,"
                    + "国产先进工艺主要会服务于政企市场和特定行业客户,"
                    + "而要进入消费电子级竞争还需要更长的时间窗口。"
            ),
            image(icons.globe),

            heading("AI 模型新动向"),
            para(
                "国内一家大模型创业公司本周开源了其旗舰模型的轻量化版本,"
                    + "参数量约为 170 亿,专门针对中文长上下文优化。"
                    + "模型采用了类似 Mamba 状态空间架构的混合设计,"
                    + "在 1 百万 token 长度的检索测试中显示出与 Transformer 基线相近的精度,"
                    + "但在解码端的内存占用大幅下降。开源协议为 Apache 2.0,允许商业使用,"
                    + "社区在不到 24 小时内便完成了对主流推理框架的适配。"
            ),
            para(
                "与此同时,海外大型实验室也在加紧推出新版本。"
                    + "某北美公司在月底前发布了其多模态旗舰,"
                    + "将视觉、音频和文本统一在单一 token 流中训练,"
                    + "端到端延迟比上一代降低了约 40%。"
                    + "开发者社区对其原生工具调用能力评价较高,"
                    + "但也对模型训练数据来源的不透明性保持关注。"
            ),

            heading("Apple Vision Pro 2"),
            para(
                "Apple's second-generation mixed-reality headset, formally "
                    + "announced at WWDC 2026, shifts the device's positioning "
                    + "away from spatial-computing-as-platform and toward "
                    + "dedicated entertainment and productivity scenarios. The "
                    + "new model is roughly 18% lighter, drops one of the "
                    + "external cameras, and replaces the original M2 system-on-"
                    + "chip with a custom variant of the Pacific architecture "
                    + "mentioned above. Pricing has been brought down to $2,499 "
                    + "in the United States, a reduction the company attributes "
                    + "to better display yields and a simplified optical "
                    + "assembly."
            ),
            para(
                "Critically, the second-generation device retains full "
                    + "backward compatibility with the visionOS 1.x application "
                    + "library, which now numbers in the tens of thousands of "
                    + "titles. Developer reaction at the post-keynote sessions "
                    + "emphasized improvements in inside-out tracking, "
                    + "particularly during fast head motion and in low-light "
                    + "environments. The persistent skepticism around enterprise "
                    + "adoption — driven mostly by IT departments uneasy with "
                    + "managing a head-worn computing surface — has not been "
                    + "meaningfully addressed in the launch material."
            ),
            image(icons.headset),

            heading("自动驾驶法规更新"),
            para(
                "国内交通运输部近期发布的新版自动驾驶测试管理办法,"
                    + "对完全无人驾驶车辆在城市道路上的测试条件做出了更为严格的规定。"
                    + "新规将测试区域分为三个等级,要求企业在进入最高等级"
                    + "(即不限定道路类型的城市级测试) 之前,"
                    + "必须完成至少 50 万公里的封闭场地测试和 200 万公里的限定区域路测。"
                    + "此外,新规首次明确要求测试车辆必须配备符合国家标准的事件数据记录器,"
                    + "且数据保存期限不得少于 36 个月。"
            ),
            para(
                "多家从事 L4 级自动驾驶研发的企业表示,"
                    + "新规在规范性和安全性上有显著提升,"
                    + "但也增加了进入测试阶段的资金和时间门槛。"
                    + "一些初创公司担心,长期门槛会让市场进一步向已有规模的玩家集中,"
                    + "不利于技术多样性。监管部门则回应称,"
                    + "自动驾驶安全直接关系到公众生命财产,"
                    + "门槛的提高是必要的代价,监管思路会在执行过程中持续优化。"
            ),

            heading("Closing notes"),
            para(
                "The week's most underreported story may have been a quiet "
                    + "revision to the IEEE 754 floating-point standard, opening "
                    + "the door to lower-precision tensor formats becoming "
                    + "first-class citizens in numerical libraries. While the "
                    + "change is technical, its downstream consequences for both "
                    + "hardware design and machine-learning compiler stacks could "
                    + "be substantial over the next five years. We expect to "
                    + "revisit this in a longer feature next month."
            ),
        ]
    }

    fileprivate static func heading(_ text: String, level: Int = 1) -> Block {
        Block(id: UUID(), kind: .heading(level: level, inlines: plain(text)))
    }

    fileprivate static func para(_ text: String) -> Block {
        Block(id: UUID(), kind: .paragraph(inlines: plain(text)))
    }

    fileprivate static func headingIR(level: Int, _ inlines: [InlineNode]) -> Block {
        Block(id: UUID(), kind: .heading(level: level, inlines: inlines))
    }

    fileprivate static func paraIR(_ inlines: [InlineNode]) -> Block {
        Block(id: UUID(), kind: .paragraph(inlines: inlines))
    }

    fileprivate static func image(_ image: NSImage) -> Block {
        Block(id: UUID(), kind: .image(image))
    }

    /// Trivial wrapper used wherever a String literal is the entire content —
    /// keeps construction sites readable while every value site still goes
    /// through `[InlineNode]`. Lifted to file scope (vs. inline `[.text(s)]`)
    /// so updating the demo to richer IR is a one-line edit per call site.
    fileprivate static func plain(_ text: String) -> [InlineNode] { [.text(text)] }

    /// Three user bubbles at the top of the demo so the chevron + collapse
    /// + selection paths are visible immediately on open:
    /// - one short bubble (no chevron — under threshold)
    /// - one bubble exactly at the threshold + min-hidden boundary
    /// - one long bubble that folds by default
    fileprivate static func userBubbleShowcase() -> [Block] {
        let shortMessage =
            "Quick check — can you take a look at the latest M-series briefing "
            + "and pull out the headline numbers?"

        let longMessage = (0..<22).map { i in
            "Line \(i + 1): "
                + "Could you summarize the architectural changes between the "
                + "previous generation and this one, with attention to memory "
                + "subsystem changes and any compiler-stack updates that "
                + "developers should be aware of? Cite sources when possible."
        }.joined(separator: "\n")

        let cjkMessage = (0..<14).map { i in
            "第 \(i + 1) 行:"
                + "请帮我对比一下国产 7nm 工艺和海外同代工艺的关键差异,"
                + "包括晶体管密度、最高频率、功耗以及 EDA 工具链的成熟度,"
                + "并给出未来 18 个月的量产可能性评估。"
        }.joined(separator: "\n")

        return [
            Block(id: UUID(), kind: .userBubble(text: shortMessage)),
            Block(
                id: UUID(),
                kind: .userAttachments(images: sampleAttachmentImages(count: 3))),
            Block(id: UUID(), kind: .userBubble(text: "screenshots from the new build")),
            Block(
                id: UUID(),
                kind: .userAttachments(images: sampleAttachmentImages(count: 1))),
            Block(id: UUID(), kind: .userBubble(text: longMessage)),
            Block(id: UUID(), kind: .userBubble(text: cjkMessage)),
        ]
    }

    /// Synthesize `count` SF-Symbol-backed `NSImage`s for the user
    /// attachments strip — uses a rotating palette so each chip is
    /// visually distinct in the snapshot.
    fileprivate static func sampleAttachmentImages(count: Int) -> [NSImage] {
        let palette: [NSColor] = [
            .systemBlue, .systemPink, .systemOrange, .systemTeal, .systemPurple,
        ]
        let symbols = ["photo", "doc.richtext", "camera.macro", "paintpalette", "scribble"]
        return (0..<count).map { i in
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
                .applying(.init(paletteColors: [palette[i % palette.count]]))
            let image =
                NSImage(systemSymbolName: symbols[i % symbols.count], accessibilityDescription: nil)
                ?? NSImage()
            return image.withSymbolConfiguration(cfg) ?? image
        }
    }

    /// Curated showcase of inline IR + heading levels. Sits at the top of
    /// `initialBlocks` so opening the demo immediately exercises the new
    /// markdown rendering path.
    fileprivate static func markdownShowcase() -> [Block] {
        let docsURL = URL(string: "https://example.com/docs")!
        let issueURL = URL(string: "https://example.com/issues/42")!
        return [
            headingIR(level: 1, [.text("Markdown showcase")]),

            paraIR([
                .text("This first section exercises every "),
                .strong([.text("inline node kind")]),
                .text(" the renderer supports. Below are headings "),
                .code("h1"),
                .text(" through "),
                .code("h6"),
                .text(", followed by a paragraph that mixes "),
                .strong([.text("bold")]),
                .text(", "),
                .emphasis([.text("italic")]),
                .text(", "),
                .strong([.emphasis([.text("bold-italic")])]),
                .text(", "),
                .strikethrough([.text("strikethrough")]),
                .text(", "),
                .code("inline code"),
                .text(", and a "),
                .link(children: [.text("hyperlink")], url: docsURL),
                .text("."),
            ]),

            paraIR([
                .text("Hard line breaks split a paragraph without ending the block."),
                .lineBreak,
                .text("This second sentence sits on its own visual line but "),
                .text("shares the paragraph's typographic state."),
                .lineBreak,
                .text("A third line, again broken with "),
                .code("\\n"),
                .text("-equivalent."),
            ]),

            headingIR(level: 1, [.text("Heading level 1")]),
            headingIR(level: 2, [.text("Heading level 2")]),
            headingIR(level: 3, [.text("Heading level 3")]),
            headingIR(level: 4, [.text("Heading level 4")]),
            headingIR(level: 5, [.text("Heading level 5")]),
            headingIR(level: 6, [.text("Heading level 6")]),

            paraIR([
                .text("Nested emphasis: "),
                .strong([
                    .text("bold with an "),
                    .emphasis([.text("italic phrase")]),
                    .text(" inside"),
                ]),
                .text(", and a "),
                .link(
                    children: [
                        .strong([.text("bold")]),
                        .text(" "),
                        .code("link"),
                    ], url: issueURL),
                .text(" carrying mixed children."),
            ]),

            paraIR([
                .text("CJK + emphasis 混排:这里出现一段"),
                .strong([.text("加粗的中文短语")]),
                .text(",紧接一个 "),
                .code("monospaced"),
                .text(" 内联代码,然后是 "),
                .emphasis([.text("italic")]),
                .text(" 收尾。换行符也能正确穿插。"),
                .lineBreak,
                .text("第二行用 "),
                .link(children: [.text("链接锚点")], url: docsURL),
                .text(" 收尾。"),
            ]),

            headingIR(level: 2, [.text("Lists")]),

            Block(
                id: UUID(),
                kind: .list(
                    ListBlock(
                        ordered: false,
                        items: [
                            ListBlock.Item(content: [
                                .paragraph([
                                    .text("Bullet item with mixed inlines: "),
                                    .strong([.text("bold")]),
                                    .text(", "),
                                    .emphasis([.text("italic")]),
                                    .text(", "),
                                    .code("monospaced"),
                                    .text(", and a "),
                                    .link(children: [.text("link")], url: docsURL),
                                    .text("."),
                                ])
                            ]),
                            ListBlock.Item(content: [
                                .paragraph([.text("Nested ordered list:")]),
                                .list(
                                    ListBlock(
                                        ordered: true,
                                        items: [
                                            ListBlock.Item(content: [.paragraph([.text("First child")])]),
                                            ListBlock.Item(content: [
                                                .paragraph([.text("Second child with "), .code("inline code")])
                                            ]),
                                            ListBlock.Item(content: [
                                                .paragraph([.text("Third child has a deeper nest:")]),
                                                .list(
                                                    ListBlock(
                                                        ordered: false,
                                                        items: [
                                                            ListBlock.Item(content: [
                                                                .paragraph([
                                                                    .text("Bullet inside ordered inside bullet")
                                                                ])
                                                            ]),
                                                            ListBlock.Item(content: [
                                                                .paragraph([
                                                                    .text("Markers right-align in their own column")
                                                                ])
                                                            ]),
                                                        ])),
                                            ]),
                                        ])),
                            ]),
                            ListBlock.Item(content: [
                                .paragraph([
                                    .text("中文长列表项也能正常折行,marker 列宽度按本层最宽 marker 计算,"),
                                    .text("不会被嵌套子列表的 marker 影响。"),
                                ])
                            ]),
                        ]))),

            // Non-1 start exercises monospaced right-alignment when marker
            // widths differ ("9." vs. "10." vs. "11.").
            Block(
                id: UUID(),
                kind: .list(
                    ListBlock(
                        ordered: true, startIndex: 9,
                        items: [
                            ListBlock.Item(content: [.paragraph([.text("Continues from a previous block at index 9.")])]
                            ),
                            ListBlock.Item(content: [
                                .paragraph([
                                    .text(
                                        "The dot at the end of the marker stays vertically aligned with the next item's dot."
                                    )
                                ])
                            ]),
                            ListBlock.Item(content: [
                                .paragraph([
                                    .text("That's the "), .strong([.text("right-alignment in a fixed-width column")]),
                                    .text(" trick."),
                                ])
                            ]),
                        ]))),

            // Task list — checkboxes are self-drawn so SF Pro's ☑/☐
            // asymmetry is bypassed.
            Block(
                id: UUID(),
                kind: .list(
                    ListBlock(
                        ordered: false,
                        items: [
                            ListBlock.Item(
                                checkbox: true,
                                content: [.paragraph([.text("Implement Block.Kind.list and ListLayout")])]),
                            ListBlock.Item(
                                checkbox: true,
                                content: [.paragraph([.text("Implement Block.Kind.table and TableLayout")])]),
                            ListBlock.Item(
                                checkbox: false, content: [.paragraph([.text("Wire selection across list items")])]),
                            ListBlock.Item(
                                checkbox: false, content: [.paragraph([.text("Add per-row collapsing for long lists")])]
                            ),
                        ]))),

            headingIR(level: 2, [.text("Tables")]),

            // Last column wraps so the per-cell TextLayout's CT line-break
            // path gets exercised.
            Block(
                id: UUID(),
                kind: .table(
                    TableBlock(
                        header: [
                            [.text("Block")],
                            [.text("Layout")],
                            [.text("Notes")],
                        ],
                        rows: [
                            [
                                [.text("paragraph")],
                                [.text("TextLayout")],
                                [
                                    .text("inline IR with "), .strong([.text("bold")]), .text(", "),
                                    .emphasis([.text("italic")]), .text(", "), .code("code"), .text(", "),
                                    .link(children: [.text("link")], url: docsURL), .text("."),
                                ],
                            ],
                            [
                                [.text("heading")],
                                [.text("TextLayout")],
                                [.text("Levels 1–6 collapse onto three visual tiers (26 / 22 / 18pt).")],
                            ],
                            [
                                [.text("image")],
                                [.text("ImageLayout")],
                                [
                                    .text("Aspect-fit; "), .code("maxHeight = 360pt"),
                                    .text("; CGImage extracted once at make-time."),
                                ],
                            ],
                            [
                                [.text("list")],
                                [.text("ListLayout")],
                                [
                                    .text(
                                        "Recursive items, marker midY-aligned to the first content line, checkbox self-drawn so checked / unchecked stay symmetric."
                                    )
                                ],
                            ],
                            [
                                [.text("table")],
                                [.text("TableLayout")],
                                [
                                    .text(
                                        "CSS-like min/max column allocation, bold header band, zebra-striped body, rounded outer border."
                                    )
                                ],
                            ],
                        ],
                        alignments: [.left, .left, .left]))),

            Block(
                id: UUID(),
                kind: .table(
                    TableBlock(
                        header: [
                            [.text("Metric")],
                            [.text("Value")],
                            [.text("Trend")],
                        ],
                        rows: [
                            [[.text("Latency p99")], [.text("12.4 ms")], [.text("↘ improving")]],
                            [[.text("Throughput")], [.text("840K req/s")], [.text("→ steady")]],
                            [[.text("Error rate")], [.text("0.012%")], [.text("↗ regressing")]],
                            [[.text("Cache hit")], [.text("97.8%")], [.text("→ steady")]],
                        ],
                        alignments: [.left, .right, .center]))),

            // CJK table exercises min-width clamp + long-cell wrap with
            // non-Latin scripts.
            Block(
                id: UUID(),
                kind: .table(
                    TableBlock(
                        header: [
                            [.text("阶段")],
                            [.text("耗时")],
                            [.text("说明")],
                        ],
                        rows: [
                            [[.text("解析")], [.text("0.4ms")], [.text("把消息流解析成 Block 数组,纯函数,off-main 安全")]],
                            [[.text("排版")], [.text("12ms")], [.text("Core Text 跑一遍 typesetter,行高、行距、首行缩进全部就位")]],
                            [
                                [.text("绘制")], [.text("3.1ms")],
                                [.text("CGContext 一次性绘制,选中底色 → inline code chip → glyph 三趟")],
                            ],
                        ],
                        alignments: [.left, .right, .left]))),

            headingIR(level: 2, [.text("Code blocks")]),

            paraIR([
                .text(
                    "Multi-line monospaced source with a corner copy button. "
                        + "Hover the top-right corner — the cursor flips to a pointer; "
                        + "click to copy the verbatim source.")
            ]),

            Block(
                id: UUID(),
                kind: .codeBlock(
                    language: "swift",
                    code: """
                        struct CodeBlockLayout: Sendable {
                            let text: TextLayout
                            let code: String
                            let containerRect: CGRect
                            let copy: CopyChrome?

                            static func make(code: String, maxWidth: CGFloat) -> CodeBlockLayout {
                                let attr = BlockStyle.codeBlockAttributed(code: code)
                                let text = TextLayout.make(attributed: attr, maxWidth: maxWidth)
                                // ...
                            }
                        }
                        """)),

            Block(
                id: UUID(),
                kind: .codeBlock(
                    language: "shell",
                    code: """
                        $ make build
                        $ make test TEST=cctermTests/NativeTranscript2
                        $ open ./build/Debug/ccterm.app
                        """)),

            headingIR(level: 2, [.text("Long-line wrap")]),

            paraIR([
                .text(
                    "Code-related blocks all soft-wrap inside their card. "
                        + "Long source lines break at character boundaries when "
                        + "no whitespace fits; diff continuation lines indent to "
                        + "the content column so the gutter and sign stay aligned "
                        + "with the first visual line.")
            ]),

            Block(
                id: UUID(),
                kind: .codeBlock(
                    language: "swift",
                    code: """
                        // A single very long source line with mixed whitespace — wraps at word boundaries first.
                        let longSentence = "This is a deliberately long string that should wrap softly across multiple visual lines inside the code block container."
                        // Unbreakable token — wraps mid-word at the character boundary.
                        let longIdentifier = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz"
                        """)),

            Block(
                id: UUID(),
                kind: .toolGroup(
                    ToolGroupBlock(
                        activeTitle: String(localized: "Editing \("Sources/Wrap.swift")"),
                        expandedActiveTitle: String(localized: "Editing \(1) file"),
                        completedTitle: String(localized: "Edited \(1) file"),
                        children: [
                            .fileEdit(
                                FileEditChild(
                                    id: UUID(),
                                    label: String(localized: "Edit \("Sources/Wrap.swift")"),
                                    activeLabel: String(localized: "Editing \("Sources/Wrap.swift")"),
                                    filePath: "Sources/Wrap.swift",
                                    diff: DiffBlock(
                                        filePath: "Sources/Wrap.swift",
                                        oldString: """
                                            let message = "short prefix"
                                            print(message)
                                            """,
                                        newString: """
                                            let message = "This is a deliberately long string that should wrap inside the diff card with continuation lines indented to the content column so the gutter and sign stay readable."
                                            let unbreakable = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz"
                                            print(message)
                                            print(unbreakable)
                                            """)))
                        ]))),

            Block(
                id: UUID(),
                kind: .toolGroup(
                    ToolGroupBlock(
                        activeTitle: String(localized: "Running \("echo …")"),
                        expandedActiveTitle: String(localized: "Running \(1) tool"),
                        completedTitle: String(localized: "Ran \(1) tool"),
                        children: [
                            .bash(
                                BashChild(
                                    id: UUID(),
                                    label: String(localized: "Ran \("echo …")"),
                                    activeLabel: String(localized: "Running \("echo …")"),
                                    command:
                                        "echo 'This is a deliberately long single-line command intended to overflow the card width so it has to soft-wrap inside the command sub-card just like stdout does.'",
                                    stdout: """
                                        This is a long stdout line that should wrap inside the stdout sub-card without any horizontal scrolling — words break at the nearest whitespace, and unbreakable tokens fall back to character boundaries.
                                        abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz
                                        """,
                                    stderr: nil))
                        ]))),

            headingIR(level: 2, [.text("Blockquotes")]),

            Block(
                id: UUID(),
                kind: .blockquote(inlines: [
                    .text("Quotes use the shared container chrome — same "),
                    .code("cornerRadius"),
                    .text(" and "),
                    .code("padding"),
                    .text(" as the user bubble and code blocks. The left bar adds a "),
                    .strong([.text("vertical accent")]),
                    .text(" so a quote sandwiched between paragraphs reads as set apart."),
                ])),

            Block(
                id: UUID(),
                kind: .blockquote(inlines: [
                    .text("Inline nodes survive into a blockquote — "),
                    .strong([.text("bold")]),
                    .text(", "),
                    .emphasis([.text("italic")]),
                    .text(", "),
                    .strikethrough([.text("struck through")]),
                    .text(", and "),
                    .link(children: [.text("links")], url: docsURL),
                    .text(" all render the same as in a paragraph, just on a muted color."),
                ])),

            headingIR(level: 2, [.text("Thematic break")]),

            paraIR([
                .text("Below this paragraph, a "),
                .code("---"),
                .text(" thematic break separates two unrelated sections."),
            ]),

            Block(id: UUID(), kind: .thematicBreak),

            paraIR([
                .text(
                    "After the rule, the second section starts. "
                        + "The break is decorative only — no glyphs, no selection, "
                        + "and the cell skips both the I-beam cursor and the highlight pass.")
            ]),

            headingIR(level: 2, [.text("Tool groups")]),

            paraIR([
                .text(
                    "A tool group folds a batch of related tool calls into a single row. "
                        + "Click the group header to reveal the per-file headers; click any "
                        + "file header to reveal its diff. Three independently-foldable "
                        + "layers (group, item header, hunks card) share the coordinator's "
                        + "fold-state dict, so toggling one doesn't reset another.")
            ]),

            Block(
                id: UUID(),
                kind: .toolGroup(
                    ToolGroupBlock(
                        activeTitle: String(localized: "Editing \("scripts/cleanup.sh")"),
                        expandedActiveTitle: String(localized: "Editing \(3) files"),
                        completedTitle: String(localized: "Edited \(3) files"),
                        children: [
                            .fileEdit(
                                FileEditChild(
                                    id: UUID(),
                                    label: String(localized: "Edit \("Sources/Greeter.swift")"),
                                    activeLabel: String(localized: "Editing \("Sources/Greeter.swift")"),
                                    filePath: "Sources/Greeter.swift",
                                    diff: DiffBlock(
                                        filePath: "Sources/Greeter.swift",
                                        oldString: """
                                            func greet(name: String) {
                                                print("Hello, \\(name)!")
                                                print("Welcome.")
                                            }
                                            """,
                                        newString: """
                                            func greet(name: String, greeting: String = "Hello") {
                                                print("\\(greeting), \\(name)!")
                                                print("Welcome to the app.")
                                                logger.info("Greeted \\(name)")
                                            }
                                            """))),
                            .fileEdit(
                                FileEditChild(
                                    id: UUID(),
                                    label: String(localized: "Write \("config/server.yaml")"),
                                    activeLabel: String(localized: "Writing \("config/server.yaml")"),
                                    filePath: "config/server.yaml",
                                    diff: DiffBlock(
                                        filePath: "config/server.yaml",
                                        oldString: nil,
                                        newString: """
                                            port: 8080
                                            host: localhost
                                            debug: true
                                            log_level: info
                                            tls:
                                              enabled: false
                                              cert: /etc/ssl/server.crt
                                            """))),
                            .fileEdit(
                                FileEditChild(
                                    id: UUID(),
                                    label: String(localized: "Delete \("scripts/cleanup.sh")"),
                                    activeLabel: String(localized: "Deleting \("scripts/cleanup.sh")"),
                                    filePath: "scripts/cleanup.sh",
                                    diff: DiffBlock(
                                        filePath: "scripts/cleanup.sh",
                                        oldString: """
                                            #!/bin/bash
                                            echo "starting cleanup"
                                            rm -rf /tmp/cache
                                            rm -rf /tmp/logs
                                            rm -rf /var/cache/build
                                            echo "done"
                                            """,
                                        newString: ""))),
                        ]))),

            paraIR([
                .text(
                    "Header-only and rich tool kinds in one group — read / generic "
                        + "render as static labels without a chevron; bash / grep / glob / "
                        + "webFetch / webSearch / askUserQuestion / agent each expose their "
                        + "own body card when expanded.")
            ]),

            Block(
                id: UUID(),
                kind: .toolGroup(
                    ToolGroupBlock(
                        activeTitle: String(localized: "Inspecting the repo"),
                        expandedActiveTitle: String(localized: "Inspecting \(8) tools"),
                        completedTitle: String(localized: "Inspected the repo"),
                        children: [
                            .read(
                                ReadChild(
                                    id: UUID(),
                                    label: String(localized: "Read \("Sources/main.swift")"),
                                    activeLabel: String(localized: "Reading \("Sources/main.swift")"),
                                    filePath: "Sources/main.swift",
                                    content: """
                                        import Foundation

                                        @main
                                        struct App {
                                            static func main() {
                                                print("hello, world")
                                            }
                                        }
                                        """)),
                            .bash(
                                BashChild(
                                    id: UUID(),
                                    label: String(localized: "Ran \("make build")"),
                                    activeLabel: String(localized: "Running \("make build")"),
                                    command: "make build",
                                    stdout: """
                                        Compiling Foo.swift
                                        Compiling Bar.swift
                                        ** BUILD SUCCEEDED **
                                        """,
                                    stderr: "warning: deprecated API in Bar.swift")),
                            .grep(
                                GrepChild(
                                    id: UUID(),
                                    label: String(localized: "Grepped \("TODO")"),
                                    activeLabel: String(localized: "Grepping \("TODO")"),
                                    pattern: "TODO",
                                    filenames: [
                                        "Sources/Foo.swift",
                                        "Sources/Bar.swift",
                                        "Tests/FooTests.swift",
                                    ],
                                    content: """
                                        Sources/Foo.swift:12: // TODO: rename
                                        Sources/Foo.swift:27: // TODO: nullable?
                                        Sources/Bar.swift:8:  // TODO: handle error
                                        """)),
                            .glob(
                                GlobChild(
                                    id: UUID(),
                                    label: String(localized: "Globbed \("**/*.swift")"),
                                    activeLabel: String(localized: "Globbing \("**/*.swift")"),
                                    pattern: "**/*.swift",
                                    filenames: [
                                        "Sources/App.swift",
                                        "Sources/Foo.swift",
                                        "Sources/Bar.swift",
                                        "Sources/Views/Home.swift",
                                        "Tests/AppTests.swift",
                                    ],
                                    truncated: true)),
                            .webFetch(
                                WebFetchChild(
                                    id: UUID(),
                                    label: String(localized: "Fetched \("https://example.com")"),
                                    activeLabel: String(localized: "Fetching \("https://example.com")"),
                                    url: "https://example.com/docs",
                                    httpStatus: 200,
                                    result: """
                                        Example Docs

                                        This is the fetched body, rendered as plain text. \
                                        Links, lists, and emphasis are not re-parsed in the native \
                                        renderer; the raw response is shown verbatim so callers can \
                                        copy it straight into another tool.
                                        """)),
                            .webSearch(
                                WebSearchChild(
                                    id: UUID(),
                                    label: String(localized: "Searched \("swift concurrency")"),
                                    activeLabel: String(localized: "Searching \("swift concurrency")"),
                                    query: "swift concurrency",
                                    results: [
                                        .init(
                                            title: "Swift Concurrency — the road to Swift 6",
                                            url: "https://swift.org/blog/concurrency",
                                            snippet: "A concise overview of structured concurrency in Swift."),
                                        .init(
                                            title: "WWDC: Meet async/await",
                                            url: "https://developer.apple.com/videos/play/wwdc2021/10132",
                                            snippet: nil),
                                    ])),
                            .askUserQuestion(
                                AskUserQuestionChild(
                                    id: UUID(),
                                    label: String(localized: "Asked \(2) questions"),
                                    activeLabel: String(localized: "Asking \(2) questions"),
                                    items: [
                                        .init(
                                            question: "Which framework should we use for navigation?",
                                            answer: "NavigationSplitView"),
                                        .init(
                                            question: "Should the sidebar be collapsible by default?",
                                            answer: nil),
                                    ])),
                            .agent(
                                AgentChild(
                                    id: UUID(),
                                    label: String(localized: "Ran agent \("research")"),
                                    activeLabel: String(localized: "Running agent \("research")"),
                                    description: "Audit repo for TODOs",
                                    progress: [
                                        "Searching documentation…",
                                        "Found 12 matches",
                                        "Cross-referencing tests",
                                    ],
                                    output: """
                                        Found 12 TODO comments across 7 files.

                                        Hottest cluster sits in Sources/Foo.swift (4 TODOs).
                                        """)),
                            .generic(
                                GenericChild(
                                    id: UUID(),
                                    label: String(localized: "Skill(\("pdf"))"),
                                    activeLabel: String(localized: "Skill(\("pdf"))"))),
                        ]))),

            // Running tool group — demonstrates the (status, fold)
            // title matrix. Group renders in the "primed" palette
            // (brighter title + chevron) and follows the Session
            // three-state rule:
            //   - collapsed → last child's progressive fragment
            //                 ("Running npm test")
            //   - expanded  → aggregated progressive
            //                 ("Running 3 tools")
            // The Bash child is marked `.running` (progressive header
            // + label colour); the earlier Read / Grep children stay
            // at `.completed` so the row demonstrates per-child
            // status mixing in a single group. State pushes are wired
            // in `body.task` via `controller.setToolStatus`, so the
            // running palette is applied as the rows mount.
            Block(
                id: TranscriptDemoView.runningGroupBlockId,
                kind: .toolGroup(
                    ToolGroupBlock(
                        activeTitle: String(localized: "Running \("npm test")"),
                        expandedActiveTitle: String(localized: "Running \(3) tools"),
                        completedTitle: String(localized: "Ran \(3) tools"),
                        children: [
                            .read(
                                ReadChild(
                                    id: TranscriptDemoView.runningReadChildId,
                                    label: String(localized: "Read \("package.json")"),
                                    activeLabel: String(localized: "Reading \("package.json")"),
                                    filePath: "package.json",
                                    content: """
                                        {
                                          "name": "demo",
                                          "version": "1.0.0",
                                          "scripts": {
                                            "test": "jest"
                                          }
                                        }
                                        """)),
                            .grep(
                                GrepChild(
                                    id: TranscriptDemoView.runningGrepChildId,
                                    label: String(localized: "Searched \("describe(")"),
                                    activeLabel: String(localized: "Searching \("describe(")"),
                                    pattern: "describe(",
                                    filenames: [
                                        "tests/login.test.js",
                                        "tests/cart.test.js",
                                    ],
                                    content: nil)),
                            .bash(
                                BashChild(
                                    id: TranscriptDemoView.runningBashChildId,
                                    label: String(localized: "Ran \("npm test")"),
                                    activeLabel: String(localized: "Running \("npm test")"),
                                    command: "npm test",
                                    // Streams nil-ed out — the running child has
                                    // not yet produced output, matching the live
                                    // shape of an in-flight bash tool.
                                    stdout: nil,
                                    stderr: nil)),
                        ]))),
        ]
    }

    /// Stable ids for the running-demo group + its children so the
    /// `.task` block can call `setToolStatus(...)` against known
    /// surfaces without scanning the block list at runtime. Internal
    /// scope so the snapshot test can replay the same status puts
    /// after pre-seeding the controller from `initialBlocks`.
    static let runningGroupBlockId = UUID()
    static let runningReadChildId = UUID()
    static let runningGrepChildId = UUID()
    static let runningBashChildId = UUID()
}

/// SF Symbol → NSImage at a fixed point size. Held by the `initialBlocks`
/// closure so the same instances persist across renders.
private struct DemoIcons {
    let cpu: NSImage
    let network: NSImage
    let globe: NSImage
    let headset: NSImage

    init() {
        let config = NSImage.SymbolConfiguration(pointSize: 88, weight: .regular)
        cpu = Self.make("cpu", config: config)
        network = Self.make("network", config: config)
        globe = Self.make("globe.asia.australia", config: config)
        headset = Self.make("visionpro", config: config)
    }

    private static func make(
        _ name: String,
        config: NSImage.SymbolConfiguration
    ) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: 240, height: 140))
    }
}

#Preview {
    TranscriptDemoView()
        .frame(width: 720, height: 720)
        .environment(\.syntaxEngine, SyntaxHighlightEngine())
}
