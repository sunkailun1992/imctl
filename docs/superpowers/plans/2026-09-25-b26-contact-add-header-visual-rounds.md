# B26：添加客户搜索窗标题按钮视觉轮次实施计划

> 同日规格是设计口径；本计划与 fake 不代表真实企微验收。

1. 保留 `AddContact` 的原 AX 唯一按钮、手机号搜索、来源唯一匹配、checkpoint、邀请确认和后验；把多按钮时的一次性视觉选择替换为只返回已验证空白搜索窗的专属回调。
2. 在 runner 新增 `contact.add` + `.control(.addContact)` + `.locate` 专属 `press` 入口；普通入口仍仅准 `selectRow` / `scroll`，`group.addMembers` 专属入口不扩大。限制 4 轮、2 次按压、24 秒。
3. 处理器只在显式 `contact.add` 安装回调。每轮重复策略、暂停、许可、手机号白名单、原动作授权、PID / 窗口 / 页面 / 候选复核；按压后用新鲜 AX 证明空白“添加客户”窗口。未知第二窗口无法与按钮按压建立 AX 因果关系，保持原状并停步；仅对具备已知“添加客户”标题、无输入框和唯一取消按钮的主窗临时 sheet 取消并读回后续轮。
4. Fake 测试覆盖 AX 零上传、正确多轮、丢失首按、未知第二窗口停步、已知临时 sheet 清理、授权 / 方法 / frame 漂移与通用 runner 的 `press` 拒绝；断言 dry run 无邀请与 checkpoint。运行聚焦、`swift build`、全量 `swift test`、diff 与 secret 扫描。
5. 主任务负责签名安装、显式 MQTT 和真实企微取证；本独立工作树不进行客户端操作或邀请，也不改协议、策略、密钥、版本和安装包。
