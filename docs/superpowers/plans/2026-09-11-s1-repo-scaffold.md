# S1 仓库脚手架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 imctl 的 SwiftPM 单包仓库：`Package.swift`、四个 target 骨架、禁用 API 守卫测试、README、设计规格移植，并推送到私有远端 `sunkailun1992/imctl`。

**Architecture:** 单包多 target：`ControlCore`（协议与状态机，无 AX/网络）、`AXKit`（通用 AX 原语）、`WeComAdapter`（企微解析）、`imctl`（CLI）。S1 只放最小可编译内容与一个"禁止 `CGEvent`"的源码扫描测试，让硬约束从第一个提交起就由 `swift test` 守着。

**Tech Stack:** Swift 6.3.3 / swift-tools-version 6.0 / Swift 5 语言模式 / macOS 15+ / Swift Testing / swift-argument-parser 1.8.2（GRDB 7.11.1、MQTT-NIO 2.13.0 已解析，按阶段加入）。

## Global Constraints

- `swiftLanguageModes: [.v5]`，`platforms: [.macOS(.v15)]`，`swift-tools-version: 6.0`。
- 任何 `Sources/` 文件出现 `CGEvent` 视为违规，测试拦截。
- 不申请录屏 / 输入监控权限；权限面只有辅助功能。
- 仓库不含 secret、凭据、真实联系人内容。
- 提交信息带 `feat/fix/test/docs/chore` 前缀与 `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`。
- 远端 `github.com/sunkailun1992/imctl` 私有；本地 `<repo-root>`。

---

### Task 1: Package.swift 与四 target 骨架

**Files:**
- Create: `Package.swift`
- Create: `Sources/ControlCore/IMCTLVersion.swift`
- Create: `Sources/AXKit/AXKit.swift`
- Create: `Sources/WeComAdapter/WeComAdapter.swift`
- Create: `Sources/imctl/IMCTL.swift`
- Test: `Tests/ControlCoreTests/IMCTLVersionTests.swift`

**Interfaces:**
- Produces: `ControlCore.IMCTLVersion.string: String`（"0.1.0-dev"），`IMCTLVersion.bundleIdentifier == "com.sunkailun.imctl"`。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ControlCoreTests/IMCTLVersionTests.swift
import Testing
@testable import ControlCore

@Suite("IMCTLVersion")
struct IMCTLVersionTests {
    @Test func versionIsDevPrerelease() {
        #expect(IMCTLVersion.string == "0.1.0-dev")
    }

    @Test func bundleIdentifierIsStable() {
        #expect(IMCTLVersion.bundleIdentifier == "com.sunkailun.imctl")
    }
}
```

- [ ] **Step 2: 写 Package.swift 与最小源码**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "imctl",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "imctl", targets: ["imctl"]),
        .library(name: "ControlCore", targets: ["ControlCore"]),
        .library(name: "AXKit", targets: ["AXKit"]),
        .library(name: "WeComAdapter", targets: ["WeComAdapter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(name: "ControlCore"),
        .target(name: "AXKit"),
        .target(name: "WeComAdapter", dependencies: ["AXKit", "ControlCore"]),
        .executableTarget(
            name: "imctl",
            dependencies: [
                "ControlCore", "AXKit", "WeComAdapter",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ControlCoreTests", dependencies: ["ControlCore"]),
        .testTarget(name: "AXKitTests", dependencies: ["AXKit"]),
        .testTarget(name: "WeComAdapterTests", dependencies: ["WeComAdapter"]),
    ],
    swiftLanguageModes: [.v5]
)
```

```swift
// Sources/ControlCore/IMCTLVersion.swift
public enum IMCTLVersion {
    public static let string = "0.1.0-dev"
    public static let bundleIdentifier = "com.sunkailun.imctl"
}
```

```swift
// Sources/AXKit/AXKit.swift
/// 通用 Accessibility 原语。S2 填充。
public enum AXKitModule {}
```

```swift
// Sources/WeComAdapter/WeComAdapter.swift
/// 企业微信 AX 树解析。S5 填充。
public enum WeComAdapterModule {}
```

```swift
// Sources/imctl/IMCTL.swift
import ArgumentParser
import ControlCore

@main
struct IMCTL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imctl",
        abstract: "IM Control Protocol controller for macOS (read-only by default).",
        version: IMCTLVersion.string
    )
}
```

空测试文件（让 test target 可编译）：`Tests/AXKitTests/Placeholder.swift` 与 `Tests/WeComAdapterTests/Placeholder.swift` 各含 `import Testing` 与一个 `@Test func compiles() {}`。

- [ ] **Step 3: 构建并跑测试**

