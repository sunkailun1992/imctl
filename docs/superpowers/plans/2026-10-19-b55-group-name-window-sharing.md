# B55 实施计划

依据 [规格](../specs/2026-10-19-b55-group-name-window-sharing.md)，不新增权限、按键、协议、配置或运行数据。

1. 先写 `B55GroupNameWindowSetTests`：精确分享指示器、平移、单窗；错误 PID / backend、角色 / subrole、title、子节点、大小、位置、遮挡和多个附窗；验证纯读没有 AX set / action。
2. 新增 `GroupNameWindowSet` 只读验证 helper；B37 原群名观察中调用，既有 window-rooted fake 保持兼容，app-rooted fake 使用真实窗口集合路径。
3. 验证 handler 在指示器共存时仍执行两次被动观察、原 checkpoint 和单确认，其他窗口仍在写值前拒绝。保留上一批提前生效、模型停止、策略撤回及幂等回归。
4. 完整非 live 测试、构建、敏感信息检查与独立审查。版本按公开 main 顺延到 `1.0.19-dev`；签名与配置格式不变。
5. 写门报告，提交和推送前同步上游，开公开 PR 待本人审核。仅按已授权的安装与 2 次实际改名范围验证；证据不足不重试或关闭守卫。
