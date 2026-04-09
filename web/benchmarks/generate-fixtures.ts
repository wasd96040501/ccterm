/**
 * Generate synthetic message fixtures for benchmarking.
 *
 * Produces a mix of user (30%) and assistant (70%) messages with realistic
 * Markdown content of varying complexity.
 */

import type { ChatMessage } from '../src/types/message'
type Message = ChatMessage

// ---------------------------------------------------------------------------
// Assistant message templates (various Markdown complexity)
// ---------------------------------------------------------------------------

const ASSISTANT_TEMPLATES: string[] = [
  // Short plain text
  `推荐几款：

1. **iTerm2** — 老牌经典，功能全面，分屏、热键窗口、搜索都很强
2. **Warp** — 基于 Rust，内置 AI 辅助，块级命令输出，现代化 UI
3. **Alacritty** — GPU 加速渲染，极简配置，追求速度的首选
4. **Kitty** — 同样 GPU 渲染，支持图片协议，可扩展性强

如果你看重**速度**选 Alacritty，看重**功能**选 iTerm2，想要**现代体验**选 Warp。`,

  // Code block + explanation
  `## 快速排序 (Quick Sort)

快速排序是一种高效的排序算法，平均时间复杂度为 **O(n log n)**。

\`\`\`typescript
function quickSort(arr: number[]): number[] {
  if (arr.length <= 1) return arr;

  const pivot = arr[Math.floor(arr.length / 2)];
  const left: number[] = [];
  const middle: number[] = [];
  const right: number[] = [];

  for (const item of arr) {
    if (item < pivot) left.push(item);
    else if (item > pivot) right.push(item);
    else middle.push(item);
  }

  return [...quickSort(left), ...middle, ...quickSort(right)];
}

// 使用示例
const data = [38, 27, 43, 3, 9, 82, 10];
console.log(quickSort(data));
// => [3, 9, 10, 27, 38, 43, 82]
\`\`\`

### 复杂度分析

| 场景 | 时间复杂度 | 空间复杂度 |
|------|-----------|-----------|
| 最好 | O(n log n) | O(log n) |
| 平均 | O(n log n) | O(log n) |
| 最差 | O(n²) | O(n) |

> **注意**：上面的实现为了简洁使用了额外数组，原地排序版本空间更优。`,

  // Table-heavy
  `## HTTP/2 核心改进

### 多路复用 (Multiplexing)

HTTP/1.1 每个 TCP 连接同一时间只能处理一个请求。HTTP/2 在单个连接上并行传输多个请求/响应。

\`\`\`
HTTP/1.1:
连接1: GET /style.css ──────────────> response
连接2: GET /app.js   ──────────────> response
连接3: GET /image.png ─────────────> response

HTTP/2:
连接1: GET /style.css ──> response
        GET /app.js   ──> response
        GET /image.png ──> response
\`\`\`

### 性能影响

| 指标 | HTTP/1.1 | HTTP/2 |
|------|---------|--------|
| 并发请求 | 6-8 | 无限制 |
| 头部大小 | ~800 bytes | ~20 bytes |
| 首页加载 | 基准 | 快 15-30% |
| API 密集场景 | 基准 | 快 30-50% |`,

  // Long explanation with multiple sections
  `## 单体 vs 微服务：务实的选择

### 一句话总结

**先单体，有了痛点再拆微服务。**

#### 单体适合的场景

- 团队 < 10 人
- 产品早期，需求频繁变动
- 业务逻辑耦合度高
- 想快速迭代 MVP

#### 微服务适合的场景

- 团队 > 30 人，需要独立部署
- 不同模块有不同的扩展需求
- 业务域边界清晰
- 有成熟的 DevOps 基础设施

### 微服务的隐性成本

\`\`\`
单体部署：git push → CI → deploy（1 个流水线）

微服务部署：
├── 服务发现（Consul / Eureka）
├── API 网关（Kong / Envoy）
├── 链路追踪（Jaeger / Zipkin）
├── 集中日志（ELK / Loki）
├── 配置中心（Nacos / Apollo）
├── 容器编排（K8s）
├── 服务间认证（mTLS）
└── 分布式事务（Saga pattern）
\`\`\`

> *"如果你管不好一个单体，你也管不好微服务。"*

### 折中方案：模块化单体

模块间通过明确的接口通信，数据库表按模块隔离 schema。等某个模块确实需要独立扩展时，再拆出去。这比一开始就全拆微服务**省 80% 的运维成本**。`,

  // Short code-only
  `\`\`\`typescript
function debounce<T extends (...args: any[]) => any>(
  fn: T,
  delay: number
): (...args: Parameters<T>) => void {
  let timer: ReturnType<typeof setTimeout> | null = null;

  return function (this: any, ...args: Parameters<T>) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      fn.apply(this, args);
      timer = null;
    }, delay);
  };
}

// 使用
const handleSearch = debounce((query: string) => {
  fetch(\`/api/search?q=\${query}\`);
}, 300);
\`\`\`

关键点：
- 泛型保留原函数的参数类型
- \`this\` 绑定正确传递
- \`ReturnType<typeof setTimeout>\` 兼容 Node 和浏览器`,

  // Inline code + bullet list
  `各有所长：

- **JSON**：机器友好，解析快，无歧义，适合 API 和配置传输
- **YAML**：人类友好，支持注释和多行字符串，适合手写配置文件

选择建议：
- API 通信 → JSON
- CI/CD 配置（GitHub Actions, K8s）→ YAML
- 应用配置 → YAML（因为可以写注释）
- 数据存储 → JSON（解析性能好 10 倍以上）

**避免**在 YAML 中依赖隐式类型转换，比如 \`no\` 会被解析为 \`false\`，\`3.10\` 会变成 \`3.1\`。`,

  // CSS code block + HTML
  `## 响应式 CSS Grid 布局

\`\`\`css
.container {
  display: grid;
  gap: 16px;
  padding: 16px;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
}

.card {
  background: #1e1e2e;
  border-radius: 12px;
  padding: 24px;
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.card--featured {
  grid-column: span 2;
}

@media (max-width: 640px) {
  .card--featured {
    grid-column: span 1;
  }
}
\`\`\`

\`\`\`html
<div class="container">
  <div class="card card--featured">
    <h2>Featured Article</h2>
    <p>This spans two columns on wider screens.</p>
  </div>
  <div class="card">Card 1</div>
  <div class="card">Card 2</div>
</div>
\`\`\`

关键技巧是 \`repeat(auto-fill, minmax(280px, 1fr))\`：
- **auto-fill**：自动计算能放几列
- **minmax(280px, 1fr)**：每列最少 280px，剩余空间均分`,

  // Multi-code-block with Python
  `## Code Review: \`get_user\` 函数

发现 **3 个严重问题**：

#### 1. SQL 注入漏洞

\`\`\`python
# 危险：直接拼接字符串
user = db.query("SELECT * FROM users WHERE id = " + str(id))

# 修复：使用参数化查询
user = db.query("SELECT * FROM users WHERE id = %s", (id,))
\`\`\`

#### 2. 密码泄露

返回值中包含了 \`password\` 字段：

\`\`\`python
# 危险
return {"name": user.name, "email": user.email, "password": user.password}

# 修复
return {"name": user.name, "email": user.email}
\`\`\`

#### 3. SELECT * 反模式

\`\`\`python
user = db.query("SELECT name, email FROM users WHERE id = %s", (id,))
\`\`\`

### 改进版本

\`\`\`python
from typing import Optional, TypedDict

class UserInfo(TypedDict):
    name: str
    email: str

def get_user(user_id: int) -> Optional[UserInfo]:
    user = db.query(
        "SELECT name, email FROM users WHERE id = %s",
        (user_id,)
    )
    if user:
        return {"name": user.name, "email": user.email}
    return None
\`\`\``,
]

