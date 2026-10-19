# B58：群名稳定性拒绝的固定诊断分类

维护者已授权修复期间仅在原测试群验证，累计最多两次实际改名，成功后还原；明确零写入的失败允许修码后再测，任何 unknown 或实际状态不清立即停止。本人账号在任务内的 PR 按当前 CI 全绿后可直接合并，第三方账号仍须本人审核。

B57 已合并并安装 1.0.21/build 6，源码树与公开 main 一致。一次新请求仍以 `group title visual round: staleView` 在 prepare/round 0 失败，irreversibleSteps=0；原名未变、实际改名累计 0/2，模型请求及 HTTP 200 增量为零。成功 capture 计数为零不能排除截图后复核失败。完整错误前缀说明已进入原 B37 body，不能据事后空窗口清单认定 B57 当时未完成准备。

随后只读匿名探针证明原选中群、主窗、标题字段、唯一候选、几何和 direct-dialog 检查在取样时一致，但 AXWindows 明确为空、应用 frontmost=true、未隐藏/最小化，窗口服务没有 on-screen 窗。诊断中的一次手动 focus 只观察到标题框扩宽，没有改名称。事后快照仍不足以证明命令中首先失败的检查。

本批只补足原有失败的可观测性：

1. 用 command-local 固定 enum 标记 B37 原稳定检查的 context、headerTraversal、headerCandidate、headerField、directDialog，以及 B55 的 identity、windowSetCount、indicatorShape、indicatorButton、accessoryOverlap；未命中的观察内部失败为 unclassified。
2. 仅在原 staleView 的错误消息追加 `[guardReason=<固定类别>]`。不记录名称、字段值、消息、原始 handle、PID、几何、密钥、截图或模型文本；不新增协议字段或改变错误码、diagnosis、事件、日志类别。
3. 分类只作旁路诊断，不参与授权、重试、重选目标、早生效核对或任何成功判断；保留全部 guard、短路读取顺序、原异常类型、checkpoint、幂等和模型 stop。每次检查开始与成功结束清空分类，避免把后续 observation 的失败误归因到先前成功的 guard。
4. fake 验证各类拒绝仍是原错误且零写入、成功无拒绝通知，handler 消息不含合成目标/新名称/密钥/正文；沿用原 B37/B55/B57 覆盖 stop、早生效与不可逆安全。

源码顺延至 1.0.22-dev。完整离线测试、扫描与独立 review 后经必要 CI 合并并更新；仅在授权剩余额度内执行验证。临时本机只读诊断工具与快照不提交。此批诊断改进本身不表示群名修改已验收。
