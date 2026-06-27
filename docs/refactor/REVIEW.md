# REFACTOR-PLAN.md · 干净上下文对抗审查记录

> 本文是对 [`REFACTOR-PLAN.md`](REFACTOR-PLAN.md) 的**最终对抗审查**汇总。4 个**上下文干净**的独立审核员（各只读最终方案 + 真实代码库 + 项目自带的 4 份 CLAUDE.md 不变量文档，**不读**任何 `nodes/` 推演产物）从不同视角挑战。原始产物：`nodes/review-architecture.md`、`nodes/review-perf-runloop.md`、`nodes/review-parity-card.md`、`nodes/review-clarity-impl.md`（这些 `nodes/` 产物已从本 PR 移除,保留在分支历史）。

## 总裁决

| 视角 | 裁决 | 破坏性能契约 | 功能降级 | 过度设计 | 内部矛盾 | blocker | major |
|---|---|---|---|---|---|---|---|
| 架构 & 数据流健全性 | sound-with-fixes | ❌ | ❌ | ❌ | ❌ | 0 | 2 |
| 性能契约 & runloop 安全（硬关） | sound-with-fixes | ❌ | ❌ | ❌ | ❌ | 0 | 2 |
| 功能平价 & 卡片修复正确性 & 过度设计 | sound-with-fixes | ❌ | ❌ | ❌ | ❌ | 0 | 2 |
| 清晰度 & 可实施性（新人视角） | sound-with-fixes | ❌ | ❌ | ❌ | ⚠️(1 处) | 0 | 1 |

**结论：方案健全（sound-with-fixes）。零 blocker，不破坏 transcript §2 性能契约，不破坏 §2.19 attach 契约或任何 runloop-tick 时序，不降级功能，不过度设计。** 权限卡片的根因分析、位置常量修正（36 非 100）、`PassthroughHostingView` 强制项均经 4 个审核员独立核实为**事实正确**。需修复的是若干**接缝欠规约、测试守门缺口、一处步骤排序内部矛盾、几处事实/标注微误**——全部可在落地前于方案内解决，无一改变方案骨架。

下表列出审查暴露的问题与**处置**（处置已回填进 `REFACTOR-PLAN.md`）。

## Major 问题与处置

| # | 来源视角 | 问题 | 处置（已回填方案） |
|---|---|---|---|
| **R1** | 清晰度 | **内部矛盾**：§8 P2 说 un-erase `AnyView` 必须**先于** `DetailContext`（漏注才会变编译错），但 §9 表把 step 6（DetailContext）排在 step 7（un-erase）**之前**——于是 `injectDetailEnvironment` 有一个 PR 处于「无编译期守护」状态。 | **已修**：§9 表对调——un-erase（连同 `mountFillPaneHost`）成为 step 6，`DetailContext` 成为 step 7；§8 P2 与 §9 顺序一致。 |
| **R2** | 性能/runloop · 架构 | **卡片悬浮宿主的 cursor-rect 爆炸半径**：M2 要求 `hitTest→nil` 挡点击，但整 pane 的 `NSHostingView` **即便 hitTest→nil 仍会为整个 bounds 注册 cursor/tracking rect**，遮挡 transcript 的 I-beam（这正是 scrim 用纯 `NSView` 的根本原因，不止是点击穿透）。 | **已修**：§7.4 新增 **M5**——`PassthroughHostingView` 必须**同时**压制非卡片区的 cursor/tracking-rect 注册（覆写 `resetCursorRects`/避免 tracking area），或把卡片宿主**只钉到卡片实际占用的底部区域**而非整 pane。守门 `DetailPaneTranscriptHitTestTests`。 |
| **R3** | 性能/runloop | **卡片宿主 z-order 未明确**，且与 step 13 交互：必须明确它在 `loadView` 中**于 `composeOrBarHost` 之后**添加一次（置顶），而 attach 时 transcript 仍 `.below topScrim`（保持在悬浮层之下）。 | **已修**：§7.4 新增 **M6** 明确 z-anchor；§9 排序注补充 step 13 抽取时不得把 transcript 重插到 `permissionCardHost` 之上。 |
| **R4** | 架构 | **`PermissionCardOverlay` 选择路由欠规约**：宿主 VC 级常驻，但卡片只应在 `.session(_)` 出现；须说明它按 `ChatComposeStack.content(for:)` 同样的方式（`.id(sid)` 键控）解析会话，否则快速切换时可能在新 transcript 上渲染陈旧/错会话的卡片。 | **已修**：§7.3 补一行——overlay 复用 `ChatComposeStack` 的 `model.selection` 路由 + `.id(sid)` 会话解析，使「栏宿主空时卡片宿主也空」。 |
| **R5** | 平价 | **§7.7 高估了卡片移动的测试保护**：`PermissionCardWiringTests` 在 `session.respond` 边界驱动，**不**经 card-button→闭包→respond 路径，搬错线（如调换 allowOnce/allowAlways、丢 `updatedInput`）所有引用 test 仍绿。 | **已修**：§7.7 + §9 平价单新增任务——加一个轻量 test：用 spy `Session` 构造 `PermissionCardOverlay`，断言 4 个动作各自以正确 decision 抵达 `session.respond`（驱动 overlay 闭包，非边界）。 |
| **R6** | 性能/runloop | **step 13 的 cross-VC 接缝**（`currentSession` 归属、`topScrim` z-anchor、`applyScrimCutouts` 坐标转换）merge gate **不覆盖**；「逐字搬移」对 §2.19 充分，但对 swap 的运行时正确性不足。 | **已修**：§8 P5 接缝条目升级为明确契约——`currentSession` 选单一所有者（不在两对象间重复），把 `topScrim`/insert 闭包交给 coordinator，保 `applyScrimCutouts` 路径；显式以 `DetailPaneTranscriptHitTestTests`（走真实 swap）为守门。 |
| **R7** | 平价 | **demo VC 迁移是真实工作量**，非脚注：`PermissionSessionDemoViewController` 经 `GeometryReader+PreferenceKey+height-constraint` 直接渲染 `ChatRestingBar` 演示卡片→宿主耦合；卡片移出后 demo 失去卡片展示，须同样挂 `permissionCardHost`。 | **已修**：§7.4 M3 + §9 step 5 标注为**显式子任务**（DEBUG-only，不影响发运，但会静默坏掉 demo）。 |

