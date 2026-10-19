# S4 开发期签名与 TCC 身份（门 G0-1）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `imctl` 二进制在每次重建后保持同一个代码签名身份，辅助功能授权只弹一次（门 G0-1）。

**Architecture:** SwiftPM 产物默认 ad-hoc 签名，标识符是内容哈希（`imctl-5555…`），每次重建都变，TCC 视为新程序。修法是构建后用稳定证书重签并固定 `--identifier com.sunkailun.imctl`。路线页原计划自建 `imctl-dev` 证书；本机已有两张 Apple Development 证书，用与本账号对应的一张（team `JVL9CBM345`）——链可信、无需 sudo、无需 GUI 信任步骤，且 designated requirement 同样稳定。证书名不入库，脚本按 team id 查找。

**Tech Stack:** `codesign`、`security find-identity`、bash。

## Global Constraints

- 不申请 hardened runtime 之外的任何 entitlement；不申请录屏/输入监控。
- 脚本不含证书 SHA-1、邮箱或私钥；team id 允许。
- 授权动作（在系统设置里勾选）由用户完成，助手只触发提示与打开设置页。

---

### Task 1: 签名脚本

**Files:**
- Create: `scripts/build-signed.sh`
- Modify: `README.md`（构建段加签名说明）

**Interfaces:**
- `scripts/build-signed.sh [debug|release]`：`swift build -c <cfg>` → 查找身份（`IMCTL_SIGN_IDENTITY` 优先，否则 `security find-identity -v -p codesigning` 中含 `IMCTL_SIGN_TEAM`（默认 `JVL9CBM345`）的第一条）→ `codesign --force --sign <identity> --identifier com.sunkailun.imctl --timestamp=none <bin>` → `codesign -dv --verbose=2` 断言 `Identifier=com.sunkailun.imctl` 且 `Signature=` 非 adhoc → 打印二进制路径。

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# Build imctl and re-sign it with a stable identity so TCC (Accessibility)
# recognises the same program across rebuilds. Usage: scripts/build-signed.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CFG="${1:-debug}"
IDENT_ID="com.sunkailun.imctl"
TEAM="${IMCTL_SIGN_TEAM:-JVL9CBM345}"

swift build -c "$CFG" >/dev/null
BIN="$(swift build -c "$CFG" --show-bin-path)/imctl"

if [[ -n "${IMCTL_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$IMCTL_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning | grep "($TEAM)" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "no code-signing identity for team $TEAM; set IMCTL_SIGN_IDENTITY" >&2
  exit 1
fi

codesign --force --sign "$IDENTITY" --identifier "$IDENT_ID" --timestamp=none "$BIN"
INFO="$(codesign -dv --verbose=2 "$BIN" 2>&1)"
grep -q "^Identifier=$IDENT_ID$" <<<"$INFO" || { echo "identifier mismatch:"; echo "$INFO"; exit 1; }
grep -q "^Signature=adhoc" <<<"$INFO" && { echo "still ad-hoc:"; echo "$INFO"; exit 1; }
echo "$BIN"
```

- [ ] **Step 2: 运行** `scripts/build-signed.sh` → 打印路径；`codesign -dv` 显示 `Identifier=com.sunkailun.imctl`、`Authority=Apple Development: …`；`imctl env` 的 `signing:` 行变为 `com.sunkailun.imctl (team: JVL9CBM345)`。
- [ ] **Step 3: 提交** `git commit -m "chore: add build-signed script for stable TCC identity"`

### Task 2: 触发授权（需用户）

- [ ] **Step 1:** `.build/debug/imctl permission --prompt --open-settings` → 系统弹"imctl 想要控制这台电脑"，同时打开系统设置 › 隐私与安全性 › 辅助功能。
- [ ] **Step 2:** 用户在列表中勾选 `imctl`（路径 `.build/debug/imctl`）。
- [ ] **Step 3:** `.build/debug/imctl permission` 退出码 0。

### Task 3: G0-1 三次重建验证

- [ ] **Step 1:** 循环三次：改动 `Sources/ControlCore/IMCTLVersion.swift` 注释 → `scripts/build-signed.sh` → `imctl permission`（不带 `--prompt`）→ 记录退出码与 `codesign -dv` 的 `CDHash`（每次不同）。
- [ ] **Step 2:** 三次都为 0 → 写 `docs/gates/2026-09-11-g0-1-tcc-identity.md`（身份、DR、三次 CDHash、结论）。否则记录失败并改走 Developer ID 申请。
- [ ] **Step 3:** 提交 `git commit -m "docs(gates): G0-1 TCC identity stable across rebuilds"`

**注意：** TCC 的"责任进程"规则——从 Claude/终端里启动的子进程可能被归到父应用。G0-1 的结论以 `imctl` 自己的条目为准；S7 前还要在 LaunchAgent 形态下复验（阶段 2）。

## 执行结果（2026-09-11）

- 3 个任务完成；G0-1 通过，报告 `docs/gates/2026-09-11-g0-1-tcc-identity.md`。首轮循环用"追加注释"导致 CDHash 不变，已改为改版本串重跑。
