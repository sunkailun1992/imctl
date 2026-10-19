## 问题与修改结果

<!-- 写清触发场景、修改前后行为和原因。PR 标题使用英文 Conventional Commits。 -->

## 关联 issue

<!-- 例如 Closes #123；无关联写「无」。 -->

## 风险与范围

<!-- 按 docs/ai-coding/AI_ENGINEERING_GUARDRAILS.md 标明低 / 中 / 高 / 极高风险。
说明是否改变协议、策略、checkpoint、权限、视觉上传、运行数据或安装方式。 -->

## 验证

- [ ] `swift build`
- [ ] `IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test`
- [ ] `bash scripts/check-secrets.sh`，已逐条人工判断告警
- [ ] `git diff --check`
- 涉及的 Java / Python 子项目检查：
- 真实客户端验证结果，或「待活体」及原因：
- 若有真实动作：已授权的测试目标代称、动作 / 发送次数、客户端证据：

## 自查

- [ ] 未绕过策略、目标复核、幂等、checkpoint、`unknown`、速率或传输守卫
- [ ] 代码、文档、夹具、日志和截图不含凭据、个人信息、真实联系人 / 消息、内网地址或本机路径
- [ ] 动态菜单账号名、最近文件名、其他会话预览也已检查并脱敏
- [ ] 行为或协议变化已同步文档与必要测试；未验收的内容仍标明未验收
- [ ] 如含 AI 生成内容，我已逐行审查并对提交负责

<!-- 本 PR 必须由 @sunkailun1992 本人审核。AI 不得代替本人 approve，
未经本人对具体 PR / 版本的明确批准不得合并。安全问题按 SECURITY.md 私下报告。 -->
