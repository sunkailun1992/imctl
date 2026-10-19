# B29 实现与验证计划

1. 在 `applyGroupName` 的首次 AXValue 写前检查当前字段和目标；`group.rename` 将原选中行作为写入期间的目标锚点，`group.create` 保留已有新群流程。
2. 写值后只认同一字段读回的请求值；仅原值可做一次相同值重写，任一其它值或选中行变化立即失败关闭。确认前才调用 checkpoint，随后仅一次 `AXConfirm`。
3. Fake AX 测试覆盖一次写值丢失后修复、两次丢失后零 checkpoint / confirm、选中行漂移后不修复、`group.create` helper 回归、无选中行但其它行恰好同名不可作为改名成功，以及确认后仅回显时不再次确认。
4. 运行相关与全量 Swift 测试、`swift build`、diff 检查、secret 扫描；门报告分别列源代码、fake 与活体边界。不得做真实改名 / 创建 / 发送。
