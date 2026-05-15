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

- **`MockCLIScenario`**:测试者实现的 protocol。补两个回调:
  - `onStart(send:)` — 子进程启动调一次,多数 scenario 不做事
  - `onIncoming(_:send:)` — 收到 host 的每条 JSON 时调用

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

1. 在 `Services/Session/MockCLI/Scenarios/<Name>Scenario.swift` 写新类型,实现 `MockCLIScenario`:
   ```swift
   #if DEBUG
   final class MyScenario: MockCLIScenario {
       private var sessionId = "11111111-1111-1111-1111-111111111111"

       func onIncoming(_ message: MockCLIIncoming, send: MockCLISender) {
           switch message {
           case .controlRequest(let subtype, let requestId, _, _):
               // ack initialize / interrupt / set_model / ...
               send.ackControlSuccess(requestId: requestId)
               if subtype == "initialize" { send.sendSystemInit(sessionId: sessionId) }
           case .userMessage(let text, let uuid, _):
               if let uuid { send.echoUser(text: text, uuid: uuid, sessionId: sessionId) }
               // 后续推送 assistant / result...
           default: break
           }
       }
   }
   #endif
   ```
2. 在 `MockCLIRegistry.scenarios` 加一行:`"myScenario": { MyScenario() }`
3. 测试里 `launchEnvironment["CCTERM_MOCK_CLI_SCENARIO"] = "myScenario"`

scenario 行为**尽量贴近真 claude CLI**(标准 ack + 标准 echo),只在为了测试
特定边界(故意挂起、故意发 error 等)时偏离。一个 scenario 服务一类测试场景,
不要往一个 scenario 里塞多个无关的行为分支。

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
