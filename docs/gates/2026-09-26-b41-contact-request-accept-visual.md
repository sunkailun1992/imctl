# B41 联系人申请提交前视觉复核 — 源码和 fake 通过，活体待验

## 本批实现

显式 `contact.request.accept` 可在唯一待处理卡片「接受」及本命令新备注弹层「完成」前各截取一次同一企微主窗供所选模型只读复核。两次按键仍各由固定 AX 与原 checkpoint 执行；模型只可 `verify/reobserve/stop`。每轮前后和按键前核对同窗/PID、同卡片和按钮、选中的「新的客户」页、策略/暂停、屏幕录制及视觉设置。独立弹窗、多个完成按钮或非备注弹层失败关闭。首个按键后失败保留 checkpoint，由执行器归 `unknown`；未执行真实接受。

## 假数据验证

- `swift build -q`：通过。
- `swift test -q --filter B41ContactAcceptVisualTests`：6/6 通过。合成卡片成功例为两次截图/模型复核、两次 checkpoint、两次 AXPress 和卡片 `added` 后验；失败例覆盖首轮/次轮停止、越权输出、权限/策略/窗口/卡片变化、非备注/多个弹层及自动/视觉关闭的零模型路径。
- 最终主树全套测试和安装版结果由总门报告另记。本隔离 worktree 的 fake 结果不能当作真实千问/MQTT 活体验收。

## 未验

真实自有待处理申请当前未提供；未触发接受、未向云端上传真实申请画面，也没有本方法的 MQTT 成功终态。专项活体应核对两帧计数、两个 checkpoint、客户端卡片状态、`contact.request.accepted` 和同键回放；不能把只读申请列表或旧版 AX 接受当作 B41 视觉证明。
