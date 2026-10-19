# B42 `contact.add` 搜索与邀请前视觉阶段门报告 — 源码和 fake 通过，活体待验

## 范围

仅显式 `contact.add`；不改 MQTT 方法参数、白名单、策略、按键集合、执行器、checkpoint 或后验。命令不再接管预先打开的搜索窗。搜索框、来源唯一匹配与邀请确认之前的模型观察仅有 `verify/reobserve/stop`；号码、来源、问候和提交仍由本地固定命令决定。

## 工程证据

- `swift build` 通过。
- `swift test --filter 'AIPlannerAddCustomerHeaderIntegrationTests|AddContactTests'`：25/25 通过。包含预开真实形态搜索窗零截图 / 零点击、模型在搜索 / 结果 / 邀请阶段停止后不继续执行、正常 dryRun 两个被动观察及原 B12 动作夹具。
- 本批没有启动真实客户端、发送邀请或做云端截图；`dryRun` 测试没有结果按钮 / 邀请按钮按压。

## 活体边界

5.0.11 脱敏 AX 夹具的添加客户第二窗口与主窗均约 1920×1200，位置仅相差约 30 点。当前 `WeComScreenCapture.bestWindow` 要求按 PID 与窗口几何**唯一**匹配；若 ScreenCaptureKit 同时枚举两窗，捕获会失败关闭。AX 窗口没有本项目可审计的公开 CGWindowID 映射，不能只凭相近标题或层级猜选另一窗口。真实 B42 Qwen 调用、MQTT 终态与自有测试手机号邀请均待主任务单独验收。
