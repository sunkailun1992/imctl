# B20 写入命令目标选中视觉轮次门报告

## 范围与当前结论

- 代码改造范围为 `message.send`、`message.sendFile`、`group.rename`、`group.addMembers` 的**目标会话选中阶段**：解析遗漏且原始 AX 行顶部标题唯一时，沿用 B18 有界可逆轮次；已激活或已解析 AX 行走原零上传路径。B19 模型返回后复核继续生效。
- 四方法的后续写入与不可逆点保持原路径。本批没有协议、按键、白名单、截图范围或传输语义变化；不能据此宣称全部固定桌面命令已有端到端多轮 AI 操作。
- 本批向企微发送 **0 条**消息；本机安装后仅做只读 MQTT 探针，未触发的视觉分支仍标待活体。

## 代码与 fake 验证矩阵

| 核对点 | 当前代码 / 测试覆盖 | 执行回执 |
|---|---|---|
| 四方法目标前缀 | 各方法先核对原写入动作策略，再调用共用选中 helper；发文件仍先获取并在失败时清理临时文件。 | 源码 diff 已复核；新增 fake 四方法矩阵通过。 |
| 解析遗漏后备 | B18 runner 仅接受目标标题唯一的原始 AX 行；一轮未落实时可重读、重选，最多 2 次动作 / 6 轮 / 40 秒。 | 首次选中未生效的 fake 双轮用例通过。 |
| 推理后门禁 | 来源 / 方法、暂停、视觉设置、初始与当前政策、目标身份、两种动作授权，以及 PID / 窗口 / 行句柄在 AX 写前复核。 | 撤销政策 / 暂停 / 整窗许可、重复或消失行、窗口 frame / PID / 身份桥变更的 fake 用例通过；漂移后三类均是零 AX 写与零 checkpoint。 |
| 快速路径 | 已激活和已解析 AX 行无需截图；四方法已解析路径有零模型 / 零截图断言。 | 四方法解析行 fake 用例通过。 |
| 不可逆边界 | Fake 在发送 / 群写入之前停止，断言 checkpoint 空；真实写入不在本批无新发送授权的活体计划内。 | Fake 通过；活体写入未验。 |

## 构建与发布证据

| 层次 | B20 回执 |
|---|---|
| `swift build` | 通过。 |
| 聚焦 fake / 全量 `swift test` | B20 新 suite **9/9**，全量 **679/679** 通过（9 个测试可执行产物计数之和）；没有启用 live 套件。 |
| `ForbiddenAPITests`、协议守卫、`git diff --check`、secret 扫描 | 全量测试含守卫通过，`git diff --check` 通过；扫描仍为既有 11 条示例 / 文档 warning，本批新增文件无命中。 |
| 源码提交 / 推送 | `9cbb8e6` 已推送到 `origin/main`；后续门报告补记另行提交。 |
| 签名包 / 本机安装 / `setup --check` | 源码提交生成 `1.0.9 build 162`；`codesign --verify --deep --strict` 通过，pkg 三个可执行程序均在 payload。`out/imctl-1.0.9.pkg` SHA-256 `5b09ff948b091cfcd69ad5c878d53f1ad5ddc7141bc7d2564570f057aa76e8f3`。外盘写 owner / 属性有提示，包仍构建且 `installer -target CurrentUserHomeDirectory` 成功；已重启守护进程与控制台，安装后 daemon 二进制哈希与 `out/imctl.app` 一致，版本与 bundle build 读回为 `1.0.9-dev` / `162`；`setup --check` 六项通过。 |
| 第二台 Mac | `~/Desktop/imctl-1.0.9-第二台Mac.zip` 四件重包、CRC 和包内 pkg 哈希通过；ZIP SHA-256 `0e889fdbe8b34fae35570cfcf574d5dbed8981531e337bb9e246634e5545e6ae`。目标机尚未安装 / 授权 / MQTT 验收。 |

## 真实客户端与 MQTT

| 步骤 | B20 证据 |
|---|---|
| 只读 MQTT / 活动会话 AX 后验 | 新 daemon 上 `controller.describe`、`account.status` 成功；后者读到企微窗口可达、19 个会话。`conversation.read` 对本人文件传输助手成功，活动头部与目标一致，读到 20 条当前可见消息；没有执行四个写命令。 |
| 普通 AX 路径模型请求数 | 视觉设置只读核对为千问 `qwen3.7-plus`，云端、整窗与密钥存在标志开启；本批只读探针没有可核实的云端请求次数。Fake 零请求不能代替真实计数。 |
| 自然解析遗漏的整窗视觉轮次 | 未验；若本批未自然触发，继续标待活体，不以普通路径成功替代。 |
| 四方法真实写入与 MQTT 终态事件 | 未执行。B17 已使用的单条测试消息许可不复用于 B20；B20 发送数为 0。 |

另：显式 `message.history{limit:1}` 的只读 MQTT 探针间歇成功、间歇返回 `CLIENT_UNAVAILABLE`；正在核对根因，不能把该方法记为稳定通过。本批的 B20 目标选中改动没有改变 `message.history` 路径。

## 未闭环

1. 真实企微解析遗漏时的整窗模型请求、轮次后 AX 选行与写入命令终态尚需活体样本；模型自评不能代替客户端证据。
2. `message.history`、联系人、建群与广播等命令的多轮步骤不属于 B20；四方法的不可逆提交阶段也未改造成通用规划。
3. `message.history` 的间歇 `CLIENT_UNAVAILABLE` 需定位；第二台 Mac 的安装、TCC 与 MQTT 仍待目标机验收。
