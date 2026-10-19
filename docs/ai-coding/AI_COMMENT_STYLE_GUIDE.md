# AI 注释规范

本规范约束 AI 在 `imctl` 中新增或修改代码时如何写注释。目标是让注释长期有维护价值，尤其是把"对真实客户端实测得到的事实"和"设计口径"区分开，而不是留下机械的"AI 改了什么"痕迹。

## 0. AI 执行流程

- 先识别本次涉及的文件类型：Swift 源码、Swift 测试、Shell 脚本、Markdown 文档、JSON 夹具、plist、Java / YAML（代理与消费方）。
- 优先读取本项目已有规范：`AI_CODING_GUIDE.md`、本文件、`SECURITY_CODING_SPEC.md`、`AI_ENGINEERING_GUARDRAILS.md`。
- 再查对应文件类型的官方或事实主流规范，并确认是否适用于当前上下文。
- 本文件尚未覆盖的文件类型：先把规范来源、适用边界和本项目落地规则补充到第 9 节，再改目标文件。
- 无法联网核验规范时只用本文件已有规则，并在交付说明写明"未联网刷新外部规范"。
- 不为了统一风格批量重排既有文件；注释优化必须和本次改动、风险说明或可维护性问题直接相关。

## 1. 总原则

- 优先让代码自解释：清晰命名、小而单一的函数、有意义的常量与枚举 case；注释是代码无法自解释时的补充。
- 注释只解释代码看不出的内容：业务意图、风险边界、协议约束、客户端怪癖、为什么不能删的兼容逻辑、失败处理为什么安全。
- **客户端事实必须带日期与版本**：例如 `// verified 2026-09-11 on 5.0.10: AXMainWindow is reachable when the window sits on another Space`。没有日期的"事实"会在客户端升级后误导维护者。
- **口径与实测分开**：设计目标写 "target: …"、"not yet verified on …"；实测写日期。不得把规格里的目标写成已验证。
- 不写逐行翻译式注释（"创建对象""返回结果"），不给 import、普通属性、显而易见的链式调用加注释。
- AI 的改动背景写在提交信息、计划、门报告或本规范里；代码内只保留后续维护必须知道的信息。
- 注释随代码同步更新；发现注释与实现不一致时优先修正或删除注释。
- 不用注释保留废弃或调试代码；历史交给 Git，成块注释掉的实现直接删除。
- 注释必须保持文件排版一致：缩进、空行、行宽、段落结构不因补说明而破坏。

## 2. Swift 文档注释（`///`）

public 类型、协议、跨 target 使用的类型、策略与执行器组件、动作、传输绑定、CLI 子命令类型应使用 `///` 文档注释（DocC 标记）。

类型注释应说明：

- 它在系统中的职责与所在边界（协议 / 策略 / 适配器 / 传输 / 守护进程）。
- 关键约束：是否会改变客户端状态、是否经策略、是否是不可逆点、是否依赖 AX 或网络、线程 / 队列假设。
- 修改它时要同步关注的上下游（例如改 `RPCMethod` 要改 `toolDescriptors` 与契约文档）。

方法注释应说明：

- 业务契约与副作用：会不会选行、设值、投递回车、写库、发事件、发布 MQTT。
- 容易误用的参数语义：`target` 是 wire 目标（标题 / `chatId:` / `externalUserId:`），`limit` 是尾部行数，`scrollback` 会滚动客户端。
- 返回值语义，尤其是 `unknown`、`nil`、空数组、`origin`、`direction` 这类"合法的不确定"。
- 抛出的 `ControlError` / `PolicyError` / `ActionError` 及其 wire 码；`throws` 但从不抛的方法不写异常。
- 不写与方法名重复的内容；`- Parameter` / `- Returns` 只在补充业务语义时使用。

示例（既有风格）：

```swift
/// Hard send-rate cap enforced by the executor, beneath any consumer policy:
/// one attempt per target every `perTargetMinIntervalMs` and at most
/// `globalLimit` attempts per sliding `windowMs`. Attempts count, not
/// successes, so a failing loop cannot hammer the client.
public final class RateLimiter { … }
```

## 3. Swift 实现注释（`//`）

只在局部逻辑确实不直观时使用，放在相关代码块上方：

- AX 怪癖与实测依据（表格 frame `y < 0`、`AXScrollUpByPage` 列出但拒绝执行、无发送按钮）。
- 安全边界：为什么先落 checkpoint、为什么 `unknown` 不重跑、为什么 Response Topic 只接受子树。
- 看似多余但不能删的兼容逻辑（例如 JSON `0/1` 必须保持数字）。
- 空 `catch`、`try?`、`continue`、fallback 为什么安全。
- `TODO` 必须带上下文与处理方向；不写没有主人的 `FIXME`。

`// MARK: -` 按"公共 API / 管线 / 辅助"分段；不用 MARK 代替拆文件。

不适合写实现注释：import、属性注入、普通 guard、与代码一一对应的行尾注释、为了"有注释"而堆砌。

## 4. 测试注释

测试用命名表达场景（`sendToNonAllowlistedTargetIsRefusedBeforeAnyAX`），注释只说明覆盖的风险场景与为什么这样断言：

- 崩溃注入后 `unknown` 且不重跑。
- 同幂等键不重发。
- 策略拒绝前不得有任何 AX set / action。
- 历史前插不是新消息。
- live 测试注明前置条件（客户端版本、授权、窗口所在 Space）。

