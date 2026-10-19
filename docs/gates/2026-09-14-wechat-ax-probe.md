# 个人微信（WeChat for Mac 4.1.13）AX 可读性探针（2026-09-14 00:1x–00:2x CST）— 不可行

用户 2026-09-14 00:15 决定"完成个人微信控制"。按阶段 0 的方法先做只读探针：个人微信客户端是否向 Accessibility 暴露会话表 / 消息区 / 输入框。**结论：WeChat 4.1.13 没有向 AX 暴露任何内容，纯 AX 路线无法控制它。**

## 条件

- `/Applications/WeChat.app`，bundle `com.tencent.xinWeChat`，版本 **4.1.13**（build 269631），已登录、正在运行（窗口起初关闭，`open -b` 后打开并置前，1728×1084）。
- 探针进程 `imctl`（辅助功能 trusted），只读 `dump-tree`；零动作、零发送。

## 观察

| 步骤 | 结果 |
|---|---|
| `dump-tree --bundle com.tencent.xinWeChat --root main-window --summary` | 5 个节点：`AXWindow`（`AXStandardWindow`，`微信`）+ 3 个交通灯 `AXButton` + 全屏按钮下的空 `AXGroup`；**没有 AXTable / AXRow / AXStaticText / AXTextArea** |
| 设置应用元素 `AXEnhancedUserInterface = true`（辅助客户端提示，经 System Events） | 成功；再 dump 主窗口只剩 `AXWindow` 1 个节点 |
| 设置 `AXManualAccessibility = true`（Chromium 系提示） | 不支持（-10006），说明不是 Chromium/Electron 壳 |
| `--root app --depth 3` | `AXApplication` + 1 个 `AXWindow` + 菜单栏（8 个 `AXMenuBarItem`），窗口无内容子树 |

对照：企微 5.0.11 同一探针得到 1000+ 节点（会话表、消息表、输入框全部可读可写）。

## 结论

- WeChat 4.x（自研跨平台 UI）把整个内容区当一块画布绘制，不构建辅助功能树；`AXEnhancedUserInterface` 也不触发。imctl 的硬边界是"权限面只有辅助功能、不录屏、不发合成事件"，因此**在当前客户端上个人微信控制不可实现**，不建 `WeChatAdapter`。
- 可选路线（都需要用户决定，均不在本次范围）：① 微信 3.8.x（最后一代 AppKit 原生客户端，AX 完整）——需确认腾讯是否仍允许旧版登录及强制升级风险；② 放弃个人微信，只做企微；③ Android 微信经 UIAutomator（另一平台的适配器，不是 macOS 控制器）；④ 截屏 + OCR + 合成点击——违反硬边界，不采纳。
- 本次对微信只做了读取；`AXEnhancedUserInterface` 提示对微信无副作用，客户端重启即失效。
