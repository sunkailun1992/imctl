# B22：只读 AXRole / AXFrame 瞬态读取收敛

## 背景与范围

B20 只读 MQTT 验收中，`message.history{limit:1}` 间歇返回 `CLIENT_UNAVAILABLE`，对应 AX `get AXRole` 的 `-25201`；watcher 也见过 `get AXFrame` 的同类瞬态。`AXElement.value()` 已对 `get AXValue` 的一次 `-25201` 做即时重读。本批仅把相同的窄恢复行为加到 `AXElement.role()` 与 `AXElement.frame()` 的只读属性访问，不重做整条命令、不滚动消息区，也不碰任何 AX set / action。

## 行为契约

- `role()` 仅在第一次 `get AXRole` 抛出 `apiFailure(-25201, "get AXRole")` 时即时重读同一属性一次。
- `frame()` 对 `AXFrame`，以及现有回退路径中的 `AXPosition`、`AXSize`，分别只在第一次读取该属性返回**对应操作名**的 `-25201` 时重读该属性一次。其它属性的读取次数与回退顺序保持原样。
- 第二次失败原样向调用方传播；其它错误码、其它操作名和 unsupported 不触发重读。`AXFrame` 不支持时继续使用 `AXPosition` + `AXSize`，其它 unsupported 仍按既有可选结果处理。
- 不扩展 `AXElement.string()`、原始 `attribute(_:)` 或全局 backend 的重试范围；已有 `AXValue` 逻辑保持原样。没有协议、策略、权限、传输、截图、按键或运行数据格式变化。

## 证据边界

Fake backend 测试覆盖一次失败后成功、持续失败、其它错误和 unsupported / frame 回退。真实 MQTT 稳定性由主智能体在安装新构建后另做只读验证；本批 fake 成功不能证明 `message.history` 的所有失败源已消除。发送数为 0。
