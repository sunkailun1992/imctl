# B41 实施计划

1. 在 `WeComActions.contactRequestAccept` 的两个固定 `AXPress` 前插入可选只读观察和按键即时门；不改动作选择、checkpoint 或执行器。
2. `AIPlannerReversibleRunner` 新增仅 `.contactRequestAccept` 可用的按钮观察入口；候选只一枚 `AXButton`，模型输出只允许 `verify/reobserve/stop`，配置跨两轮冻结。
3. 处理器锁定同主窗、同卡片、同按钮、备注弹层的来源及本机授权；每次截图前后和两次 checkpoint 后立即复核。
4. 合成 AX/截图/模型测试覆盖成功、模型停止/越权、授权或身份漂移、非备注或多弹层、AX-only/自动轮次；更新对外协议和门报告。真实联系人申请仅在可核对的自有测试申请出现并获得专项授权后验收。
