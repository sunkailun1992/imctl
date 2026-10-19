# B60 实施计划

依据 [规格](../specs/2026-10-19-b60-group-name-field-resize.md)，在既有修复授权内处理固定 AXValue 后同一标题字段的受限宽度变化，不改变全局几何规则或当前 `unknown` 的停止边界。

1. **先建立可区分阶段的回归。** 用 fake AX 在本命令写入固定名称后分别模拟字段变宽/变窄，旧实现应暴露完整 frame 冻结造成的拒绝。对照写值前宽度变化、写后横/纵位置或高度变化、未知值、替换字段、越界、多候选和同名其他会话；记录 prepare、afterStaging、模型调用及 AX 动作次数，不能仅用异常是否消失判断通过。
2. **建立群名专用 placement。** 保留有限性、正宽高、原横/纵位置与高度容差和标题区域包含；只在已知固定 AXValue 写入后允许宽度变化。prepare 仍采用完整冻结 frame，不修改全局 `sameHistoryFrame`、群创建或其他命令，也不重选目标或依当前新标题重新解析授权。
3. **复用原 handler 守卫。** 不抽取或重写 B37 BFS；维持原 stableReader 的 `allowAppliedTitle` 参数及 `checkCommand` 签名和调用。仅当原早生效写后 gate 的 `allowAppliedTitle` 或 `state.afterStagingStarted` 为 true，并且 `state.beforeVerified`、字段精确匹配固定 `requestedName` 时，启用受限宽度。prepare/写值前仍严格；不新增 stagedValue、原值宽度例外或恢复 hook。唯一候选、direct-dialog、B55 窗口集合及原授权 gate 位置与语义不变。
4. **删除不安全补偿，对齐早生效所有权。** 手机新名而桌面原列旧名已证明旧列不能保证安全草稿。删除 `restoreStagedNameIfOwned` 与调用；checkpoint 后 stop、守卫或 confirm 错误原样传播，零补偿 AXValue、不自动确认或重试。`GroupRename.swift` 早生效核对采用同一受限 placement，继续独立核对原窗口、PID、字段、原会话行、固定请求值与标题区域。仅字段回显不能提前成功，仍要求唯一原行的新名称后验；已生效路径不追加 confirm。
5. **锁住焦点恢复与不可逆边界。** B57 可见窗口 helper 增加只读 restoreFocus 判定；handler 在执行 checkpoint 回调前设置本地尝试标志，只在动作返回 verified true 后设置成功标志。经公有 handler/off-Space fake 先建立红测：第二轮 stop 为 checkpoint 一次、字段仅一次请求值、无补偿/confirm/restoreFrontmost；checkpoint 回调抛错零字段写入且不恢复；afterSubmit 崩溃原类型传播且不恢复。保留原 prepare-stop 与正常 verified 恢复焦点测试。再回归模型非法选择、政策/录屏/冻结设置撤销、所有权漂移与未验证结果；不改变 checkpoint、幂等、`unknown`、动作上限和异常类别，也不因几何相容或手机人工证据清除已有 checkpoint。
6. **完成离线交付。** 明确关闭 live 与 live vision，运行完整非活体/守卫测试和敏感内容扫描，独立审查 diff 与测试。主流程按远端最新 main 顺延版本并同步协议、安装现状和门报告，填入精确测试数和未验收项；当前安装基线仍为 1.0.23/build 8。脱敏记录新增可信人工证据：手机已显示请求新名，实际改名 1/2、剩余一次仅还原；原命令保持 unknown，不改写为 succeeded，也不宣称本次宽度根因或后续修复已获现场验证。
7. **经 PR 核对当前版本 CI。** 开工、提交前、推送前先 fetch；远端 main 前进则跟进并重新验证，禁止强推。本人账号已授权协作任务按必要 CI 全绿、评审对话解决后的例外合并，第三方账号仍须本人审核。保留权限、规则集、发布、安装与真实动作各自授权，不修改 GitHub 门禁。
8. **保持当前现场停止。** 本次 unknown 请求不重放、不换键、不确认或恢复待定草稿。候选就绪后先只读厘清桌面 pending 状态，再一次性确认所需更新及一次还原的明确授权；获准后才安排安装核对与唯一一次还原，不再做向外改名试验。离线几何问题与当次现场根因分开记录；手机人工确认、CI 或安装均不回写旧命令状态，新的真实结果仍须记录终态及同一原会话后验。

最终 review 新发现正常 confirm 后仅比 selected title 的原有边界：在同批增加独立红测，原选中行失去选择或切到另一同新名行均不能成功，也不得为探测结果 blur；正常 rename 的两次列表等待绑定原 row handle，原固定 blur 前复核原所有权，群创建不变。该新 concern 是首次完整测试通过后再验证的原因，最终完整数字以门报告为准。

维护者在 unknown 后回复“继续”，主会话已明确续行只限 CI 全绿、更新后剩余一次还原，不增加向外改名试验。后续依此继续安装与唯一一次还原，新 unknown 仍立即停止；旧记录与实际1/2的事实不改写。
