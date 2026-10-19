# B58：群名守卫固定诊断（2026-10-19）— 离线通过，待受限现场

依据 [规格](../superpowers/specs/2026-10-19-b58-group-name-guard-diagnosis.md) 与 [计划](../superpowers/plans/2026-10-19-b58-group-name-guard-diagnosis.md)。本批先解决原 `staleView` 无法区分拒绝来源的问题，群名修改尚未完成真实验收。

## 已核实的前序现场

- B57 PR #6 已合并，1.0.21/build 6 已安装，三个二进制与公开合并源码树构建一致；签章、设置、LaunchAgent 和 daemon 离线就绪已核对。
- 一次新改名请求终态 failed/UNSUPPORTED，原 B37 `group title visual round: staleView`，prepare/round 0、irreversibleSteps=0。原名未变，实际改名累计 0/2；未发出恢复或新键重试。模型 request/HTTP200 增量为零；成功 capture 计数为零不能排除截后复核失败。
- 本机临时纯读 CLI 比较得到唯一原选中行、同一主窗/标题字段/有效几何、唯一 writable header candidate，未见 direct dialog；当时 AXWindows 是明确空数组，frontmost=true、hidden/minimized=false，窗口服务没有可见窗。一次限定手动 focus 仅观察字段宽度变化，未改名称。事后取样不能作为命令中首次失败原因。
- 临时 probe、匿名快照与取样输出已移除，不进入公开仓库。

## 本批实现与安全边界

固定 enum 只作为 command-local 旁路标记，在原 staleView 消息附 guardReason；所有原 guard、AX 读取顺序、异常类型、checkpoint、幂等、早生效核对、模型 stop 和权限保持不变。诊断不含名称/正文/几何/PID/句柄/密钥/截图/模型内容，分类不参与成功或重试判断。

## 验证

- 最终完整 `IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test --no-parallel`：**1,216 项 / 161 套件**、10 个测试执行程序全部通过，合计 82.037 秒、0 failures；保留全部旧测试及原 B54 记录守卫。
- 新增 B58 专项 5 项通过，0.083 秒：B55 成功、12 类拒绝、原 AXKitError、handler 8 类漂移及合成截后 stale 的 unclassified 隔离；所有请求/图片均为 fake。
- 高可信扫描 706 个追踪文件通过；广泛扫描仍为 11 处原有模板、合成路径与参数说明，已逐项复核。diff 检查通过。
- 独立原始码及测试 review 无阻挡；release build 通过。最终签章候选、CI、安装及受限现场结果见 [PR #7](https://github.com/sunkailun1992/imctl/pull/7) 的最终回执；本文件只记录提交时快照，当前仍安装 1.0.21/build 6，真实群名修改未通过。

维护者明确允许修复期间零写入失败后修码再测，但总实际改名不超过两次，成功后恢复；unknown 或状态不清立即停止。本人账号任务内 PR 在当前 CI 全绿后可合并，第三方账号仍需本人审核。