## 内部一致性修正（事实/标注微误）

| 项 | 修正 |
|---|---|
| `contextUsage` 标注 | §5 目标树与 §8 P8 把 `ContextUsageCache` 标为 `[value]`/「纯值」，但 `contextUsage`/`contextUsageFetchedAt` 实为**被观察的 @Observable 字段**（非 `@ObservationIgnored`），有 SwiftUI reader（`ContextRingButton` 经 `session.contextUsage`）。**改为**：与 `tasks`/`todos` 同属「观察嵌套」一类——子对象须 `@Observable` 且被 tracked 属性持有，test 须断言实时重渲染。 |
| 卡片决策闭包位置 | §5/§7 的 ASCII 把卡片接线画在 `InputBarChrome` 路径下，实际 4 个决策闭包内联在 **`ChatRestingBar`**（`InputBarChrome.swift:143-162`）。逐字搬移须从 `ChatRestingBar` 取，不是 `InputBarChrome`。 |
| `SessionRuntime` 体量 | 实为 **~3249 行 / 11 文件**（方案写 ~3000 / 9 文件，文件数略少报；不影响结论）。 |
| `PassthroughHostingView` 历史 | 该类型曾存在、现仅余 `DetailRouterViewController.swift:27` 的墓碑注释。M2/M5 视其为**新增**（结论正确），但应注明「曾被删除，于卡片宿主旁重新引入」以免实现者误找旧类。 |
| `isGroupableAssistant` 行号 | §8 P7 引「`+Receive.swift:700` 注释」，实际声明在 `:701`；谓词已被 `ReverseEntryBuilder.swift:84` + `JSONLReversePageSource.swift:135` 共享（核实无误），`EntryGrouping` 确为不存在的符号（0 命中）——「bridge uses EntryGrouping」标注确属幻影，方案的修正正确。 |
| `ChatRestingBar`/`ChatComposeStack` 文件锚点 | 二者贯穿全文但未注文件：`ChatRestingBar` 在 **`Content/Chat/InputBarChrome.swift`**，`ChatComposeStack` 在 **`App/AppKit/ChatSessionViewController.swift:605`**。已在 §2 树补文件路径。 |
| `Content/Chat/CLAUDE.md` scrim 名漂移 | 上游不变量文档仍把顶 scrim 称 `TranscriptScrimView`（基类），实为 `TranscriptTopScrimView`——已列入 §8 的文档收尾清单（与 `RootView2`×8、AppState `.environment` 漂移并列）。 |
| P4 forwarder 返回值 | `markTaskStoppedLocally` 返回 `Bool`；`Session.stopBackgroundTask` forwarder 应签名为 `Void`（当前调用方已弃用返回值），勿误带 `-> Bool` 重新泄漏 runtime 细节。 |

## 被低估的最大风险（来自清晰度审查）

**step 13 的「同会话 crossfade」（`fadingOutTranscript`，`ChatSessionViewController.swift:113`）顺序不在两道 merge gate 的覆盖内**——两道 gate 驱动 `present→attachSession`，验证的是 **attach 单宽 tile 契约**，与同会话 crossfade 的 finish-before-new-attach 是**不同路径**。若本方案会出回归，最可能是同会话 crossfade 的单帧撕裂/滚动条陈旧闪。**处置**：§9.1 已补——要么命名一个覆盖 `fadingOutTranscript` finish-before-attach 顺序的 test，要么明确该路径为「仅手动冒烟」并接受残余风险（A→B→A→A 切换、原地 promotion 各跑一遍）。

## 审核员一致背书（不要再二次质疑的部分）

- **核心诊断**（架构已约 90% 单向；本方案是外科手术而非重写；两条主轴 + 唯一向上结构边）经代码核实属实。
- **P1/P2**（DI 收敛 + 删死注入）是最高价值最低风险，事实精确；`DetailContext` 是真实的耦合削减（增删依赖 1 处），非为干净而干净。
- **P4** 在产品里闭合唯一真违例（façade），方向正确。
- **§6 数据流宪法**与 §6.1 边判决忠实描述了代码已有行为；每条「保留命令式边 X 因 runloop 理由 Y」都有真实时序支撑，非债务粉饰。
- **§7 卡片根因**端到端正确（union-height 撑大 bottom-anchored 宿主就是代码自身的文档化设计）；inset 固定 112 不跳；M1=36、M2 强制 PassthroughHostingView 均经核实。
- **反过度设计**：P6 降为可选、P7 缩小/放弃、P8 排除 `TurnUsageMeter`、P9/P11 推迟、§11「明确不做」表——每条拒绝都有真实不变量支撑;审核员均称 §11 是全文最强部分,且**未发现任何应砍而未砍的过度设计**。
</content>
