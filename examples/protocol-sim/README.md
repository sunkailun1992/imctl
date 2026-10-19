# imctl 协议模拟器与驱动（Python）

`docs/protocol/im-control-protocol.md` 的可执行版本：一个**模拟 imctld 的 mock 控制器**和一个**扮演业务侧的驱动**，让任何语言 / 平台的对接方不用 Mac、不用企微账号就能联调命令、事件、重放、企微 API 路线和回调；驱动同样能对真实 `imctld` 跑完整流程（扫码建群 / 联系我 / 欢迎语 / 读会话与历史 / 发消息 / 接管信号 / 群发）并把二维码存成文件。

模拟器**不是**活体验收：真实客户端的行为以 `docs/gates/` 为准。

## 安装

```bash
cd examples/protocol-sim
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt            # paho-mqtt；只有对真实 broker 才需要
python3 -m unittest discover -s tests -t . # 零依赖：内存总线上的端到端测试
```

## 用法

```bash
# 1. 离线：mock + 驱动在同一进程，跑完整流程，二维码（占位）与报告写到 ./out
python3 -m imctl_sim.cli --broker memory:// demo --out ./out

# 2. 在你的 EMQX 上起一个 mock 控制器（其它语言的消费方就能对它联调）
export IMCTL_MQTT_URL='mqtt://<user>:<pass>@<host>:1883'   # 不要写进仓库
python3 -m imctl_sim.cli mock --controller-id mock-01 --corp-id wwmock

# 3. 驱动：单个方法 / 事件流 / 完整 demo（对 mock 或真实 imctld 都可）
python3 -m imctl_sim.cli call --controller-id mac-01 controller.describe
python3 -m imctl_sim.cli call --controller-id mac-01 message.send '{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}'
python3 -m imctl_sim.cli tail --controller-id mac-01 --seconds 60
python3 -m imctl_sim.cli demo --controller-id mac-01 --group imctl测试群 --target chatId:<chat_id> --userid <员工userid> --out ./out

# 4. 只下载一张二维码
python3 -m imctl_sim.cli qr --url <group.joinway.get 返回的 qrCode> --out ./out/joinway.png
```

`demo` 对真实控制器时：API 路线未 enroll（`describe.wecomApi == "disabled"`）就跳过群活码 / 联系我 / 欢迎语 / 群发；`sim.*` 步骤（模拟客户发言、接管、回调）只在 mock 上执行，真实环境由人扫码、说话。

## 直接调企微取二维码（只为你自己快速验证）

`imctl_sim/wecom_direct.py` 不经代理，用环境变量里的 corpid / secret 直接调企微生成群活码与联系我二维码并下载 PNG。这绕过了"secret 只在代理"的生产设计，只能在你本机出口 IP 已加入自建应用可信 IP 时用于验证：

```bash
export WECOM_CORP_ID=ww… WECOM_CORP_SECRET=… WECOM_USERID=<员工userid>
python3 -m imctl_sim.wecom_direct groups                                  # 列客户群及 chat_id
python3 -m imctl_sim.wecom_direct qr --chat-id <种子群 chat_id> --out ./out # 群活码 + 联系我 二维码 PNG
unset WECOM_CORP_SECRET
```

## 结构

| 文件 | 内容 |
|---|---|
| `imctl_sim/protocol.py` | 方法 / 事件 / 错误码常量、topic、目标语法、`messageKey` 算法 |
| `imctl_sim/bus.py` | `MemoryBus`（进程内，测试与离线 demo）与 `MqttBus`（paho MQTT 5，Response Topic / Correlation Data / user properties / retain） |
| `imctl_sim/mock_controller.py` | mock 控制器：会话与消息、身份桥、策略、暂停、限速、幂等、事件日志与 `event.replay`、16 个 API 方法的假实现、`sim.inbound|takeover|callback|reset` |
| `imctl_sim/driver.py` | `ImctlClient`：`call` / `command`、事件订阅与 gap 对账、`wait_for`、二维码下载 |
| `imctl_sim/cli.py` | `mock` / `call` / `tail` / `demo` / `qr` |
| `imctl_sim/wecom_direct.py` | 直接调企微的验证脚本（见上） |
| `tests/test_sim.py` | 内存总线上的端到端测试 |

## 边界

- mock 的二维码 URL 是 `https://mock.invalid/qr/…`（装了 `qrcode[pil]` 会渲染成可扫的占位图，否则写 `.txt`）；真实二维码只有真实企微接口（经代理或 `wecom_direct`）才有。
- 语音消息：员工↔客户会话没有官方发送接口、桌面 AX 没有录音路径；mock 与真实控制器都只发文本，附件只在欢迎语 / 群发（企微 attachments 形状）。
- broker 地址、凭据、corpid / secret 只走环境变量或本机文件，不进仓库。