夹具助手（`GroupFixture` 等）注明几何来自哪个版本的录制、哪些字段是合成的。

## 5. Shell 脚本

- 顶部块注释：用途、用法、环境变量覆盖、安全边界（例如为什么 warning-only、为什么不打印 secret 值、为什么复制到稳定目录）。
- 关键步骤上方一行说明"为什么"，不解释普通命令。
- 不在注释里写本机路径、broker 地址、证书序列号。

## 6. Markdown 文档

- 规范文档：规则写成可见正文，不用 HTML 注释藏规则。
- 门报告是证据：写条件（客户端版本、Space、授权、传输）、动作条数与内容、数字、结论与未闭环；不把"机制成立"写成"效果已验"。
- 规格与计划：规格写"口径"，计划写任务与代码；两者都不冒充实测。
- 脱敏：文档中的会话标题只允许 `文件传输助手`、合成夹具名或 `«hash»` 占位符。

## 7. JSON 夹具与 plist

- JSON 不支持注释：夹具的来源、版本、录制时间、脱敏方式写在文件名（`wecom-<版本>-<视图>.json`）、`Tests/WeComAdapterTests/FixtureLoading.swift` 的注释和门报告里。
- 手工修改夹具必须在提交信息说明改了哪些节点与原因；不改真实录制夹具去"凑测试"，需要时新建合成夹具。
- LaunchAgent plist 由 `LaunchAgentSpec` 渲染，不手写；键的含义写在 `LaunchAgent.swift` 的注释与 `docs/ops/launchagent.md`。

## 8. Java / YAML（代理与消费方，规划）

- Java 遵循 Google Java Style Javadoc：public 类、回调处理器、token 缓存、路径白名单、MQTT 发布器写类级 Javadoc，说明安全边界（不落正文、不持业务语义、失败关闭）。
- `application.yml` 只解释环境差异与误改风险，不写任何真实参数；密钥占位符形如 `${WECOM_CORP_SECRET}`。
- 历史模板来自同级仓库 `quantitative-trading-ai/docs/ai-coding/AI_COMMENT_STYLE_GUIDE.md` 的 Java / YAML / Shell 节；公开贡献以本文件已有规则及子项目 README 为准，不需要访问该仓库。
- GitHub Actions YAML 写清触发、权限、非活体开关与每个 job 的用途；外部 PR 不接触 secrets，不使用 `pull_request_target` 执行贡献代码。第三方 action 固定到核对过的官方提交，注释标明版本。

## 9. 项目当前文件类型规范索引

| 文件类型 | 项目内示例 | 规范来源 | 本项目落地规则 |
|---|---|---|---|
| Swift 源码 | `Sources/**/*.swift` | Swift API Design Guidelines、Swift-DocC 标记 | public 类型 / 方法用 `///`；实现注释只写"为什么"；客户端事实带日期与版本；口径与实测分开 |
| Swift 测试 | `Tests/**/*.swift` | swift-testing 文档 | 命名表达场景；注释说明风险与前置条件；live 门控写明 |
| Shell | `scripts/*.sh` | Google Shell Style Guide | 顶部说明用途 / 用法 / 安全边界；不写本机路径与凭据 |
| Markdown | `docs/**/*.md`、`README.md`、`AGENTS.md` | CommonMark、本仓库文档流 | 规则可见；门报告写条件与证据；脱敏 |
| JSON 夹具 | `Tests/Fixtures/ax-trees/*.json` | JSON（无注释） | 来源写在文件名 / 加载器注释 / 门报告；不手改录制夹具凑测试 |
| plist | `LaunchAgentSpec` 渲染 | Apple launchd.plist 手册 | 不手写；键含义在代码注释与 ops 文档 |
| Java / YAML | `proxy/`、`examples/`（规划） | Google Java Style、Spring Boot 配置文档 | 采用本文件 Java / YAML 规则；密钥只占位 |
| GitHub Actions YAML | `.github/workflows/ci.yml` | [GitHub 工作流语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax) | 最小只读权限、普通 PR、关闭 live、无 secrets；扫描只报位置，不打印命中值 |

## 10. 注释检查清单

提交前逐条问：

- 这条注释解释的是代码看不出的"为什么"吗？
- 写的是实测事实吗？有日期与客户端版本吗？还是设计口径？标清楚了吗？
- 半年后、客户端升级后它还有价值吗？会不会误导？
- 删掉它，维护者会不会误改安全边界（策略、checkpoint、合成输入、Response Topic）？
- 有没有泄露 broker 地址、凭据、真实联系人标题或正文？
- 它与当前代码行为一致吗？排版与文件风格一致吗？

任一答案不满足，删除或重写。

## 11. 参考依据

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)：命名与文档注释的基本要求。
- [Swift-DocC 标记](https://www.swift.org/documentation/docc/writing-symbol-documentation-in-your-source-files)：`///` 摘要、讨论、`- Parameter` / `- Returns` / `- Throws` 的用法。
- [swift-testing](https://developer.apple.com/documentation/testing)：`@Suite` / `@Test` / `#expect` / `#require` 的组织方式。
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)。
- [CommonMark](https://spec.commonmark.org/current/)。
- [Google Java Style Guide - Javadoc](https://google.github.io/styleguide/javaguide.html#s7-javadoc)（代理与消费方）。
- Robert C. Martin《Clean Code》第 4 章：注释是"必要的恶"，被注释掉的代码直接删除。
