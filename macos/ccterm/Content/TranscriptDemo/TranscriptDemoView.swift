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
    @State private var controller = Transcript2Controller()
    /// Monotonic counter for extra-pool cycling. Decoupled from
    /// `blockCount` so deletions don't reset the cycle (which would
    /// otherwise pin every appended block to `extraPool[0]` once the live
    /// count dropped below `initialBlocks.count`).
    @State private var extraAddCount: Int = 0

    var body: some View {
        NativeTranscript2View(controller: controller)
            .frame(minWidth: 320, minHeight: 240)
            .overlay(alignment: .bottom) { controlPanel }
            .task {
                // Idempotent: only seed once. Survives Preview re-renders
                // that would otherwise re-fire a side-effecting `@State`
                // default closure.
                if controller.blockCount == 0 {
                    controller.loadInitial(Self.initialBlocks)
                }
            }
    }

    private var controlPanel: some View {
        HStack(spacing: 10) {
            Button {
                let next = Self.extraBlock(at: extraAddCount)
                controller.apply(.insert(at: controller.blockCount, [next]))
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

private extension TranscriptDemoView {
    /// Built once at first access. Stable `Block.id`s + stable `NSImage`
    /// instances so the diff sees no churn across re-renders.
    static let initialBlocks: [Block] = makeInitialBlocks()

    /// Hardcoded extra entries appended by the "Add Message" button. Cycled
    /// through by `currentCount` so each click visibly adds something new.
    static let extraPool: [Block.Kind] = [
        .paragraph(
            "Update — A late-breaking note from one of the framework "
            + "maintainers suggests the Pacific instruction extensions ship "
            + "with two undocumented opcodes used internally for scheduling. "
            + "Apple has not commented on whether these will be exposed to "
            + "third-party developers."
        ),
        .heading("更新 · 后续动态"),
        .paragraph(
            "据多家媒体跟进报道,前述监管新规将在公开征求意见 30 天后正式生效。"
            + "目前已有 7 家企业提交了书面反馈,主要集中在过渡期长度和数据保存格式两个方面。"
            + "监管部门表示会在听证会后整理意见并公布最终版本。"
        ),
        .paragraph(
            "Side note — Several open-source projects have begun publishing "
            + "matrix-multiplication kernels tuned for the new memory "
            + "subsystem. Early benchmarks show 1.4x–1.7x improvements on "
            + "INT8 GEMM workloads compared with hand-tuned NEON intrinsics, "
            + "though the gap narrows considerably at larger problem sizes "
            + "where memory-bandwidth ceiling dominates."
        ),
    ]

    static func extraBlock(at addIndex: Int) -> Block {
        let kind = extraPool[addIndex % extraPool.count]
        return Block(id: UUID(), kind: kind)
    }

    static func makeInitialBlocks() -> [Block] {
        let icons = DemoIcons()
        return [
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

    static func heading(_ text: String) -> Block {
        Block(id: UUID(), kind: .heading(text))
    }

    static func para(_ text: String) -> Block {
        Block(id: UUID(), kind: .paragraph(text))
    }

    static func image(_ image: NSImage) -> Block {
        Block(id: UUID(), kind: .image(image))
    }
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

    private static func make(_ name: String,
                             config: NSImage.SymbolConfiguration) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: 240, height: 140))
    }
}

#Preview {
    TranscriptDemoView()
        .frame(width: 720, height: 720)
}
