# UI Test 编写规范

XCUITest 端到端测试。慢(单测 10-30s),严禁默认全量;总是 `make test FILTER=...` 针对性跑。

## 架构

```
┌─────────────────────────┐                ┌──────────────────────────┐
│ XCUITest runner         │  app.launch()  │ ccterm.app (parent)      │
│ (cctermUITests target)  │ ─────────────▶ │ ─ AppState.applyTestMode │
│ launchEnvironment[ ... ]│                │ ─ InMemorySessionRepo    │
└─────────────────────────┘                │ ─ SessionHandle2.mock... │
                                           └─────────┬────────────────┘
                                                     │ spawn (binaryPath = self,
                                                     │        env CCTERM_RUN_AS_MOCK_CLI=1)
                                                     ▼
                                           ┌──────────────────────────┐
                                           │ ccterm 二进制 (child)    │
                                           │ AppEntryPoint            │
                                           │  → MockCLIRunner.run()   │
                                           │  → reads stdin / writes  │
                                           │    stdout 行级 JSON      │
                                           └──────────────────────────┘
```

测试模式开关:**只通过环境变量**(`launchEnvironment`),不通过命令行 flag。

| 环境变量                       | 作用                                                             |
|--------------------------------|------------------------------------------------------------------|
| `CCTERM_TEST_MODE=1`           | 总开关。开了才会切到 in-memory repo + 装 mock CLI override       |
| `CCTERM_MOCK_CLI_SCENARIO=foo` | 子进程跑哪个 scenario(见 `MockCLIRegistry`)                     |

## Mock 基础设施

### `InMemorySessionRepository`

`Services/Session/SessionRepository+InMemoryMock.swift`(DEBUG only)。纯内存,
与 `CoreDataSessionRepository` 同协议、相同行为契约。**永远不写主 CoreData
store**,UI test 跑完不会留脏数据。

### Mock CLI

`Services/Session/MockCLI/`(DEBUG only)。

- **`MockCLIBaseScenario`**:**绝大多数 scenario 应继承此类**。提供"贴近真
  claude CLI"的默认行为(initialize ack + system.init、interrupt ack + result.error、
  user echo + result.success、其它 control_request 一律 ack),scenario 只 override
  自己测试关心的那个钩子。所有"mock claude 怎么行动"都是 **test-specific** 的,
  由 scenario 决定 —— mock CLI 框架(Runner/Sender/Parser)只提供脚手架。

  override 钩子:`onStart` / `onInitialize` / `onInterrupt` / `onControlRequest`(其它 subtype)
  / `onUserMessage` / `onControlResponse` / `onUnknown`。

- **`MockCLIScenario`**(协议):仅当需要完全自定义路由 / 跳过默认解析(典型:
  chaos test 直接读 raw JSON 并随机 emit)时才直接实现。补两个回调 `onStart`
  / `onIncoming`,所有路由自己负责。

- **`MockCLISender`**:写 stdout 的便捷句柄。常用消息有快捷方法:
  - `ackControlSuccess(requestId:response:)` / `ackControlError(...)` — 响应 host 的 control_request
  - `sendSystemInit(sessionId:model:)` — 系统 init 信号
  - `echoUser(text:uuid:sessionId:)` — echo user 消息(用于 queued→confirmed 匹配)
  - `sendAssistantText(_:sessionId:messageId:)` — assistant 文本
  - `sendResultSuccess(...)` / `sendResultError(...)` — turn 结束
  - `sendJSON(_:)` — 任意 JSON(自定义边界场景用)

- **`MockCLIRunner`**:子进程入口,读 stdin → 解析 → 派发给 scenario。
  EOF 时 `exit(0)`(让 `SessionHandle2.onProcessExit` 走干净退出)。

- **`MockCLIRegistry`**:`name → factory` 查找表。**新增 scenario 必须在这里注册**,
  名字与测试里的 `CCTERM_MOCK_CLI_SCENARIO` 值匹配。

### 新增 scenario 的流程

1. 在 `Services/Session/MockCLI/Scenarios/<Name>Scenario.swift` 写新类型,**继承
   `MockCLIBaseScenario`**,只 override 测试关心的钩子:
   ```swift
   #if DEBUG
   final class MyScenario: MockCLIBaseScenario {
       // 偏离默认:turn 永远挂着 —— echo user 但不发 result
       override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
           if let uuid { send.echoUser(text: text, uuid: uuid, sessionId: sessionId) }
       }
       // 其它钩子(initialize / interrupt / ...)走 base 默认行为,无需 override
   }
   #endif
   ```
