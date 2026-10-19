# B22：只读 AXRole / AXFrame 瞬态读取实施计划

规格见 `docs/superpowers/specs/2026-09-25-b22-transient-ax-role-frame-reads.md`。

## 全局约束

仅改 `AXElement` 的 `role()` / `frame()` 只读调用和 AXKit fake 测试。不改 `AXBackend` 协议、Live / Fake 实现、`AXValue`、WeCom 处理器 / 滚动、策略、执行器、传输、运行数据或客户端动作。一个属性最多增加一次即时读取；无 sleep、无整命令重试。没有发送或其它客户端写入。

## Task 1：先写 fake 回归

1. 用 `FakeAXBackend.onRead` 对 `AXRole`、`AXFrame` 脚本化第一次 `-25201`、第二次成功，并断言每个属性恰好读 2 次、无 AX set / action。
2. 覆盖 `AXFrame` 不支持时 `AXPosition` / `AXSize` 各自的单次瞬态及 fallback 结果。
3. 覆盖连续 `-25201`、其它错误码 / 不匹配操作名只读一次并原样抛出；unsupported 保持 nil 或原 fallback。

## Task 2：窄实现

在 `AXElement` 内封装私有的单属性 read helper：只捕捉 `apiFailure` 且 code、operation 都与所读属性精确匹配，随后调用原 `attributeIfSupported` 一次。`role()` 从返回值取 string，`frame()` 逐属性使用 helper；`value()` 保留既有实现。

## Task 3：验证与交接

先跑聚焦测试，再跑 `swift build` 与一次全量 `swift test`，检查 `git diff --check` 和 `scripts/check-secrets.sh` 新增命中。主智能体负责 cherry-pick 后的真实客户端只读 MQTT 验证、门报告、安装包及 wiki 归档；真实验证前不宣称间歇错误已完全解决。
