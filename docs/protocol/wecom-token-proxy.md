# 令牌注入代理契约（`wecom-token-proxy`）

imctl 不持企微 secret、不直连企微：所有官方接口经云端固定 IP 主机上的代理转发，代理注入 `access_token`；企微回调也打到代理，由代理验签、解密后转成 MQTT 事件。本页是 imctl（Swift `WeComAPI`）、代理（Java 17 / Spring Boot 4，`proxy/wecom-token-proxy/`）与 Java 消费方三方共同遵守的契约。业务语义在 `im-control-protocol.md`；本页只写 HTTP 与回调形状。

## 1. 透传接口

- 请求：`POST {base}/wecom/{path}`，`Authorization: Bearer <proxy-token>`，`Content-Type: application/json`，请求体 = 企微该接口的 JSON（snake_case，原样）。`{path}` 是企微 `https://qyapi.weixin.qq.com/cgi-bin/` 之后的路径，例如 `externalcontact/groupchat/list`。
- 代理动作：校验 Bearer → 路径白名单（不在白名单 `404`）→ 取缓存的 `access_token`（过期或收到 `40014` / `42001` 时刷新一次并重试一次）→ `POST https://qyapi.weixin.qq.com/cgi-bin/{path}?access_token=…` → 原样返回企微响应体与 `200`。
- 响应：HTTP `200` + 企微 JSON（含 `errcode` / `errmsg`）；imctl 只按 `errcode` 判断（`≠0` → `WECOM_API`）。代理自身错误用非 2xx：`401` token 缺失/错误、`403` token 不允许该路径、`404` 路径不在白名单、`429` 超过限流、`502` 企微不可达、`503` 尚无 access_token。
- 默认路径白名单（B5 用到的 16 个接口 + 素材上传）：

```text
externalcontact/groupchat/list            externalcontact/groupchat/get
externalcontact/groupchat/add_join_way    externalcontact/groupchat/get_join_way
externalcontact/groupchat/update_join_way externalcontact/groupchat/del_join_way
externalcontact/add_contact_way           externalcontact/list_contact_way
externalcontact/get_contact_way           externalcontact/update_contact_way
externalcontact/del_contact_way           externalcontact/send_welcome_msg
externalcontact/remark                    externalcontact/add_msg_template
externalcontact/get_groupmsg_task         externalcontact/get_groupmsg_send_result
media/upload                              （multipart，`type=image|file|video|voice`；欢迎语/群发附件的 media_id 来源）
```

- 限流：每 token 每分钟请求数上限（默认 120），超出 `429`；企微本身的接口频率限制原样透传（`45009`）。
- 审计：一行一请求——时间、token 指纹（前 6 位）、路径、HTTP 状态、`errcode`、耗时；**不记请求/响应正文**。

## 2. 健康与身份

- `GET /healthz` → `{"status":"ok","tokenCached":true|false,"corpId":"<corpid>"}`（不含 secret / token）。
- Bearer token 由代理环境变量 `PROXY_BEARER_TOKENS`（逗号分隔，一台 Mac 一个）签发，`imctl wecom enroll --proxy <base> --token-stdin` 写入本机 0600 文件。轮换 = 环境变量加新减旧 + 各 Mac 重新 enroll。

## 3. 回调（企微 → 代理 → MQTT）

- 企微后台"接收事件服务器"URL：`https://<host>/wecom/callback`，Token 与 EncodingAESKey 只在代理环境变量。
- `GET /wecom/callback?msg_signature&timestamp&nonce&echostr`：`sha1(sort(token, timestamp, nonce, echostr))` 与 `msg_signature` 比对，AES-256-CBC 解密 `echostr`（密钥 `Base64(EncodingAESKey + "=")`，IV = 密钥前 16 字节，明文 = 16 随机字节 + 4 字节网络序长度 + 消息 + corpid），corpid 必须等于 `WECOM_CORP_ID`，回明文。
- `POST /wecom/callback?msg_signature&timestamp&nonce`，体为 `<xml><ToUserName/><Encrypt/><AgentID/></xml>`：同样验签、解密得到事件 XML，解析成扁平字段后发布 MQTT，**发布成功后**再回 `success`（企微要求 5 s 内；失败回 `500` 让企微重试）。
- MQTT：topic `wecom/{corpId}/evt`，QoS 1，持久会话，载荷：

```json
{"eventId": 128, "tsMs": 1789300000000, "kind": "wecom.callback", "corpId": "ww…",
 "payload": {"ToUserName": "ww…", "FromUserName": "sys", "CreateTime": "1789300000", "MsgType": "event",
             "Event": "change_external_contact", "ChangeType": "add_external_contact", "UserID": "u1",
             "ExternalUserID": "wm…", "State": "ch1", "WelcomeCode": "…"}}
```
  user properties：`event_id`、`kind`、`corp_id`。`eventId` 由代理单调分配并持久化（重启不回退）；Java 以 `(corpId, eventId)` 去重。`change_external_chat`（`create` / `update` / `dismiss`）、`change_external_contact`（`add_external_contact` / `del_external_contact` / `del_follow_user` / `edit_external_contact`）、`change_external_tag` 都原样透传，字段名保持企微的 PascalCase。
- 回调事件不含客户聊天内容；聊天内容只来自 imctl 的桌面观察（`message.observed`）。

## 4. 环境变量（代理）

| 变量 | 含义 |
|---|---|
| `WECOM_CORP_ID` | corpid |
| `WECOM_CORP_SECRET` | 自建应用 secret（客户联系权限） |
| `WECOM_AGENT_ID` | agentid |
| `WECOM_CALLBACK_TOKEN` / `WECOM_CALLBACK_AES_KEY` | 回调 Token / EncodingAESKey |
| `PROXY_BEARER_TOKENS` | 允许的 Bearer token，逗号分隔 |
| `PROXY_ALLOWED_PATHS` | 覆盖默认白名单（逗号分隔） |
| `PROXY_RATE_LIMIT_PER_MINUTE` | 每 token 每分钟上限（默认 120） |
| `MQTT_URL` / `MQTT_USERNAME` / `MQTT_PASSWORD` / `MQTT_CLIENT_ID` | broker（MQTT 5，QoS 1，持久会话） |
| `MQTT_TOPIC_PREFIX` | 默认 `wecom` |
| `PROXY_DATA_DIR` | `eventId` 序列持久化目录 |

部署前提（用户提供）：固定公网 IP 主机（其出口 IP 填进自建应用"可信 IP"）、HTTPS 域名、自建应用参数。imctl 侧只需 `imctl wecom enroll`。

## 5. imctl 侧映射

| 协议方法 | 接口 | 身份桥 |
|---|---|---|
| `group.list` / `group.get` | `groupchat/list` / `groupchat/get` | `group.get` 与 `group.list{syncNames}` 写 `chat_id ↔ name` |
| `group.joinway.create|get|update|delete` | `groupchat/add|get|update|del_join_way` | — |
| `contact.way.create|list|get|update|delete` | `add|list|get|update|del_contact_way` | — |
| `contact.welcome.send` | `send_welcome_msg` | — |
| `contact.remark.set` | `remark` | 写 `external_userid ↔ remark` |
| `broadcast.create` / `broadcast.get` | `add_msg_template` / `get_groupmsg_task` / `get_groupmsg_send_result` | — |
| `broadcast.confirm` | （桌面 AX：群发助手 → 发送） | — |

没有 enroll 的控制器对这些方法回 `UNSUPPORTED`；代理不可达 `PROXY_ERROR`；企微 `errcode≠0` → `WECOM_API`（message 含 errcode 与 errmsg）。
