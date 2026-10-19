# imctl Java 参考消费方

`docs/protocol/im-control-protocol.md` 业务侧的 Java 17 / Spring Boot 4 / Maven 参考实现，只发命令、只做消息业务：

- 共享订阅 `$share/imctl-consumers/im/+/evt` 与 `$share/imctl-consumers/wecom/+/evt`，`im/+/state` 看控制器上下线；
- `(source, eventId)` 落库去重（`EventStore`，默认内存，换成主键 `(source, event_id)` 的表即可）；
- 事件空洞、自身重连、控制器重新上线 → `event.replay` 对账（`Reconciler`）；
- `message.observed{origin:peer}` 且会话在群 / 客户白名单（按 `chatId` / `externalUserId`，从不按标题）→ `conversation.read` + `message.history` 取上下文 → `ReplyPolicy` 决定回不回 → `message.send{target:"chatId:…", idempotencyKey, ttlMs}`；`messageKey` 去重；`origin:other` 接管 → 按会话静默 30 分钟；
- 企微回调 `add_external_contact` 且 `State` 在渠道开关内 → 20 s 内 `contact.welcome.send`（附群活码链接）+ `contact.remark.set`（备注唯一化）；`change_external_chat/create|update` → `group.get` 回写身份桥；
- `ReplyPolicy` 可插拔：默认回声（无模型也能证明回路），配置 `AI_BASE_URL` / `AI_API_KEY` / `AI_MODEL` 后走 OpenAI 兼容 `chat/completions`（千问 / DeepSeek 等）。

```bash
mvn -q test                                  # 核心逻辑单测（假命令通道，不连 broker）
export IMCTL_MQTT_URL='mqtt://<host>:1883' IMCTL_MQTT_USERNAME=java IMCTL_MQTT_PASSWORD=… \
       CONSUMER_GROUP_ALLOWLIST=<chat_id> CONSUMER_WELCOME_STATES=ch1 CONSUMER_JOINWAY_URL=<群活码链接> CONSUMER_STAFF_USERID=<userid>
mvn -q -DskipTests package && java -jar target/imctl-java-consumer-0.1.0.jar
```

先用 `examples/protocol-sim` 的 mock 控制器联调（`python3 -m imctl_sim.cli mock --controller-id mock-01`），再指向真实 imctld。控制器侧的白名单、策略与限速与本消费方无关地生效：这里的白名单只能更严。
