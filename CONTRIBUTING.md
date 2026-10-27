# 参与贡献

欢迎提交问题、文档、测试和功能修复。中文或英文均可。外部贡献通过分支和 pull request 进入 `main`，由 [@sunkailun1992](https://github.com/sunkailun1992) 本人审核；维护者本人与维护者本机的 AI 会话可以直接合并，规则见 [MAINTAINERS.md](MAINTAINERS.md)。公开源代码不会授予任何人直接修改主分支的权限。

## 开始之前

- 先读 [README.md](README.md)、[AGENTS.md](AGENTS.md) 和 [AI 编码规范](docs/ai-coding/README.md)。安全边界适用于人工和 AI 贡献。
- 小型文档修正、范围明确的 bug 修复可以直接开 PR。新功能、大范围重构、协议变化或极高风险修改，先开 issue 说明问题与方案，等维护者确认。
- 极高风险包括：按键或权限面、目标白名单与策略、checkpoint / `unknown`、视觉数据外传、凭据、MQTT 传输守卫、代理与回调验签。具体分级见 [工程门禁](docs/ai-coding/AI_ENGINEERING_GUARDRAILS.md)。不能为了通过测试而放宽安全限制。
- 开发所需规则、决策和证据应在仓库或当前 issue / PR 中提供。私人 wiki 和特定 AI 插件不是参与贡献的前提；缺少依据时向维护者确认，不猜测授权。

## 开发环境

Swift 主程序需要 macOS 15+、Xcode 命令行工具和 Swift 6.2+。`Package.swift` 声明工具版本 6.0，但当前 `Package.resolved` 中的依赖要求 6.2+。已记录的开发基线是 Xcode 26.6 / Swift 6.3.3，Swift 语言模式为 5。

```bash
git clone https://github.com/<your-user>/imctl.git
cd imctl
swift --version
swift build
IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test
```

普通测试使用 fake AX、假传输和合成数据，不需要企业微信、真实 MQTT broker、API 密钥或系统权限。首次解析 SwiftPM 依赖需要联网。不要为运行单元测试安装守护进程或开启云端视觉。

修改 Java 或 Python 子项目时，也要执行相应目录 README 中的测试。这些子项目不会被 `swift test` 覆盖：

- [Java 消费方](examples/java-consumer/README.md)：在该目录执行 `mvn -q test`，需要 Java 17 和 Maven。
- [令牌代理](proxy/wecom-token-proxy/README.md)：在该目录执行 `mvn -q test`，需要 Java 17 和 Maven。
- [协议模拟器](examples/protocol-sim/README.md)：在该目录执行 `python3 -m unittest discover -s tests -t .`，内存总线测试只用 Python 标准库。

## 验证与真实客户端

提交前至少执行：

```bash
swift build
IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test
bash scripts/check-secrets.sh
git diff --check
```

`scripts/check-secrets.sh` 是广泛的告警扫描，正常退出不代表没有泄漏；必须逐条判断命中，且它只覆盖 Git 已追踪的文件。提交新文件前同时人工检查文件内容。CI 的 `secrets` 检查另外拒绝特定高可信密钥格式和私钥，命中只报文件、行号及规则名；它不识别所有凭据或个人信息，也不检查公开 issue、评论和截图。

CI 的 `swift` 检查在 GitHub 托管的 `macos-latest` 上构建并执行非活体测试。两个 live 开关均为 `0`，不使用仓库 secrets，不签名、不安装、不发布，也不接触真实客户端。检查名称与规则集的实际状态见 [MAINTAINERS.md](MAINTAINERS.md)。

真实客户端测试需要单独授权、自己的测试账号和策略允许的目标，按 [测试规范](docs/ai-coding/TESTING_SPEC.md) 执行。发送、接受申请、建群或改名等真实动作，先确认具体目标与次数；不使用真实客户或客户群。视觉实测还需对应开关、密钥和数据上传范围的明确授权。无法实测就写「待活体」及原因，不把 fake 或 CI 当作真实验收。

## 分支、提交与 PR

1. 外部贡献者 fork 仓库，从最新 `main` 切出 `feat/<主题>`、`fix/<主题>` 或 `docs/<主题>` 等分支。已有写权限的协作者也使用工作分支，不直接推 `main`。
2. 一个 PR 处理一个明确问题。提交信息和 PR 标题用英文 Conventional Commits，例如 `fix(adapter): verify the original group after rename`；PR 正文可用中文或英文。
3. 按 [PR 模板](.github/pull_request_template.md) 写问题、修改结果、风险、检查结果和未验收项。草稿 PR 可以提前开。
4. 新协议方法、事件字段、错误码或 topic 必须同一 PR 更新 [权威协议](docs/protocol/im-control-protocol.md) 与对应测试。行为变化同步相关文档；贡献者不自行升发布版本。
5. 合并条件：CI 全绿、维护者审核确认是有益的改动并批准、评审对话全部解决，然后由维护者 squash 合并；追加新提交需要重新审核。维护者本人与维护者本机的 AI 会话可以直接合并，目标设置见 [MAINTAINERS.md](MAINTAINERS.md)。

开工、提交前和推送前先 `git fetch`。未推送的本地提交可以 rebase 到最新上游并重跑验证；已推送的分支通过追加提交或合并 `main` 跟进，禁止强推（包括 `--force-with-lease`）。遇到无法解决的冲突、他人的未提交改动或分叉时报告，不覆盖他人工作。

## 使用 AI

欢迎使用 AI 辅助，你仍需审查并负责全部提交。在 PR 中说明 AI 是否参与；协作署名只写实际参与的模型。

AI 可以阅读、修改工作分支、执行测试、提交修复和开 PR，不代替 @sunkailun1992 本人 approve，也不伪造审核。维护者本机用维护者账号运行的 Claude / Codex 会话可以直接合并到 `main`（本机验证全过、合并后看 CI）；云端会话只推 `claude/<主题>` 分支。直接合并不授权更改 GitHub 权限、规则集、发布状态、真实客户端动作或安装，这些操作仍分别需要本人明确授权。

## 公开内容与安全问题

代码、文档、夹具、issue、PR、日志和截图都不能含真实凭据、broker / 内网地址、个人联系方式、真实联系人或消息正文、本机绝对路径。使用 `测试联系人A`、`示例公司`、`示例文档.pdf`、`<repo-root>` 等合成值；不要把可用密钥格式当测试数据。

AX 树里的菜单也可能有动态账号名和最近文件名；默认脱敏不能代替人工复核。截图须检查整个画面，包括其他会话预览。发现安全问题按 [SECURITY.md](SECURITY.md) 私下报告，先撤销已泄漏凭据，不在公开 issue 重贴原值。

## 许可证

提交贡献表示你有权提交该内容，并同意按本项目的 [Apache-2.0](LICENSE) 授权。第三方内容需保留原有授权及署名，不需要另签 CLA。
