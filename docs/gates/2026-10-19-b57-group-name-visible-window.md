# B57 群名视觉检查前的可见主窗恢复（2026-10-19）— 离线通过，待 CI 与真实改名

B56 已合并并安装公开 1.0.20/build 4。唯一获准的新改名请求在 prepare/round 0 的 AX 前置检查停止，`irreversibleSteps:0`；群名步骤截图 / 模型 / HTTP200 增量都是 0，实际改名 0 次。原名保持，没有恢复动作或新键重试，详见 PR #4 的现场回执。

只读现场的 `AXWindows` 是 0 元素数组，但原主窗 / focused window / 唯一选中目标仍可读，主窗 frame 为 `(0,30,1920×1170)`；窗口服务的该应用窗口全部 `onScreen:false`。这与既有 locator 对另一 Space 的记录相符，并能重现 B55 的零窗拒绝。未上传或保存现场截图、模型原文；临时 AX 树默认脱敏，不入库。

本批依 [规格](../superpowers/specs/2026-10-19-b57-group-name-visible-window.md) 先取得可见且不变的原主窗，再运行原 B37 / B55；不允许空集合直接通过。离线结果见下。提交本报告时已安装为 1.0.20/build 4，群名实机验收尚未通过，本批没有新增真实改名或视觉请求；后续安装及受限现场结果以本 PR 的最终回执为准。

## 离线验证

- 最终 `IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test --no-parallel` 退出码 0；10 个测试可执行文件合计 1,211 项 / 160 套件全部通过，汇总测试耗时 82.202 秒。新增 B57 套件 15 项，保留全部原测试。
- 专项测试 15 项 / 1 套件在 0.536 秒通过。初始千问 / Gemini 的有效设置都能冻结为起点；等待中任何 provider / key / cloud / full-window 变动仍拒绝。raw `AXWindows` 的 nil / unsupported / 非数组 / AX 失败不会被当成明确空集合，也不会触发前景写入。
- helper 测试覆盖空集合恢复为同一主窗及精确分享指示器后，再实际调用原 B55；永久零窗、未知对话框 / 第三窗、main / focused / row handle / title / header / frame / PID / backend 漂移、激活失败、策略 / pause / 权限 / 预算撤销均拒绝。所有 helper 测试不请求模型、不写名称；失败和 body 抛错仍尝试恢复原前景。
- 另有完整 handler 集成：hidden→visible 后真正调用原 B37 runner，全部使用合成图和假决策。prepare 返回 stop 保留诊断，0 checkpoint / 0 群名值写入 / 0 confirm；正常路径为两轮观察、1 checkpoint、1 次群名值写入、原字段 1 次 confirm 和 1 次完成回呼。捕图、决策、checkpoint 与 confirm 时都尚未恢复前景，整段结束后才恢复。
- 独立只读审查及集成补强复查均无阻挡。原 B55、群名写入动作、runner、checkpoint、幂等与许可不改；共享预算检查仅从 private 改为 module-internal，供同模块 handler extension 复用，检查内容不变。
- 高可信敏感内容扫描覆盖 701 个追踪文件通过；广泛扫描仍为 11 处既有模板、合成路径或参数 / scanner 自检字符串，逐项复核无新增实际敏感内容；`git diff --check` 通过。

按维护者的新协作授权，本人账号与 AI 的本任务 PR 经当前版本必要 CI 全绿且评审对话解决后可直接合并；第三方账号仍需本人审核。上述离线证据不能替代真实改名验收，也不授权超过前次“前置失败即停止”的真实请求范围。
