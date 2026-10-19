# B16：云端视觉辅助 AX 控件定位门报告

## 范围与决定

- 用户 2026-09-24 允许显式操作在 AX 无法辨认控件时上传**候选按钮内部像素**给外部视觉 API；默认千问，支持切换 Gemini / DeepSeek 与替换各自密钥。用户提供的本机配置已一次性导入：千问和 Gemini 密钥仅在本机 `vision/cloud-vision.json`，DeepSeek 未配置。仓库、安装包和本页不存密钥。
- B16 首个入口仅是 `group.addMembers` / `imctl probe addmembers` 的群标题栏按钮。常规 MQTT 读取 / 观察、控制台会话和 B15 本机媒体方向不请求视觉 API。显式命令仍经 `ActionPolicy`、AX 句柄、窗口 / 会话复核及原有命令执行器；模型仅返回候选 ID，不生成坐标或发送内容。
- 当前企微 5.0.11 的目标按钮在 `AXHelp` 或 `AXValue` 已提供准确的「添加群成员」名称。最终实机路径优先使用该名称，**未上传图片**；只在名称缺失且右侧标题栏有多个候选时尝试模型。

## 验证结果

| 检查 | 证据与结果 |
|---|---|
| 配置与密钥 | 用户指出模型过旧后，按[阿里云视觉模型表](https://help.aliyun.com/zh/model-studio/vision-model)把默认千问改为 `qwen3.7-plus`，可选 `qwen3.8-flash` / `qwen3.8-max`，保留两个 Qwen3-VL 型号兼容旧配置；Gemini 可选 `gemini-3.8-flash` / `gemini-3.7-flash`；DeepSeek `deepseek-flash`。各家密钥独立保存、替换和删除，目录 0700、文件 0600，CLI 只从标准输入接收密钥，状态只报告有无。控制台「设置 → 视觉识别」可管理。 |
| 裁图边界 | 只在策略授权、会话 / PID / 窗口确认后，对右侧标题栏两个至八个候选分别取 AX 框**内部**像素，黑底拼图；不含按钮间隙、群名、头像或消息区。合成图测试解码 JPEG 后确认左侧敏感色像素数为 0；截图不落盘。 |
| 网络边界 | 固定官方 HTTPS/443 主机；内联 JPEG ≤ 1 MB、宽高 ≤ 1024，响应 ≤ 16 KB；无 URL 输入、重定向、cookie、磁盘缓存、自动重试或跨供应商转发。单次请求上限 8 秒，错误不回显服务端正文。 |
| AX / 策略 | AX 唯一名称优先且不调用模型；模型返回只能是现有候选之一；无把握、HTTP 错、超时、候选帧超范围或界面变化一律在 AXPress 前停止。合成 AX 测试覆盖无把握零按压、伪造候选零按压、准确 AXHelp 零云端调用。 |
| 官方 API 合成图 | 千问北京地域端点使用现有本机密钥的**合成图片**请求返回 HTTP 200；随后 `qwen3.7-plus` 对公开应用图标 JPEG 的 JSON 请求也返回 HTTP 200、`finish_reason=stop` 且 JSON 选择字段可解析。Gemini Developer API 在本机返回 HTTP 400 `FAILED_PRECONDITION`，归因为服务地区限制，不能称可用；DeepSeek 未配置密钥，未发真实请求。三家请求形状由假传输单测覆盖。 |
| 测试群活体 | `imctl probe addmembers --target imctl测试群`：策略允许、AX 名称命中、面板出现，读到 1 个脱敏行，确认按钮不可用，取消后面板关闭。最后一次运行约 4.00 秒，发送 0 条、选中成员 0 个、模型请求 0 次。开发期早期探针在同一测试群曾因模型拒判 / 超时而停在 AXPress 前；不把它们算作最终成功。 |
| 常规读与 B15 | 代码调用图显示云端 selector 仅装在 addMembers 显式动作；`conversation.read`、`message.history`、MQTT 观察与媒体方向沿既有路径。 |
| 构建 / 测试 / 包 | B16 完整测试曾全 9 个 target、575 项通过（包括 AX、裁图和 Forbidden API 守卫）。最后一次 Gemini 输出预算调整后，两次全量复跑分别遇到既有 OSS / FileFetcher 超时取消断言的偶发失败，两项各自单独复跑通过，因此不把复跑写成全绿。更换千问默认型号后，视觉模型及命令 12 项、控制台模型 25 项通过；`git diff --check` 通过；`check-secrets.sh` 退出 0，11 条旧模板 / 示例告警，没有新增命中；已配置的两个密钥在本批变更文件中命中 0 次。1.0.5 build 156 的 `out/imctl.app` 完成签名校验，开发用未签名 pkg 的 payload 含 CLI、控制台及守护进程；`installer -target CurrentUserHomeDirectory` 成功覆盖唯一安装位置。 |
| 本机安装读回 | `~/Applications/imctl.app` 为 1.0.5 build 156，签名校验通过；LaunchAgent 重启后 active / exit 0，六项 `setup --check` 全通过；云端状态为已启用、千问 `qwen3.7-plus`，千问和 Gemini 密钥存在、DeepSeek 缺失。控制台已重新打开，未进行真实云端后备调用。 |
| 第二台 Mac | 未安装、未授权、未配置密钥；本机安装包不包含密钥。 |

## 尚未闭环

- 当前企微的 AX 名称使本机无法在不人为屏蔽该名称的前提下走到云端后备路径；**云端截图 → 模型选择 → AXPress 的实机端到端尚无成功证据**。该路径只由裁图、协议与 Fake AX 测试覆盖。后续若企微版本出现无名称候选，应先在用户测试群用只读探针验证再扩大到其它控件。
- 千问端点固定北京地域，其他地域密钥未核对；Gemini 本机地区限制未解决，不自动改用 Vertex。DeepSeek 需独立密钥与活体验证。
- API 提供商可能保留已收到的裁图；本机关闭开关不能撤销此前传输。第二台 Mac 须独立完成授权、设置与验收。