const USER_TEMPLATES: string[] = [
  '帮我写一个 TypeScript 的快速排序',
  '最近 AI 领域有什么大新闻吗？',
  '我的 React 列表渲染很慢，有上千条数据，怎么优化？',
  'macOS 上有什么好用的终端？',
  '帮我 review 一下这段代码：\n```python\ndef get_user(id):\n    user = db.query("SELECT * FROM users WHERE id = " + str(id))\n    if user:\n        return {"name": user.name, "email": user.email}\n    return None\n```',
  'Rust 和 Go 哪个更适合写后端？',
  '介绍一下 WebAssembly',
  'JSON 和 YAML 哪个好？',
  '写一个 CSS Grid 的响应式布局示例',
  '微服务和单体架构怎么选？',
  'Docker 和 Podman 有什么区别？',
  '给我写一个 debounce 函数',
  'HTTP/2 相比 HTTP/1.1 有什么优势？',
  'Promise.all 和 Promise.allSettled 的区别？',
  '你觉得 Bun 能替代 Node.js 吗？',
  '解释一下 React 的 useEffect 和 useLayoutEffect 区别',
  '怎么处理 Node.js 中的内存泄漏？',
  'Git rebase 和 merge 有什么区别？',
  'WebSocket 和 SSE 怎么选？',
  'TypeScript 的 type 和 interface 有什么区别？',
]

/**
 * Generate N messages with a ~30% user / ~70% assistant ratio.
 * Use different `seed` values to produce distinct message sets
 * (different IDs and template offsets) for conversation switch tests.
 */
export function generateMessages(count: number, seed = 0): Message[] {
  const messages: Message[] = []
  let isUser = true

  for (let i = 0; i < count; i++) {
    const type = isUser ? 'user' : 'assistant'
    const pool = isUser ? USER_TEMPLATES : ASSISTANT_TEMPLATES
    const content = pool[(i + seed) % pool.length]

    messages.push({
      type,
      id: `bench-s${seed}-${i}`,
      content,
      timestamp: Date.now() - (count - i) * 60000,
    } as Message)

    if (isUser) {
      isUser = false
    } else {
      isUser = ((i + seed) * 7 + 3) % 10 < 7
    }
  }

  return messages
}