Run: `swift build && swift test`
Expected: 编译通过，`IMCTLVersion` 两个测试 PASS。

- [ ] **Step 4: 提交**

```bash
git add Package.swift Sources Tests
git commit -m "feat: scaffold SwiftPM package with ControlCore/AXKit/WeComAdapter/imctl targets"
```

### Task 2: 禁用 API 守卫测试

**Files:**
- Create: `Tests/ControlCoreTests/ForbiddenAPITests.swift`

**Interfaces:**
- Consumes: 无。
- Produces: 任何 `Sources/**/*.swift` 含 `CGEvent`、`CGWarpMouseCursor`、`CGPostKeyboardEvent`、`IOHIDPostEvent`、`CGRequestScreenCaptureAccess`、`CGPreflightListenEventAccess` 即失败。

- [ ] **Step 1: 写测试（当前应通过，属于守卫）**

```swift
import Foundation
import Testing

@Suite("Forbidden API guard")
struct ForbiddenAPITests {
    static let forbidden = [
        "CGEvent", "CGWarpMouseCursor", "CGPostKeyboardEvent", "IOHIDPostEvent",
        "CGRequestScreenCaptureAccess", "CGPreflightListenEventAccess", "CGRequestListenEventAccess",
    ]

    static var sourcesRoot: URL {
        // .../Tests/ControlCoreTests/ForbiddenAPITests.swift -> package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test func sourcesNeverMentionSyntheticInputOrExtraTCC() throws {
        let fm = FileManager.default
        let enumerator = try #require(fm.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in Self.forbidden where text.contains(token) {
                hits.append("\(url.lastPathComponent): \(token)")
            }
        }
        #expect(hits.isEmpty, "Forbidden API usage: \(hits)")
    }
}
```

- [ ] **Step 2: 验证守卫会抓**

临时在 `Sources/AXKit/AXKit.swift` 加一行注释 `// CGEvent`，`swift test --filter ForbiddenAPITests` 必须 FAIL；删掉后再跑必须 PASS。

- [ ] **Step 3: 提交**

```bash
git add Tests/ControlCoreTests/ForbiddenAPITests.swift
git commit -m "test: guard Sources against synthetic input and extra TCC APIs"
```

### Task 3: .gitignore、README、贡献规则

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `docs/superpowers/specs/README.md`（规格目录索引）

- [ ] **Step 1: .gitignore**

```
.build/
.swiftpm/
DerivedData/
*.xcodeproj
*.xcworkspace
.DS_Store
/Tests/Fixtures/ax-trees/*.raw.json
/docs/gates/*.raw.*
*.p12
*.cer
*.mobileprovision
.env
```

- [ ] **Step 2: README.md**

内容：定位（一段）、硬规则（不合成键鼠 / 只申请辅助功能 / 白名单编译进代码 / 不向真实联系人发消息 / 仓库无 secret）、模块表、构建与测试命令、`IMCTL_LIVE=1` 说明、当前阶段（阶段 0 只读探针）、文档目录。

- [ ] **Step 3: 提交**

```bash
git add .gitignore README.md docs/superpowers/specs/README.md
git commit -m "docs: add README, gitignore and specs index"
```

### Task 4: 设计规格移植

**Files:**
- Create: `docs/superpowers/specs/2026-09-11-imctl-design.md`（从 wiki topic 页移植：定位、分层职责、协议 v0.1 草案、平台能力与路线、生命周期与本机环境、可替换机制、验证顺序、边界与禁区）
- Create: `docs/superpowers/specs/2026-09-11-imctl-roadmap.md`（从路线页移植：阶段门、v0.1 完成定义、模块表、首个冲刺、工程规则、风险回退）

规则：不写入任何 host/IP/secret；不复制 wiki 的证据索引与变更史；标注来源为 wiki 页名。

- [ ] **Step 1: 写两份规格**
- [ ] **Step 2: 提交**

```bash
git add docs/superpowers/specs
git commit -m "docs: port design spec and roadmap from wiki"
```

### Task 5: 推送私有远端

- [ ] **Step 1:** `gh repo create sunkailun1992/imctl --private --source . --remote origin --push`
- [ ] **Step 2:** `gh repo view sunkailun1992/imctl --json isPrivate,url` 应返回 `isPrivate: true`；`git log --oneline` 与远端一致。

## Self-Review

- 规格覆盖：Package/targets（T1）、CGEvent 拦截（T2）、gitignore/README（T3）、specs 移植（T4）、远端（T5）。GRDB/MQTT-NIO 按 YAGNI 不在 S1 引入，版本记入 README 与 wiki。
- 类型一致：`IMCTLVersion.string`/`bundleIdentifier` 在 T1 定义，CLI 引用同名。
