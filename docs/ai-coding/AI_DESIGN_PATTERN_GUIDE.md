# AI 设计模式规范

本规范约束 AI 在 `imctl` 中选择、引入和调整设计模式的方式。目标是让代码结构贴合"控制真实客户端、不可逆动作、事件即真相"的安全边界，而不是为了展示模式而增加抽象。

## 1. 总原则

- 先理解当前语言、框架和项目结构，再选模式；本项目默认按 Swift 5 语言模式、值类型优先、协议 + 具体实现、闭包注入的方式落地。
- 优先沿用项目已有模式；只有当新模式能降低真实复杂度、隔离风险或稳定扩展点时才引入。
- 模式是"引入"出来的：出现真实坏味道（重复实现、按类型膨胀的 `switch`、状态判断散落多处、测试无法隔离真实客户端）时通过小步重构引入；没有坏味道保持简单。
- 模式必须服务边界：AX 与企微隔离、策略与动作隔离、不可逆点与证据、传输与协议隔离、守护进程与纯逻辑隔离。
- 不允许为简单逻辑硬套模式；一个私有方法能表达清楚时，不新增 Manager、Helper、Factory、Service、Abstract 层。
- 不允许用模式绕过策略层、幂等键、checkpoint、`ForbiddenAPITests` 或 Response Topic 守卫。
- 新增抽象必须配套命名、测试与文档，让维护者一眼看出扩展点与禁止绕过的路径。

## 2. 标准参考

- GoF 设计模式与 SOLID：命名与职责判断的基础词汇。
- Hexagonal / Ports & Adapters：`AXBackend`、`CommandHandler`、`MQTTLink`、`IdentityLookup` 是端口，Live / Fake / 具体绑定是适配器。
- Martin Fowler《Refactoring》：由坏味道驱动的小步引入。
- Swift 生态惯例：协议 + 默认实现、值类型、`enum` 状态机、闭包注入替代重型 DI 容器、`final class` 只用于需要引用语义的持有者。

这些是模式语言，不是模板；最终以最小可用设计为准。

## 3. AI 执行流程

1. 识别改动涉及的 target、边界与风险等级。
2. 查找项目内同类模式与命名（第 4 节表）；同一职责不引入第二套。
3. 判断变更是协议、策略、适配器解析、动作、观察、传输还是运维接口。
4. 复用已有端口与注入点；不能绕过 `ActionPolicy` / `CommandExecutor`。
5. 只有出现两个以上实现、稳定扩展点、重复流程或清晰状态机时才引入新模式。
6. 测试覆盖模式的选择、分发、降级、异常路径与安全边界（fake 上测，live 只验证前置假设）。
7. 交付说明写清采用了什么模式、解决了什么问题、没有采用哪些更重的方案。

## 4. 本项目既有模式

