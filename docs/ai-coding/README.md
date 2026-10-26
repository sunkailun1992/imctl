# AI 编程指导目录

本目录集中维护 `imctl` 的 AI 编程规范。根目录 `AGENTS.md` 只保留 AI 工具入口和最高优先级安全边界；本目录保存可持续维护的细分规范。结构与同级 Java / iOS 仓库的 `docs/ai-coding/` 一致，内容按 Swift / SwiftPM、Accessibility 控制、MQTT 边缘接入和"对真实客户端做活体验收"的场景重新收敛。

## 目录职责

```text
AGENTS.md
  -> docs/ai-coding/README.md
    -> AI_CODING_GUIDE.md
    -> AI_DIRECTORY_STRUCTURE_GUIDE.md
    -> AI_COMMENT_STYLE_GUIDE.md
    -> AI_DESIGN_PATTERN_GUIDE.md
    -> AI_ENGINEERING_GUARDRAILS.md
    -> SECURITY_CODING_SPEC.md
    -> TESTING_SPEC.md
    -> AI_AUTOMATION_WORKFLOW.md
```

- `AGENTS.md`：仓库级 AI 入口，适合 Codex、Claude Code、Copilot agent 等支持 AGENTS 文件的工具读取。
- `.github/copilot-instructions.md`：GitHub Copilot 仓库级入口，只做轻量转发，避免和 `AGENTS.md` 冲突。
- `AI_CODING_GUIDE.md`：项目分层、命令管线、策略层次、运行数据、协议变更规则、版本 / 分支 / 提交规则。
- `AI_DIRECTORY_STRUCTURE_GUIDE.md`：SwiftPM target、子目录、夹具、文档、脚本、计划中的 `WeComAPI` / 代理 / Java 示例的归属。
- `AI_COMMENT_STYLE_GUIDE.md`：Swift `///` 文档注释与实现注释、带日期的客户端事实、Shell、Markdown、JSON 夹具、plist、Java（代理 / 消费方）的注释规范。
- `AI_DESIGN_PATTERN_GUIDE.md`：`AXBackend` 端口与 Fake、策略对象、命令管线状态机、快照 diff、传输绑定等既有模式和禁止过度抽象规则。
- `AI_ENGINEERING_GUARDRAILS.md`：风险分级、Definition of Done、必须检查项、AI 工具边界和交付说明模板。
- `SECURITY_CODING_SPEC.md`：合成输入与权限面、白名单与策略、不可逆点与幂等、secret 与运行数据、日志正文、传输 / 代理 / 回调、输入信任、AI 边界的安全规则。
- `TESTING_SPEC.md`：单元 / 守卫 / live / 混沌 / 活体门报告的分层，夹具录制与脱敏，门报告模板。
- `AI_AUTOMATION_WORKFLOW.md`：一个批次从规格到 PR 的标准流程与多智能体分工；维护者可另行归档私人 wiki。

版本、分支与提交规则折叠在 `AI_CODING_GUIDE.md` 第 10–11 节，不单独成文；规模变大再拆。

## 阅读顺序

任何 AI 修改代码前必须先读：

1. 根目录 `AGENTS.md`
2. 本文件
3. `AI_CODING_GUIDE.md`
4. `AI_DIRECTORY_STRUCTURE_GUIDE.md`
5. `AI_COMMENT_STYLE_GUIDE.md`
6. `AI_DESIGN_PATTERN_GUIDE.md`
7. `AI_ENGINEERING_GUARDRAILS.md`
8. `SECURITY_CODING_SPEC.md`
9. `TESTING_SPEC.md`
10. `AI_AUTOMATION_WORKFLOW.md`
11. 当前批次的规格（`docs/superpowers/specs/`）、计划（`docs/superpowers/plans/`）、既有门报告（`docs/gates/`）
12. 目标 Swift 文件及其上下游（协议类型 → 执行器 → 处理器 → 动作 → 传输 → 守护进程 / CLI）

涉及发送路径、策略与白名单、`KeystrokeInjector`、TCC / 签名 / LaunchAgent、MQTT 凭据 / ACL、代理与回调、事件语义时，不得只读摘要文件，必须继续阅读真实代码、门报告和仓库规格 / issue / PR 中的用户决定。私人 wiki 可由维护者补充脱敏依据，不要求外部贡献者访问；缺少授权依据时向维护者确认。

## 维护规则

- 新增 AI 规范优先放入本目录，不再把细分规范堆到仓库根目录。
- 根目录只保留 `AGENTS.md` 作为跨工具入口；工具专用入口只写在工具约定目录，例如 `.github/copilot-instructions.md`。
- 同一规则只保留一个主版本，其他入口通过链接指向主文件；`README.md` 的硬规则与本目录冲突时以本目录为准并同步修正 `README.md`。
- 规范文档、门报告与 wiki 不得含 broker 地址、凭据、企微应用参数、代理 token、真实联系人标题或正文；示例一律用 `<PLACEHOLDER>`、`文件传输助手` 或合成夹具里的名字。
- 不写本机绝对路径（`/Users/<name>/…`、外盘挂载点）；需要表达目录关系时用相对路径、`~/Library/…` 或 `<REPO>`。
- 只做目录整理、README 或规范调整时，不提升 `IMCTLVersion`。
- 发现疑似密钥、broker 地址或真实联系人内容时，只报告文件与行号，不自动替换或改写 git 历史（是否改写历史由用户决定）。
- 规范更新和代码修改可以同一次提交，但交付说明必须区分"工程规范"和"运行时改动"。
- 维护者本人与维护者本机的 Claude / Codex 会话可以直接合并到 `main`（本机验证全过、合并后看 CI）；云端会话只推 `claude/<主题>` 分支；其他人走 PR，由 @sunkailun1992 本人审核批准。AI 不代替本人 approve。流程见根目录 `CONTRIBUTING.md` 和 `MAINTAINERS.md`。

## 当前标准布局

```text
.
├── AGENTS.md
├── README.md
├── Package.swift
├── .github
│   └── copilot-instructions.md
├── Sources/<Target>/…
├── Tests/<Target>Tests/…  Tests/Fixtures/ax-trees/*.json
├── scripts/
└── docs
    ├── ai-coding/           本目录
    ├── superpowers/specs/   设计规格（口径）
    ├── superpowers/plans/   代码级 TDD 计划
    ├── gates/               阶段 / 批次门报告（实测）
    ├── ops/                 运维（LaunchAgent、EMQX 凭据与 ACL）
    └── protocol/            Java 消费方契约
```

## 参考依据

- [OpenAI Codex 文档](https://developers.openai.com/codex)：`AGENTS.md` 用于项目级代理指令与操作约束。
- [GitHub Copilot 仓库级自定义指令](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions)：`.github/copilot-instructions.md`。
- [Swift Package Manager 文档](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/)：target / testTarget / 资源目录约定。
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)、[Swift-DocC 标记](https://www.swift.org/documentation/docc/)：命名与文档注释。
- 历史模板来自同级仓库 `quantitative-trading-ai`、`utils`、`BTCQuantAI` 的 `docs/ai-coding/`；本目录已保存 imctl 所需规则，外部贡献者不依赖这些仓库。
