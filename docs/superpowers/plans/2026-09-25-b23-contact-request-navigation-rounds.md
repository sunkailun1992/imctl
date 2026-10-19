# B23 实现与验证计划

1. 在 `WeComContactsView` 从左侧 `AXOutline` 枚举精确“新的客户”AX 行，排除右侧标题并拒绝重复；为显式视觉路径增加 `AXSelectedRows` 与卡片表双后验。
2. 在 `WeComActions.openContacts` 保持常规导航；仅 `contact.request.list` / `accept` 的显式视觉配置安装可逆选中回调。解析遗漏或选中读回失败时调用一次有界轮次，后台自动化及其它联系人命令不安装。
3. 在 `WeComCommandHandler` 用既有 `AIPlannerReversibleRunner` 只允许 `.selectRow`。轮次 gate 复查命令、暂停、视觉开关、策略、动作权限与企微窗口；观察和写入前重取唯一 AX 行；按新鲜 AX 状态核验结果。保留接受申请原 checkpoint 和卡片后验。
4. 假件测试覆盖直接 AX 快路径、解析遗漏、首选丢失后再观察、重复行、后台来源、政策 / 暂停 / 整窗开关撤销、窗口 / 行变化、接受前卡片状态变化与 checkpoint 顺序；执行相关测试、全量 `swift test`、`git diff --check`。
5. 由主线集成阶段记录真实企微 / MQTT 只读验收和门报告。无协议变化，不改协议文档；没有接受申请的活体授权不触发接受。
