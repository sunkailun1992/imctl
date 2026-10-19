# 批次 B5：`WeComAPI`（经令牌注入代理的企微官方接口客户端）与 API 路线命令（2026-09-14 19:5x–20:1x CST）— 单测通过、无活体（代理与自建应用未就绪）

条件：没有代理主机、没有自建应用参数，因此**没有调用任何真实企微接口、没有建群、没有群发、没有发欢迎语**；全部 HTTP 路径只在 `URLProtocol` 伪代理与记录式传输上验证。桌面客户端未被触碰（`broadcast.confirm` 只在合成夹具上按了假按钮）。计划：`docs/superpowers/plans/2026-09-14-b5-wecom-api-proxy-client.md`；契约：`docs/protocol/wecom-token-proxy.md`。

## 实现

- 协议：`RPCMethod` 26 个（新增 `group.list|get`、`group.joinway.create|get|update|delete`、`contact.way.create|list|get|update|delete`、`contact.welcome.send`、`contact.remark.set`、`broadcast.create|confirm|get`），`isWeComAPI` 路由，`broadcast.create` 需 `idempotencyKey`；`ControlError` 新增 `UNSUPPORTED` / `WECOM_API`（含 errcode 与 errmsg）/ `PROXY_ERROR`；`APICommandHandler` 协议；`CommandExecutor.apiHandler`（nil → `UNSUPPORTED`，API 方法不受暂停与速率上限影响）；`controller.describe` 增 `wecomApi: enabled|disabled`；`tools/list` 27 个。
- `WeComAPI` target：`WeComProxySettings`（`~/Library/Application Support/imctl/wecom-proxy.json`，0600，`summary` 不含 token）；`URLSessionWeComTransport`（`POST {base}/wecom/{path}`，Bearer，同步）；`WeComAPIClient`（snake_case 编解码、信封 `errcode` 判断、401/403 → `PROXY_ERROR`）；16 个接口的类型化方法与模型；`WeComAPIHandler`（协议参数 camelCase ↔ 企微 snake_case，`group.get` / `group.list{syncNames}` / `contact.remark.set` 回写身份桥，`syncGroups` 分页同步；`broadcast.confirm` 委托闭包，缺失即 `UNSUPPORTED`）。
- 适配器：`WeComActions.confirmBroadcast`（策略 `confirmBroadcast`；主窗口与应用其它窗口里找含"群发"的静态文本 + 发送样按钮，`AXPress` 一次，等按钮禁用/消失）；`WeComCommandHandler.confirmBroadcast(msgid:)`；`ActionError.actionUnavailable` 现映射为 `UNSUPPORTED`（原 `CLIENT_UNAVAILABLE`）。
- 守护进程：`imctld run --wecom-config`，文件存在即启用 API 路线并把 `broadcast.confirm` 接到适配器；策略 enabled 加 `.confirmBroadcast`。
- CLI：`imctl wecom enroll`（`--token-stdin` 避免进 shell 历史）`|status|call <path> --body|sync-groups`。
- 文档：`docs/protocol/wecom-token-proxy.md`（透传接口、白名单、错误码、健康、回调验签/解密、MQTT 事件形状、环境变量、imctl 侧映射）；`README.md`；`docs/protocol/java-consumer.md`。

## 单测

- `swift test`：**198 个测试 / 58 个套件通过**（B4 为 182 / 52）。新增套件：URLSessionWeComTransport（URLProtocol 伪代理：路径 `/wecom/…`、`Authorization: Bearer`、JSON 体、状态码透传、非法地址）、WeComAPIClient（16 个接口的请求路径/字段与响应解码、错误映射）、WeComAPIHandler（身份桥回写、分页同步、群发创建/确认/结果、群活码/联系我/欢迎语）、WeComProxySettings、broadcast.confirm AX 探针、imctl wecom；追加：Protocol types（26 方法、幂等键、错误码）、CommandExecutor（API 路由、UNSUPPORTED、暂停不拦 API）、Command parsing、RPCDispatcher（27 工具）。
- `bash scripts/check-secrets.sh`：仅既有 1 条历史命中。

## 未做 / 待用户事项

- 真实接口：需要自建应用（corpid / agentid / secret，客户联系权限，可信 IP）、代理主机与 HTTPS 域名、P1 代理部署；之后 `imctl wecom enroll` → `imctl wecom call externalcontact/groupchat/list --body '{}'` 取证 → `sync-groups` → 群活码 / 联系我 / 欢迎语 / 群发逐项活体。
- `broadcast.confirm` 的真实"群发助手"窗口形状未取证；探针找不到即 `UNSUPPORTED`，Java 退回逐群 `message.send`。
- 二维码：`group.joinway.get` / `contact.way.create` 返回的 `qrCode` 是企微图片 URL，只有真实接口打通后才有；本批没有任何真实二维码。
- 附件：`contact.welcome.send` / `broadcast.create` 的 `attachments` 按企微形状原样透传（link / image / miniprogram / video / file）；语音消息在员工↔客户会话没有官方发送接口、桌面 AX 也没有录音路径，本批不支持。
