# EMQX 收口：每机凭据与 topic ACL（需用户在仪表盘操作）

现状（2026-09-13 核）：broker 是用户 LAN 上的 EMQX 5.9.3，**MQTT 客户端无认证链（匿名可连）**，authz `file` 源且 `no_match = allow`。地址与仪表盘凭据只在本机 `~/Library/Application Support/imctl/mqtt.json` 与用户手里，不入库。

控制器侧已就绪：`imctl enroll --username … --password …` 写入凭据（0600），`imctld --mqtt` 与 `imctl mqtt call|tail` 都会带上；`MQTTBinding` 只向 `im/<id>/` 子树发布（Response Topic 在子树外一律改用 `im/<id>/rsp`），所以每机 ACL 收紧不会丢回复。

## 目标模型

- 一机一账号一 `controller_id`；**MQTT 用户名 = controller_id**，密码每机随机（`openssl rand -base64 24`）。这样一条带 `${username}` 的规则覆盖所有 Mac，不用逐机加规则。
- Java 消费方用独立用户（例如 `java`），只能发布命令、订阅事件/状态/自己的回复子树。
- 缺省拒绝。

## 步骤（仪表盘）

1. **认证**：Access Control → Authentication → Create → Password-Based → Built-in Database（密码 hash 用默认 sha256 + salt）。Users 里新增：`<controller_id>`（每台 Mac 一条）、`java`。
2. **授权**：Access Control → Authorization → Settings：`No match: deny`；Create → File（或 Built-in Database，规则等价），规则按顺序：

```erlang
%% Java 消费方：发命令、收事件/状态、收自己的回复子树
{allow, {username, "java"}, publish,   ["im/+/cmd"]}.
{allow, {username, "java"}, subscribe, ["im/+/evt", "im/+/state", "im/+/rsp/#"]}.
%% 每台 Mac 只在自己的子树里（用户名 = controller_id）
{allow, all, all, ["im/${username}/#"]}.
{deny, all}.
```

3. **共享订阅**：Java 用 `$share/<group>/im/+/evt`。EMQX 5 做授权时按剥离 `$share/<group>/` 前缀后的 topic 匹配；**上线前在仪表盘 Authorization 的"Check"或用 `imctl mqtt tail` 以 java 用户实测一次**，若被拒再加一条 `{allow, {username, "java"}, subscribe, ["$share/<group>/im/+/evt"]}`。
4. **禁用匿名**：认证器创建后 EMQX 即要求认证；确认监听器上没有 `enable_authn = false`。
5. 控制器写入凭据并验证。`--controller-id` 可省：沿用已登记的 id，没有就取本机名小写，并打印出来；EMQX 里给这台 Mac 建的用户名要与打印出的 id 相同。

```bash
imctl enroll --broker <host>[:1883] --controller-id mac-01 --username mac-01 --password '<随机>'
imctld run --mqtt --watch-interval 1        # 日志应有 connected … sessionPresent=…
imctl mqtt call controller.describe         # 用同一凭据；应有响应
```

6. **反向验证**：用另一个 controller 的用户名试发布 `im/mac-01/cmd` 应被拒（仪表盘 Authorization 页有 Check 工具，或 `mosquitto_pub -u mac-02 -P …` 看断连/无回复）。

## 注意

- 规则里 `${username}` 只能替换整段 topic 层级，不能拼进字符串。
- 若以后用 TLS（8883），`imctl enroll --tls`；证书由用户在 broker 侧配置。
- `imctl mqtt call` 的回复 topic 是 `im/<id>/rsp/cli-<pid>`，在控制器子树内；Java 的回复 topic 也必须是 `im/<id>/rsp/<instance>`，否则控制器改回 `im/<id>/rsp`。
