# B15：可见媒体行方向与屏幕录制授权门报告（2026-09-24）

## 条件与范围

- 用户批准：方向未知的图片可按需截取企微窗口单帧，在内存中判断左右，不保存；屏幕录制权限须出现在「授权与本机」并用于本机安装。
- 既有 AX 定点与增强模式核对：私聊图片行只有时间标签，行 / 单元格横跨消息区；没有可用于判左右的同一行 AX 锚点。本批不发送消息、不更改策略或凭据。
- 规格与计划：`docs/superpowers/specs/2026-09-24-b15-visible-media-direction.md`、`docs/superpowers/plans/2026-09-24-b15-visible-media-direction.md`。

## 实现

- AX 已能判断的文本、文件、视频继续走原路径。显式历史只针对本次返回、可见且方向未知的无文本媒体候选调用一次视觉解析；观察者仅在同一会话新增行即将产生事件时调用。截图由 ScreenCaptureKit 只截匹配 PID 与 AX 几何的企微窗口，不保存、不上传，超时或不确定回 `unknown`。
- 纯像素分类器以消息视口和行坐标定位，只有单侧足够大的连通区域才判断左右；双侧、居中、空白、头像、离屏或裁切不足一律保留 `unknown`。既有 `direction` / `origin` 同步到 socket / MQTT，不新增图片字节字段。
- `controller.permissions` 加守护进程视角的 `screenRecording` 与显式提示；`imctl setup --check` 六项，控制台「授权与本机」显示状态及系统设置入口。守卫测试把屏幕录制 API 限制在授权处理器和单帧截图文件。

## 验证

| 项目 | 结果 |
|---|---|
| `swift build --quiet` | 通过 |
| `swift test --quiet` | 558 项、9 个测试目标通过；新增 7 个合成图分类测试及历史 / 观察事件的 fake AX 覆盖，含空会话首条媒体与历史前插，live 套件默认跳过 |
| `git diff --check`、`bash scripts/check-secrets.sh` | 通过；无新增敏感内容告警 |
| 本机 1.0.4 包 / 签名 / 安装 / TCC 读回 | 最终 release build 155 由已提交源码重出并安装；独立 app 签名通过，`setup --check` 六项均通过（含屏幕录制）；pkg SHA-256 `d3d42a3d3dac00413d7d3cdf30d22ebaa6e0ab3e0bda55ea9284d3ebb81ff52d` |
| 真实企微只读方向 / 时延 | build 153 授权后首次历史读取触发 `CGS_REQUIRE_INIT` 崩溃；Core Graphics 显示初始化消除崩溃。旧截图 API 随后在 macOS 27.0 返回 `SCStreamErrorDomain:-3811`，专用单帧 API 修复。最终 build 155 对同一私聊 5 行中的 2 条可见左侧图片均返回 `inbound`：socket `message.history(limit=30)` 约 0.31 秒，MQTT 同一方法约 0.51 秒，返回一致；LaunchAgent 持续运行，最近 4 分钟无新的 `imctld` 崩溃报告；发送 0 条 |
| 第二台 Mac | 安装脚本和说明已随包更新；目标机安装与授权待目标机执行 |

## 边界

屏幕录制授权由 macOS 与人决定，代码不会修改 TCC 数据库；未授予时普通 AX 读取继续可用，媒体行仍可能为 `unknown`。旧 `message.observed` 事件不会静默改写；有需要时由消费方显式读当前历史。新媒体 `message.observed` 的方向仅有 fake AX / 单测覆盖，本轮没有新收到的真实媒体事件。macOS 15–25 的旧截图 API 分支已编译，未在旧系统实测。截图无法恢复本机缺失的企微附件缓存，也不改变媒体按需取 URL 的模式。
