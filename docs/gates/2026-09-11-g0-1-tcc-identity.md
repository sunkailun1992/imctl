# 门 G0-1：TCC 身份跨重建稳定（2026-09-11）— 通过

## 方法

- 签名：`scripts/build-signed.sh`，身份 = 本机已有 Apple Development 证书（team 查找 `JVL9CBM345`；codesign 报告 `TeamIdentifier=FCZGS779KT`），`--identifier com.sunkailun.imctl`，无 hardened runtime、无 entitlements。
- Designated requirement：`identifier "com.sunkailun.imctl" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: <email> (JVL9CBM345)" and certificate 1[field.1.2.840.113635.100.6.2.1]`。
- 授权：`imctl permission --prompt --open-settings` 一次，用户在辅助功能列表勾选 `imctl`（14:10 CST 前完成）。
- 验证：每轮改 `IMCTLVersion.string` 使机器码变化 → 重建重签 → `imctl permission`（不带 `--prompt`）。

## 结果

| 轮 | 版本串 | CDHash | `imctl permission` |
|---|---|---|---|
| 0（授权时） | 0.1.0-dev | （加 `--root` 前的构建） | trusted |
| 0'（加 `--root` 后） | 0.1.0-dev | — | trusted，无弹窗 |
| 1 | 0.1.0-dev+g01r1 | 5b7eadcd… | trusted，无弹窗 |
| 2 | 0.1.0-dev+g01r2 | 3bb5c025… | trusted，无弹窗 |
| 3 | 0.1.0-dev+g01r3 | d41b5686… | trusted，无弹窗 |
| 恢复 | 0.1.0-dev | 5c562122… | trusted，无弹窗 |

对照：ad-hoc 签名时标识符为 `imctl-<内容哈希>`，每次重建都会变（`imctl env` 的 `signing:` 行可见）。

## 结论与保留

- 通过：同一 DR 下 5 个不同 CDHash 均无需重新授权。
- 保留：本次进程由 Claude 桌面应用的子进程启动；LaunchAgent 形态下 TCC"责任进程"归属需在阶段 2 复验。TCC.db 本身不可读（authorization denied），结论以 `AXIsProcessTrusted` 为准。
- 与路线页差异：未自建 `imctl-dev` 证书，直接用已有 Apple Development 身份；Developer ID 仍按计划在阶段 1 结束前申请。