2. 在 `MockCLIRegistry.scenarios` 加一行:`"myScenario": { MyScenario() }`
3. 测试里 `launchEnvironment["CCTERM_MOCK_CLI_SCENARIO"] = "myScenario"`

一个 scenario 服务一个测试用例(或一组共享同一种"CLI 行为偏离"的相关用例),
不要往一个 scenario 里塞多个无关的行为分支 —— 多写几个 scenario 类,每个只
override 自己关心的那一两个钩子,更容易看清"这个 scenario 跟真 claude CLI 的
唯一区别是什么"。chaos test 等需要随机/复杂行为的场景可以直接实现
`MockCLIScenario` 协议,绕过 base 的默认解析,自己读 raw JSON 决定怎么 emit。

### 不要做的事

- ❌ 加 launch argument(如 `--skip-bootstrap` / `--force-running`)。这是 trick,
  会在生产路径里堆条件分支。**唯一被认可的测试入口是 mock CLI scenario**——
  通过实现真实 CLI 协议来覆盖边界场景。
- ❌ 在 SessionHandle2 / SessionManager2 加只供测试用的 `forceXxxForTest()` 方法。
- ❌ 直接读写 `pendingTurnCount` / `status` 等内部字段。要让 isRunning=true 就
  通过 scenario 让 turn 真的挂着。
- ❌ 在 production 代码里 `#if DEBUG` 跳过常规路径。mock 接入只在
  `makeAgentConfig` / `AppState.init` 两处有 `#if DEBUG` 分支,且都是**注入**
  而非**绕过**。

## 测试用例编写规范

### 文件组织

- 一个 invariant 一个 test method(不串多个 user journey)
- 一类 invariant 一个 test class(stop button / send button / sidebar 选中态 / ... )
- 用 `MainActor` 跑 UI test(`@MainActor func testXxx()`)
- `continueAfterFailure = false` 默认设上,失败立刻停

### 启动 app

```swift
let app = XCUIApplication()
app.launchEnvironment = [
    "CCTERM_TEST_MODE": "1",
    "CCTERM_MOCK_CLI_SCENARIO": "myScenario",
]
app.launch()
```

**禁止用 `launchArguments`** 控制 mock 行为。`launchArguments` 等价 `CommandLine.arguments`,
有"trick 味";`launchEnvironment` 是隔离的测试通道。

### Accessibility identifier 约定

```swift
.accessibilityIdentifier("ComponentName.ElementName")
// 如:InputBar2.SendButton, InputBar2.StopButton, InputBar2.TextField
```

注意:
- **加在子元素上**,不要加在外层容器(SwiftUI 容器 id 会传染给所有后代,覆盖子元素自己的 id)
- NSViewRepresentable 包的 NSTextView 无法直接被 a11y query 拿到 —— 点击外层容器让焦点落到 NSTextView,再 `app.typeText(...)`

### 等待元素

XCUI 默认按 element ref 拿,需要等待用 `waitForExistence(timeout:)`:
```swift
XCTAssertTrue(button.waitForExistence(timeout: 5), "button should appear after X")
```
timeout 取宽点(3-10s),但避免无脑 sleep。点击需要等到 `isHittable=true` 时:
```swift
_ = button.waitForExistence(timeout: 5)
button.click()
```

### 写键盘事件的注意点

- `app.typeText(...)` / `app.typeKey(...)` 走 `CGEventPost` 系统级输入栈。
  **机器装有非英文 IME 且作为活动输入源**时可能触发输入法选择弹窗或 System
  Settings,污染测试环境。
- 跑 UI test **前置条件**:输入源是 English/ABC。
- 如果一个测试根本不需要键盘,优先用 mock CLI scenario 让状态自然达成,不用
  键盘事件。

### 断言风格

- 期望存在:`waitForExistence(timeout:)` + `XCTAssertTrue`
- 期望消失:`XCTAssertFalse(element.exists)`(不需要 wait;UI mutation 同步可见)
- 给 message 写有效信息:**说明本断言违反了什么 invariant**,而不是 "X should be Y"

## 运行测试

```bash
# 单 method(开发最常用)
make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState

# 单 class
make test FILTER=InputBar2StopButtonUITests

# 全量(慢,只在临发 PR 时跑)
make test-all
```

输出格式:成功一行 + xcresult 路径;失败给关键 assertion + crash log + xcresult。
xcresult bundle 含 screenshots 和 video,定位"按钮没出现"这类问题最直接,
`open /tmp/ccterm-test-.../result.xcresult` 自动 Xcode 加载。