| 模式 | 落地 | 规则 |
|---|---|---|
| 端口 + Live / Fake 适配器 | `AXBackend` ← `LiveAXBackend`（唯一接触 `AXUIElement`）/ `FakeAXBackend`（记录 set / action、可注入失败、可模拟客户端变化） | 新的 AX 能力先加到 `AXBackend` 协议并给 Fake 实现；解析与动作只依赖 `AXElement`，不依赖 Live |
| 策略对象（fail-closed） | `ActionPolicy`（阶段 → 启用 → 目标 → 允许）、`SendPolicy`（文件只能放宽）、`RateLimiter` | 所有改变客户端状态的原语先 `authorize`；默认拒绝；`unknown` 类型不可被类型规则放行；策略在代码里，文件只是输入 |
| 命令管线 / 状态机 | `CommandExecutor`（串行队列；`CommandStateV1` 终态判定；checkpoint 与 `unknown`） | 新方法加 `execute` 分支而不是绕过执行器；状态迁移只经 `transition`，每次迁移一条事件 |
| Repository | `ControlStore`（GRDB：命令 / 事件 / 暂停 / kv / 身份桥；`idempotency_key` UNIQUE 由数据库判重） | 查询放 store，业务规则不放 SQL；迁移只追加 |
| 命令处理器（端口） | `CommandHandler` ← `WeComCommandHandler` / 测试 `FakeHandler` | 平台差异全部在处理器与适配器内；执行器与传输不知道企微 |
| 目标解析 | `TargetRef` → `TargetResolver`（身份桥 + 客户端证据）→ `ResolvedTarget` → 策略 | 客户端证据优先于桥的类型；解析只读，不改客户端 |
| Strategy | `SubmitStrategy`（enter / ctrl-enter / send-button / context-menu / ax-confirm / newline） | 策略枚举 + `switch`；不为每种策略建类；新策略先在 `probe submit` 上取证 |
| 快照 + diff | `WatchSnapshot` / `WatchDiff`（尾对齐识别前插；切换后抑制历史爆发） | 观察语义放 diff，不放守护进程；新增字段先进快照 |
| 引擎 + 驱动分离 | `WatchEngine`（纯逻辑：定位 / 快照 / diff / 归因 / 重定位）+ `DaemonWatcher`（定时器、通知去抖、落库、状态文件） | 纯逻辑可在 fake 上测；守护进程只做 I/O 与调度 |
| 分类器 | `OriginClassifier`（一次发送只消费一次） | 归因规则集中；`unknown` 是合法结果 |
| 传输绑定 | `RPCDispatcher`（JSON-RPC / MCP）、`MQTTBinding`（Response Topic 守卫、事件泵游标）、`UnixSocketServer` / `StdioServer` | 绑定只做信封、编码、守卫；语义在执行器；查询（`event.replay`）不建命令 |
| 闭包注入 | `readerProvider`、`recentSends`、`identityLookup`、`postReturnKey`、`exitHook`、`sendPolicyProvider`、`configureActions` | 用闭包替代 DI 容器；测试用它们注入 fake、时钟、崩溃点；生产装配集中在 `main.swift` |
| 规格对象 + 渲染 | `LaunchAgentSpec.plistXML()`、`MQTTSettings`、`SendPolicy` | 配置先建模再序列化；文件权限在 `save` 里保证 |

## 5. 反模式（禁止）

- 在 CLI、守护进程或传输层直接调用 AX / 适配器发送，绕过 `CommandExecutor` 与 `ActionPolicy`。
- 单例与全局可变状态（唯一例外 `DaemonRuntime.shared` 用于信号处理；不新增）。
- 为策略、动作或传输各建一层 Manager / Service / Coordinator 包装。
- 用继承表达平台差异（企微 / 未来其它适配器）；用协议 + 独立 target。
- 在 `switch` 之外用字符串比较判断 `ActionKind` / `RPCMethod` / `CommandStateV1`。
- 在解析层用固定坐标、`_NS:*` 标识符或同名标题代替角色 + 几何 + 复核。
- 强解包 `!`、`unsafeBitCast`、`try!`（测试中的 `#require` 除外）。
- 为了"未来的微信适配器"预建抽象；4.1.13 无 AX 树，不存在的东西不抽象。

## 6. 扩展指引

- **新的客户端能力**：`AXBackend` 原语（若缺）→ `WeComLayout` / 解析 → `WeComActions` 动作（经策略）→ 处理器方法 → 执行器分支 → 工具描述与契约。
- **B16 视觉辅助定位**：AX 候选收集与裁图分开；云端请求放可注入的窄传输端口，Fake 只回候选 ID。动作层在策略通过、AX 唯一定位失败后才调用；返回后重读 AX 复核，再使用既有动作原语。提供商差异只在传输编码与固定官方端点，不让传输层决定操作或扩大截图范围。
- **新的策略维度**：加进 `SendPolicy` + `ResolvedTarget` + `ActionPolicy.allows`，并给 `imctl policy` 加旗标；不新建第二套策略对象。
- **新的传输**：实现新的绑定类，复用 `RPCDispatcher`；事件发布必须按 `event_id` 顺序且持久化游标。
- **`WeComAPI`（规划）**：`WeComAPIClient` 协议 + `URLSession` 实现 + `URLProtocol` 伪代理测试；请求签名 / token 由代理注入，客户端只带 Bearer；身份桥写入 `ControlStore.upsertIdentity`。
- **Java 代理 / 消费方（规划）**：采用本文件的 Strategy / Adapter / Provider / Repository 边界与各子项目现有结构；历史模板来自同级 Java 仓库，但外部贡献者不需要访问；与 imctl 的边界只在 topic 与 JSON-RPC 信封。
