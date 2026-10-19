# B16：显式操作的云端视觉控件定位

## 背景与用户决定

企微 5.0.11 的部分控件缺少可用的 AX 标题 / 描述。现有适配器先按 AX 角色、父子关系和窗口相对几何筛选，仍有 `RailBadges.contactsBadgeY`、`WeComContactsView.leftColumnWidth`、选人面板缩进及群标题栏未标注按钮等版本相关阈值。用户指出这类选取容易随界面变化失效，希望引入视觉模型动态识别。2026-09-24 用户随后决定可调用外部视觉 API，支持千问、Gemini、DeepSeek；千问是默认提供商，并从已有本机凭据一次性初始化。此前 B15 对媒体方向的截图许可只限本机判向、不上传，本批另行界定云端用途。

## 范围

- 初始试点是显式 `group.addMembers` 中打开「添加群成员」表单的群标题栏图标：AX 能给出多个未标注候选，但不能唯一辨认其语义。先保持候选元素的 AX 句柄、角色和框，再由视觉模型选择**候选 ID**；模型不提出任意点击坐标。后续扩到其它控件须逐个补规格、假数据与活体证据。
- 只在当前命令已经通过 `ActionPolicy.authorize`、企微 PID / 窗口 / 会话与目标已确认、AX 无法唯一定位该控件时尝试。普通会话 / 消息读取、`message.history`、`message.observed`、守护进程观察轮询和 B15 方向判断不走云端。经 MQTT 发来的显式操作也须先经过同样的策略检查；不暴露任意截图分析 RPC。
- 截取已核对的企微窗口**单帧**，在内存中只拼接候选 AX 按钮框内部像素，黑色填充其余区域；群名、聊天正文、头像和按钮之间的空隙不进入请求。裁图必须有动作专用的正向区域定义，限制像素与编码字节数；无法证实裁图范围安全时不请求模型。截图 / 裁图不落盘、不进日志、数据库、事件、MCP 或 MQTT。
- 本机独立启用开关及提供商 / 模型 / 密钥管理；系统的屏幕录制授权不自动打开云端上传。默认提供商千问，可在本机切换 Gemini / DeepSeek；每家密钥独立，替换或删除不回显。已有本机千问凭据只作一次性导入来源，先核对非秘密的地域信息，运行期不读取原应用文件。密钥不进代码、文档、日志、命令参数或安装包。
- 仅在请求体里内联一张裁图；不用公网图片 URL、供应商 Files API、跨提供商转发或后台重试。按提供商及地域选固定官方 HTTPS/443 主机与路径，禁止自定义 endpoint、IP、URL 用户信息、重定向和从消息 / 模型输出构造地址。请求有短超时、尺寸上限和频率上限；远端会收到裁图，其保存规则由远端服务决定，imctl 不宣称远端零留存。

## 操作与失败语义

1. 先读取右侧标题栏候选的 AXTitle、AXDescription、AXHelp 与 AXValue；后两者若有唯一且准确的「添加群成员」名称，就直接用该 AX 句柄，不截图。AX 候选仍歧义时，将同一企微窗口内的候选按钮裁图按顺序拼接，提示词用匿名 ID 标注各框，让模型只返回 `candidate_id`；返回必须是候选集合中唯一的一个。固定提示词不接受企微画面中的指令；不向模型开放工具调用。
2. 模型返回后重新读取企微 PID、窗口、活动会话、候选 AX 元素的角色、动作和几何；候选仍唯一且状态未变才用已有 AX 动作。`ActionPolicy`、`CommandExecutor`、checkpoint、幂等、速率与结果复核保持原控制权。没有 AX 可操作元素时不发送合成鼠标或额外按键。
3. 开关关闭、授权或密钥缺失、截取 / 裁剪失败、模型超时 / 429 / 5xx、响应不合法、多个候选、界面变动、AXPress 无法验证时停止视觉路径，不自动换提供商。若不可逆动作可能已经发生但证据不足，沿用 `unknown`，不重试。B16 路径启用后发生的候选歧义不能在模型失败时再猜原先的最右按钮。

## 可验证验收

1. Fake AX + 合成图：唯一 AX 目标零截图零请求；歧义时只裁标题栏按钮带，裁图外的合成敏感像素不出现在编码请求里；动作拒绝前零截图、零上传、零 AX 写。
2. 三家假传输分别检验官方端点、认证头、内联图、模型名单、请求尺寸 / 次数；恶意 URL、重定向、无密钥、坏密钥状态、切换与替换、429、超时、畸形输出均失败关闭；任何错误、日志、状态与 CLI 输出不含密钥或裁图。
3. 模型响应只能选候选 ID；骗入文字命令、任意坐标、改策略、多个 ID、伪造 / 过期 AX 句柄、PID / 窗口 / 会话变化及无 AX 动作均无客户端写。经现有命令执行器的策略、幂等、checkpoint 测试仍通过。
4. `message.history`、`conversation.read`、`message.observed` 与空闲观察者对云端假传输的调用数均为零；B15 本机方向测试维持原状。
5. `swift build`、`swift test`、`check-secrets`、脱敏的测试群活体只读 / 受限动作及门报告完成后才可称已上线；发送数、云端请求数、时延与未验证系统在门报告分别列明。第二台 Mac 的安装、授权和密钥设置单独验收。

## 官方协议依据

- 千问视觉理解与官方地域端点：<https://help.aliyun.com/zh/model-studio/vision>、<https://help.aliyun.com/en/model-studio/compatibility-of-openai-with-dashscope>。
- Gemini 图像输入：<https://ai.google.dev/gemini-api/docs/image-understanding>。
- DeepSeek Vision 图像输入：<https://api-docs.deepseek.com/guides/vision/>。
- 千问北京地域与其它地域的端点分别配置；本批固定北京端点，与用户提供的现有配置相同，其他地域密钥不可直接复用：<https://help.aliyun.com/en/model-studio/regions/>。
- Gemini Developer API 的可用地域受服务端限制；本机合成请求如返回地域限制，不自动切换到 Vertex / Agent Platform。Vertex API key 需要另行核实服务权限：<https://ai.google.dev/gemini-api/docs/available-regions>、<https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/api-keys?usertype=standard>。

模型名、地域与端点可能变化，实现时以对应官方文档及合成传输测试重新核对；凭据所属地域不可由密钥字符串推断。
