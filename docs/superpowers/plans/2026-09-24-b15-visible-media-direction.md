# B15 实施计划：可见媒体行方向

1. 用独立 `WeComScreenCapture` 按守护进程身份预检 TCC、匹配企微 PID 与当前 AX 窗口，只截一帧，设置统一超时。截图在调用栈结束时释放。
2. 用纯 `ScreenshotDirectionInference` 读取行内像素；基于窗口、消息视口和行的全局坐标换算，要求单侧足够大的连通区域，双侧 / 居中 / 离屏回 `unknown`。用合成图测试。
3. 显式历史读取仅对本次返回的未知媒体行调用一次解析器；观察者仅对同会话的新追加行补证据，再生成事件。fake AX 测试检验调用范围及 MQTT `direction` / `origin`。
4. 扩展守护进程 `controller.permissions`、`imctl setup`、控制台「授权与本机」，加入状态、系统提示和设置入口；安装包随包说明同步。屏幕录制检查属于守护进程，不以终端或控制台进程状态代替。
5. 调整仓库安全规范和 `ForbiddenAPITests` 精确例外；同步协议 / 运维文档；`swift build`、`swift test`、`check-secrets`、只读活体、门报告、提交推送。

## 回退与边界

移除视觉解析接线即可恢复 AX-only 的 `unknown`，不迁移数据。授权由 macOS 管理，应用不能替用户写 TCC；撤销屏幕录制后仍可读普通消息，媒体方向按原有 AX 证据或 `unknown` 返回。
