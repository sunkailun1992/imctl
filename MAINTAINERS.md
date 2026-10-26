# 维护与合并规则

## English summary

- Maintainer: @sunkailun1992 (repository admin and the only code owner).
- The maintainer and the maintainer's own local Claude/Codex sessions may merge to `main` directly after the local checks pass, then watch CI. Cloud sessions push `claude/…` branches only. Everyone else opens a PR that needs CI green, the maintainer's review and approval, and every review conversation resolved.
- Only squash merges; no force pushes or deletions of `main`; agents never change the ruleset or repository permissions.
- Merging never implies running the real WeCom client, installing services, turning on cloud vision or publishing a release; each needs its own explicit approval.

## 名单

| GitHub | 角色 |
|---|---|
| [@sunkailun1992](https://github.com/sunkailun1992) | 仓库管理员、维护者、全库代码所有者 |

`.github/CODEOWNERS` 将全库交由 @sunkailun1992 负责，包括协作规则与工作流本身。新增其他代码所有者、协作者或管理员，须由本人明确决定；被授予 write 权限也不代表可以绕过本人审核。

## 合并规则

- 维护者本人，以及维护者本机用维护者账号运行的 Claude / Codex 会话，可以直接合并到 `main`：合并前本机验证命令全过（`swift build`、`IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test`、`bash scripts/check-secrets.sh` 逐条判断、`git diff --check`），合并后看 CI，红了马上修。
- 云端会话只推 `claude/<主题>` 分支，由维护者或本机会话审过后合并。
- 其他人的 PR（含被授予 write 权限的协作者）：CI 全绿、维护者审核确认是有益的改动并批准、评审对话全部解决之后，由维护者 squash 合并；追加可审查的新提交后重新审核。
- 只允许 squash；禁止强推和删除 `main`；任何代理都不得修改 ruleset 或仓库权限。AI 不代替本人 approve，不伪造审核。
- 直接合并只省掉 PR 这一步，不省掉验证、门报告和用户决定：发送路径、策略与白名单、按键、权限面、视觉上传、凭据等极高风险改动，仍按 [工程门禁](docs/ai-coding/AI_ENGINEERING_GUARDRAILS.md) 先取得用户决定、补活体门报告。

## GitHub 目标设置

下表记录目标策略。文档和 `CODEOWNERS` 本身不能开启分支保护；实际生效的内容以 [GitHub Rules](https://github.com/sunkailun1992/imctl/rules) 和仓库 Settings 为准，由维护者本人设置后核对。

| 项目 | 目标 |
|---|---|
| 分支 | `main`，规则 active |
| 进入方式 | 其他人必须 PR；仓库管理员设为「始终绕过」，供维护者本人与本机 AI 会话直接合并 |
| 审核 | 其他人的 PR 至少 1 个 approval，并强制代码所有者批准；全库 CODEOWNER 只有 @sunkailun1992 |
| 新提交 | 其他人 PR 的旧批准作废；评审对话全部解决 |
| 合并方式 | 只允许 squash |
| CI | `.github/workflows/ci.yml` 的 `swift` 与 `secrets` 设为必需检查；直接合并后也要看结果 |
| 强推与删除 | 禁止强推和删除 `main`；不使用 `--force` 或 `--force-with-lease` |
| 发布 | 只有本人另行批准的具体版本才可发布；CI 不签名、安装或发布 |

`CODEOWNERS` 自动请求审核与「强制代码所有者批准」是两项设置，必须同时具备；只有「1 个 approval」不能保证是本人批准。「始终绕过」只用于维护者一侧的直接合并，不用于强推、删除或跳过他人改动的审核。

## 安全与发布

安全问题按 [SECURITY.md](SECURITY.md) 私下报告。公开 issue、PR、验收记录和安装包均需脱敏；发布前核对源代码、测试结果、包内容、签名与权限说明。运行真实企微、安装常驻服务或开启云端视觉属于单独授权的本机操作，不因合并或 CI 通过而自动执行。
