# 完整公开迁移与本机重装（2026-10-19）— 公开与重装完成，CI 排程修正待审核

## 用户决定

用户要求修复群改名误报、脱敏后完整开源，保留全部功能与项目内容；开发者可贡献代码，合入 `main` 必须由本人审核。用户选择旧私有库改名 `imctl-private`，新建干净的公开 `imctl`，并要求移除本机旧 App、重装公开版。

## 文件与历史

- 公开仓库：[sunkailun1992/imctl](https://github.com/sunkailun1992/imctl)，Apache-2.0。
- 初始公开提交：`65694bc667afa533cc6363177a2c5da075f5b76e`；只有 1 笔干净历史，作者与提交者均使用公开 GitHub handle / noreply。
- 原私有库改名 `imctl-private`，仍为 private；原有提交、标签与本地开发资料留在该私有副本，没有改写或强推。
- 初始公开树共 687 个文件，原有 677 个路径全部保留，新增 10 个修复规格 / 计划 / 门报告及公开协作文件。没有删除原有项目内容。
- 从已审查私有快照导出后，逐个比对全部 687 个文件的 Git 路径、mode 和 blob id，全部一致。没有挑选部分模块，未携带旧 `.git`、运行数据、构建缓存或本机 IDE 元数据。

| 目录 | 初始公开文件数 | 内容 |
|---|---:|---|
| `Sources/` | 230 | 全部控制台、CLI、守护进程、核心、AX、企微、传输和 OSS 源码 |
| `Tests/` | 168 | 全部测试与合成 / 脱敏夹具 |
| `docs/` | 200 | 全部协议、运维、工程规范、规格、计划、历史验收记录 |
| `examples/` | 26 | Java 消费方及 Python 协议模拟器 |
| `proxy/` | 32 | 完整令牌代理及其测试 / 配置模板 |
| `scripts/` | 6 | 构建、签名、安装与扫描脚本 |
| `packaging/` | 11 | 完整安装与图示资源 |
| `.github/` | 4 | 工具入口、全库 CODEOWNERS、PR 模板、CI |
| 根目录文件 | 10 | 包描述 / 锁文件、README、授权与治理文件等 |

新增的本报告通过 PR 补充，故后续文件数可以增长；上表固定指初始公开提交。

## 敏感信息审查

独立复核覆盖全部 687 个拟公开文件，包括新增治理 / 工作流与唯一二进制图示：已知实名、个人邮箱、真实公司与业务文件名无残留，未找到实际内网地址、可用凭据、私钥或真实业务身份。合成测试路径、参数名和占位符已人工分类；公开署名、package、bundle 与签名识别码按其功能保留。原始 Git 历史没有公开。

高可信 secret 检查扫描 687 个追踪文件通过，scanner 自检通过；畸形 PEM 标头后接 10,000 个空白的负例在 0.001 秒内拒绝。广泛 warning-only 扫描仍有 10 个已解释的合成路径 / 模板 / 参数名命中，不等同零命中，也不把扫描器当成完整安全证明。

## GitHub 实际设置

以下已通过 API 写入并重新读取验证，不只是文档目标：

- `main-owner-review`（ruleset `25370501`）：active，精确作用于 `refs/heads/main`；必须 PR、至少 1 个 approval、强制 CODEOWNER review，追加提交使旧批准失效，评审对话必须解决，只允许 squash。
- `.github/CODEOWNERS` 全库唯一 owner 为 `@sunkailun1992`，GitHub 解析错误数为 0。
- owner 的管理员例外仅限 `pull_request`，没有可直接推送的 `always` 例外。GitHub 不允许作者 approve 自己的 PR，owner 自己的 PR 需本人审查后亲自决定；AI 不能把凭据权限当成本人批准。
- 独立 `main-integrity-and-ci`（ruleset `25370504`）：active，无任何 bypass；禁止删除 / 强推，要求 GitHub Actions 的 `swift` 与 `secrets`，并要求跟上最新 base。实际 check 名与集成已核实。
- Actions 默认 token 只读，不允许工作流 approve PR；所有外部贡献者的工作流执行需维护者批准。CI 不访问真实客户端或配置，不签名、安装或发布。
- 仅允许 squash merge，合并后删工作分支，自动合并关闭。
- 私密漏洞报告、Dependabot 安全更新、secret scanning 与 push protection 已启用。首次自动依赖 PR 的状态实读为 `REVIEW_REQUIRED` / `BLOCKED`，没有自动合入。
- 新启用的依赖扫描报出 Java 消费方示例的 13 条既有 Jackson 告警（5 high / 8 medium），均位于 `examples/java-consumer/pom.xml`。自动 [PR #1](https://github.com/sunkailun1992/imctl/pull/1) 仅把 `jackson.version` 从 2.18.2 升至 2.18.11，逐项覆盖 13 条告警的最低修复版本；尚未合并。该 POM 不参与 Mac App 构建。本机没有 Maven / wrapper，未声称已完成 Java 测试；Swift CI 也不能代替 Java 验证。

## 构建、安装与功能

- 本机 `swift build`、1,183 个非 live 测试 / 158 个套件、额外协议与禁用 API 守卫全部通过。群名修复细节见 [专门门报告](2026-10-19-group-rename-early-apply.md)。没有移除其他功能或修改其配置格式。
- 从公开初始提交的完整源码构建 release App，显式选择本机原有有效签名证书；三个二进制的指定签名条件与旧版相同，签名严格校验通过。构建脚本的默认选择码未匹配当前证书，不代表需要新增证书。
- 旧 App 已移除，新版安装到原位置；控制台打开，原 LaunchAgent 参数保持，守护进程仍启用 MQTT。
- 已安装 CLI / daemon / console 与公开源码构建产物的二进制哈希逐一一致。App 为 `1.0.18` / build `1`，守护进程为 `1.0.18-dev`；build 重新计数来自新的干净 Git 历史。
- 原有配置文件内容哈希一致；没有复制密钥到仓库、删除运行数据或修改 TCC 数据库。
- 新版离线体检 `ready:true`：daemon、企微读取、辅助功能、屏幕录制、MQTT、视觉 / OSS 配置和智能体接入正常。未配置的官方 API、未启用的自动接受功能继续保持原状态。
- 上述体检为本地状态核对。随后用户批准测试群改名后恢复共 2 次动作；首次请求的 prepare 模型返回 stop，checkpoint 为 0、群名未变。同键回放返回同一记录，没有换键重试或关闭守卫。模型进行 1 次现有许可范围内的单帧观察，另做只读画面核对；没有截图入库、发送消息或加人。真实改名后验分支尚未触发，不能声称通过。

## 首次云端 CI 与排程修正

[首次公开 CI](https://github.com/sunkailun1992/imctl/actions/runs/39193799853) 的 secrets 和 Swift build 通过，1,183 项测试执行完成，但 9 项测试 / 11 个 issue 因背景佇列与短时间上限失败。本次群名 B37 全套 16 项通过，不能因此把云端全套写成通过。许多快测同时耗时约 51 秒，失败集中于 readiness、MCP、MQTT 与 socket 的背景探针，首要怀疑是共享 runner 上大量测试并行导致排程压力。

本 PR 将 CI 的测试命令改为 `swift test --no-parallel`，按 [Swift Testing 官方说明](https://developer.apple.com/documentation/testing/parallelization) 关闭不同测试间的并行；每项测试本身的并发探针、超时和断言保持不变，不跳过任何测试，不改运行时实现。本机默认并行全套已通过；串行与后续云端结果以 PR checks 为准。此项变更与验收记录通过 PR 由本人审核，未绕过 main 规则。


第二次 [串行 CI](https://github.com/sunkailun1992/imctl/actions/runs/39194672251) 证实原 9 项失败全部消失，1,183 项仍完整执行，仅剩 FileFetcher 的 URLProtocol 取消观察顺序问题：生产方法等待的 URLSession delegate 与测试检查的 stopLoading 不是同一事件，锁住数组不能保证取消回呼已完成。本 PR 再为测试 stub 增加按 URL 的 NSCondition 通知，测试在同一个原 16 秒总界限内等 start / cancel，不增加 sleep、不放宽超时、不修改正式下载实现，保留错误、取消、清空及总耗时全部断言。定向 12 项 FileFetcher 测试已通过；新 head 的全套与 CI 仍需重新核对。用户仅批准过旧 head `072936c`，新 head 需要本人重新审查后才可合并。
