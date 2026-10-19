import Foundation

/// Pure rules from `ReadinessFacts` plus the last live results to a `ReadinessReport` (B52). The order of
/// `capabilities` is the order a person should fix things in; `nextStep` is the first `fail`'s fix.
public enum ReadinessEvaluator {
    /// The client version the recorded fixtures and gates cover. Other versions are not blocked.
    public static let calibratedClientVersion = "5.0.11"
    /// A watcher poll older than this is worth a warning (the timer polls every second).
    public static let staleWatchMs: Int64 = 15_000

    static let screenRecordingPane = #"open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture""#
    static let kickstartCommand = "launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl"
    static let restartDaemon = ReadinessFix(text: "这个配置是守护进程启动后才写入或改过的，重启守护进程才会生效（先确认没有命令在执行）",
                                            command: kickstartCommand, action: ReadinessAction(.restartDaemon))
    static let fullDiskAccessPane = #"open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles""#

    public static func evaluate(_ f: ReadinessFacts, online: [ReadinessProbeKind: ReadinessProbeResult],
                                info: ReadinessOnlineInfo, nowMs: Int64) -> ReadinessReport {
        let live = info.state == "done" ? online : [:]
        let daemon = daemonCapability(f)
        let wecom = wecomCapability(f)
        let read = readCapability(f, upstreamOK: daemon.status == .ok && wecom.status == .ok)
        let capabilities = [
            daemon, wecom, read,
            sendCapability(f, read: read.status),
            mediaCapability(f, read: read.status),
            contactAddCapability(f, read: read.status),
            autoAcceptCapability(f, read: read.status),
            visionCapability(f, live: live[.vision]),
            mqttCapability(f, live: live[.mqtt], nowMs: nowMs),
            ossCapability(f, live: live[.oss]),
            agentsCapability(f, live: live[.agents]),
            wecomApiCapability(f, live: live[.wecomApi]),
            healthCapability(f),
        ]
        let ready = capabilities.allSatisfy { $0.status == .ok || (!$0.required && $0.status == .disabled) }
        let first = capabilities.first { $0.status == .fail }
        return ReadinessReport(ready: ready, nextStep: first?.fix, nextStepCapability: first?.id,
                               capabilities: capabilities, online: info, version: f.version, generatedMs: nowMs,
                               build: f.runningBuild, runningCommands: f.runningCommands)
    }

    public static func categoryLabel(_ category: String?) -> String {
        switch category {
        case "timeout": "超时"
        case "network": "网络不通"
        case "auth": "认证被拒"
        case "http": "服务未接受请求"
        case "http4xx": "请求被拒（4xx）"
        case "http5xx": "服务端错误（5xx）"
        case "response": "应答格式不对"
        case "mismatch": "往返内容不一致"
        case "cleanup": "探测对象没删掉"
        case "rejected": "broker 拒绝发布"
        case "notConnected": "未连接"
        case "launch": "程序起不来"
        case "protocol": "握手应答不对"
        case "redirect": "发生了重定向"
        case "config": "配置读不了"
        case "internal": "内部错误"
        case let other?: other
        case nil: "未知"
        }
    }

    // MARK: Core

    static func daemonCapability(_ f: ReadinessFacts) -> ReadinessCapability {
        let manual = f.pauseReasons.filter { $0 != PauseReason.system.rawValue }
        var checks = [
            ReadinessCheck(id: "launchd", status: f.launchedByLaunchd ? .ok : .fail,
                           detail: f.launchedByLaunchd ? "由 launchd 常驻" : "不是由 launchd 启动（手动运行或调试）"),
            ReadinessCheck(id: "version", status: .ok, detail: f.version),
            ReadinessCheck(id: "paused", status: manual.isEmpty ? .ok : .fail,
                           detail: f.pauseReasons.isEmpty ? "未暂停" : "暂停原因：\(f.pauseReasons.joined(separator: ","))"),
        ]
        var stale = false
        if let running = f.runningBuild, let installed = f.installedBuild {
            stale = running != installed
            checks.append(ReadinessCheck(id: "build", status: stale ? .fail : .ok,
                                         detail: stale ? "守护进程在跑 build \(running)，已安装的是 build \(installed)" : "build \(running)，与已安装版本一致"))
        }
        var fix: ReadinessFix?
        if !f.launchedByLaunchd {
            fix = ReadinessFix(text: "守护进程不是由后台常驻启动的（手动运行或调试）：先停掉手动运行的那个，再安装后台常驻并请求授权",
                               command: "imctl setup", action: ReadinessAction(.setup))
        } else if stale {
            fix = ReadinessFix(text: "升级后守护进程还没重启：重启后才会用上新版本（先确认没有命令在执行）",
                               command: kickstartCommand, action: ReadinessAction(.restartDaemon))
        } else if manual.contains(PauseReason.api.rawValue) {
            fix = ReadinessFix(text: "守护进程被手动暂停（api）；确认可以恢复后执行", command: "imctl call controller.resume",
                               action: ReadinessAction(.resumeDaemon))
        } else if !manual.isEmpty {
            fix = ReadinessFix(text: "守护进程处于保护暂停（\(manual.joined(separator: ","))）；先看日志找原因", command: "imctl call controller.logs",
                               action: ReadinessAction(.openLogs))
        }
        return ReadinessCapability(id: "daemon", title: "守护进程", required: true, status: fix == nil ? .ok : .fail, checks: checks, fix: fix)
    }

    static func wecomCapability(_ f: ReadinessFacts) -> ReadinessCapability {
        var checks = [ReadinessCheck(id: "running", status: f.clientRunning ? .ok : .fail, detail: f.clientRunning ? "在运行" : "没有运行")]
        var warnings: [String] = []
        switch f.clientVersion {
        case calibratedClientVersion?:
            checks.append(ReadinessCheck(id: "version", status: .ok, detail: "\(calibratedClientVersion)（已校准）"))
        case let version?:
            checks.append(ReadinessCheck(id: "version", status: .ok, detail: "\(version)（未在此版本校准）"))
            warnings.append("企业微信 \(version) 未在此版本校准，能否使用以下面的可读性为准")
        case nil:
            checks.append(ReadinessCheck(id: "version", status: .unknown, detail: "读不到版本"))
        }
        let reachable: ReadinessCheck
        if !f.clientRunning {
            reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "企业微信没有运行")
        } else if !f.accessibilityTrusted {
            reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "要先授予辅助功能才能读取")
        } else if f.watch.clientAvailable == false {
            reachable = ReadinessCheck(id: "reachable", status: .fail, detail: "读不到企业微信主窗口，守护进程已暂停（system）")
        } else if let age = f.watch.lastPollAgeMs {
            if f.watch.lastPollOK {
                reachable = ReadinessCheck(id: "reachable", status: .ok, detail: "会话列表 \(f.watch.conversationCount) 行")
            } else if f.watch.clientAvailable == true {
                reachable = ReadinessCheck(id: "reachable", status: .ok, detail: "主窗口可达，当前不在「消息」页")
                warnings.append("企业微信当前不在「消息」页；读取会话前请切回「消息」")
            } else {
                reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "最近一次读取失败，正在重试")
            }
            if age > staleWatchMs { warnings.append("守护进程已有 \(age / 1000) 秒没有读到企业微信") }
        } else {
            reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "守护进程还没读过企业微信（刚启动）")
        }
        checks.append(reachable)
        let fix: ReadinessFix?
        if !f.clientRunning {
            fix = ReadinessFix(text: "打开企业微信并登录", command: "open -b com.tencent.WeWorkMac", action: ReadinessAction(.openWeCom))
        } else if reachable.status == .fail {
            fix = ReadinessFix(text: "把企业微信主窗口打开（不要最小化），切到左侧「消息」，几秒后重新体检", action: ReadinessAction(.openWeCom))
        } else {
            fix = nil
        }
        let status: ReadinessStatus = fix != nil ? .fail : (reachable.status == .unknown ? .unknown : .ok)
        return ReadinessCapability(id: "wecom", title: "企业微信", required: true, status: status, checks: checks, fix: fix, warnings: warnings)
    }

    static func readCapability(_ f: ReadinessFacts, upstreamOK: Bool) -> ReadinessCapability {
        let check = ReadinessCheck(id: "accessibility", status: f.accessibilityTrusted ? .ok : .fail,
                                   detail: f.accessibilityTrusted ? "imctld 已获辅助功能授权" : "imctld 没有辅助功能授权")
        guard f.accessibilityTrusted else {
            return ReadinessCapability(id: "read", title: "读取会话与历史", required: true, status: .fail, checks: [check],
                                       fix: ReadinessFix(text: "系统设置 › 隐私与安全性 › 辅助功能 里打开 imctl（列表里显示为「imctl 控制台」或 imctld）；新安装可直接执行。开关已开仍不生效（换过签名证书）：先在列表里删掉旧条目再执行", command: "imctl setup", action: ReadinessAction(.setup)))
        }
        return ReadinessCapability(id: "read", title: "读取会话与历史", required: true, status: upstreamOK ? .ok : .unknown, checks: [check])
    }

    static func sendCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        let p = f.policy
        var scope = "文件传输助手"
        if p.titleCount > 0 { scope += " + 会话 \(p.titleCount) 个" }
        if p.chatIdCount > 0 { scope += " + chatId \(p.chatIdCount) 个" }
        if p.externalUserIdCount > 0 { scope += " + externalUserId \(p.externalUserIdCount) 个" }
        if p.typesEnabled { scope += " + 按类型放行" }
        var warnings: [String] = []
        if p.allowAll { warnings.append("allowAll 已开启：任何会话都可发送") }
        if !p.readable { warnings.append("policy.json 读不了，只用内置白名单（文件传输助手）") }
        let check = ReadinessCheck(id: "allowlist", status: .ok, detail: p.allowAll ? "全部放开（allowAll）" : "可发送：\(scope)")
        return ReadinessCapability(id: "send", title: "发送消息", required: true, status: read == .ok ? .ok : .unknown,
                                   checks: [check], warnings: warnings)
    }

    static func mediaCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        let dataOK = f.wecomData == "granted"
        let checks = [
            ReadinessCheck(id: "screenRecording", status: f.screenRecordingGranted ? .ok : .fail,
                           detail: f.screenRecordingGranted ? "屏幕录制已允许" : "屏幕录制未允许"),
            ReadinessCheck(id: "wecomData", status: dataOK ? .ok : .fail, detail: "访问企微数据：\(wecomDataLabel(f.wecomData))"),
            ReadinessCheck(id: "fullDiskAccess", status: f.fullDiskAccess ? .ok : .fail,
                           detail: f.fullDiskAccess ? "完全磁盘访问权限已加" : "完全磁盘访问权限未加"),
        ]
        let fix: ReadinessFix?
        if !f.screenRecordingGranted {
            fix = ReadinessFix(text: "系统设置 › 隐私与安全性 › 屏幕与系统录音 里允许 imctl.app：列表里没有就从访达把 imctl.app 拖进去；开关已开仍不生效（换过签名证书）就删掉旧条目再加。系统提示重启时选「稍后」，再重启守护进程", command: screenRecordingPane, action: ReadinessAction(.openSystemSettings, target: "screenRecording"))
        } else if !dataOK {
            switch f.wecomData {
            case "pending": fix = ReadinessFix(text: "系统对话框「访问其他 App 的数据」还开着：点「允许」后重新体检")
            case "absent": fix = ReadinessFix(text: "找不到企业微信的数据目录：先打开并登录一次企业微信", action: ReadinessAction(.openWeCom))
            default: fix = ReadinessFix(text: "系统设置 › 隐私与安全性 › 完全磁盘访问权限 里加入 imctl.app 并打开（不弹框确认「访问企微数据」只能靠它）；开关已开仍不生效就删掉旧条目再加", command: fullDiskAccessPane, action: ReadinessAction(.openSystemSettings, target: "fullDiskAccess"))
            }
        } else {
            fix = nil
        }
        let status: ReadinessStatus = fix != nil ? .fail : (read == .ok ? .ok : .unknown)
        return ReadinessCapability(id: "media", title: "图片判向与取回", required: true, status: status, checks: checks, fix: fix)
    }

    static func wecomDataLabel(_ value: String) -> String {
        switch value {
        case "granted": return "已允许"
        case "denied": return "被拒绝"
        case "pending": return "系统对话框未处理"
        case "absent": return "数据目录不存在"
        default: return value.hasPrefix("unknown") ? "未确认（没有完全磁盘访问权限时不探测）" : "探测出错"
        }
    }

    // MARK: Optional, local

    /// User decision 2026-10-13: any number may be added; the hourly caps are the limits shown. While the policy
    /// file does not parse both caps are 0 (a broken file never widens anything), as with a policy that set both to 0.
    static func contactAddCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        guard f.policy.readable else {
            return disabled("contactAdd", "按手机号加人", detail: "策略文件无法解析，已暂停（坏文件不放宽任何东西）",
                            fix: ReadinessFix(text: "修好本机 policy.json 后自动恢复", command: "imctl policy list", action: ReadinessAction(.openPolicy, target: "phones")))
        }
        guard f.policy.maxAddsPerHour > 0 || f.policy.maxSearchesPerHour > 0 else {
            return disabled("contactAdd", "按手机号加人", detail: "已关闭（每小时上限都是 0）",
                            fix: ReadinessFix(text: "要按手机号加人，在本机调高上限", command: "imctl policy phones --max-per-hour 20 --max-searches-per-hour 60",
                                              action: ReadinessAction(.openPolicy, target: "phones")))
        }
        let check = ReadinessCheck(id: "phones", status: .ok,
                                   detail: "号码不限，每小时最多添加 \(f.policy.maxAddsPerHour) 次、搜索 \(f.policy.maxSearchesPerHour) 次")
        return ReadinessCapability(id: "contactAdd", title: "按手机号加人", required: false, status: read == .ok ? .ok : .unknown, checks: [check])
    }

    static func autoAcceptCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        guard f.policy.autoAccept != "off" else {
            return disabled("autoAccept", "自动接受好友申请", detail: "策略 autoAccept=off",
                            fix: ReadinessFix(text: "要自动接受好友申请，在本机打开策略", command: "imctl policy requests --auto-accept all", action: ReadinessAction(.openPolicy, target: "autoAccept")))
        }
        let mode = ReadinessCheck(id: "mode", status: .ok, detail: "策略 autoAccept=\(f.policy.autoAccept)")
        let rail: ReadinessCheck
        var fix: ReadinessFix?
        if let problem = f.watch.railProblem {
            rail = ReadinessCheck(id: "rail", status: .fail, detail: "通讯录角标无法归属：\(problem)")
            fix = ReadinessFix(text: "这台 Mac 的企业微信导航栏布局与已校准的不同，后台不会自动开始接受；下面的命令可查看布局，适配需要改代码", command: "imctl probe rail")
        } else if f.watch.railRead {
            rail = ReadinessCheck(id: "rail", status: .ok, detail: "通讯录角标已归属")
        } else {
            rail = ReadinessCheck(id: "rail", status: .unknown, detail: "还没读到导航栏")
        }
        let status: ReadinessStatus = fix != nil ? .fail : (read == .ok && rail.status == .ok ? .ok : .unknown)
        return ReadinessCapability(id: "autoAccept", title: "自动接受好友申请", required: false, status: status, checks: [mode, rail], fix: fix)
    }

    // MARK: Optional, live

    /// The live check of an enabled module: `tested:false` when this report has no result for it.
    static func liveCheck(_ id: String, _ result: ReadinessProbeResult?, ok okDetail: String) -> ReadinessCheck {
        guard let result else { return ReadinessCheck(id: id, status: .ok, detail: "未实测", tested: false) }
        return result.ok
            ? ReadinessCheck(id: id, status: .ok, detail: okDetail, tested: true, latencyMs: result.latencyMs)
            : ReadinessCheck(id: id, status: .fail, detail: "失败（\(categoryLabel(result.category))）", tested: true, latencyMs: result.latencyMs)
    }

    static func visionCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        let v = f.vision
        let setKey = "pbpaste | imctl vision set --provider \(v.provider) --secret-stdin"
        guard v.config.present else {
            return disabled("vision", "视觉兜底", detail: "未配置",
                            fix: ReadinessFix(text: "要用视觉兜底：把千问（或 Gemini）的密钥复制到剪贴板后执行；密钥只存本机",
                                              command: "pbpaste | imctl vision set --provider qwen --secret-stdin", action: ReadinessAction(.openSettings, target: "vision")))
        }
        guard v.config.valid else {
            return failure("vision", "视觉兜底", check: ReadinessCheck(id: "config", status: .fail, detail: "cloud-vision.json 读不了（目录须 0700、文件须 0600）"),
                           fix: ReadinessFix(text: "重新写入视觉配置", command: setKey, action: ReadinessAction(.openSettings, target: "vision")))
        }
        guard v.cloudEnabled else {
            return disabled("vision", "视觉兜底", detail: "云端视觉已关闭",
                            fix: ReadinessFix(text: "重新开启云端视觉（沿用已存的密钥）", command: "imctl vision set --provider \(v.provider)", action: ReadinessAction(.openSettings, target: "vision")))
        }
        let call = v.keyPresent ? liveCheck("call", live, ok: "模型应答正常")
                                : ReadinessCheck(id: "call", status: .unknown, detail: "没有密钥，未实测", tested: false)
        let checks = [
            ReadinessCheck(id: "provider", status: .ok, detail: "\(v.provider) · \(v.model)"),
            ReadinessCheck(id: "key", status: v.keyPresent ? .ok : .fail, detail: v.keyPresent ? "密钥已存" : "当前提供商没有密钥"),
            ReadinessCheck(id: "screenRecording", status: f.screenRecordingGranted ? .ok : .fail,
                           detail: f.screenRecordingGranted ? "屏幕录制已允许" : "屏幕录制未允许"),
            ReadinessCheck(id: "fullWindow", status: .ok, detail: v.fullWindowEnabled ? "整窗辅助已开启（仅显式桌面命令）" : "整窗辅助未开启"),
            call,
        ]
        let warnings = v.loadedAtStart == false
            ? ["云端视觉是守护进程启动后才开启的：整窗辅助已生效；添加群成员的按钮裁图要重启守护进程后才生效"] : []
        let fix: ReadinessFix?
        if !v.keyPresent {
            fix = ReadinessFix(text: "当前提供商没有密钥：复制密钥后执行", command: setKey, action: ReadinessAction(.openSettings, target: "vision"))
        } else if !f.screenRecordingGranted {
            fix = ReadinessFix(text: "视觉兜底要截企微窗口：在 系统设置 › 隐私与安全性 › 屏幕与系统录音 里允许 imctl.app（列表里没有就从访达拖进去）", command: screenRecordingPane, action: ReadinessAction(.openSystemSettings, target: "screenRecording"))
        } else if call.status == .fail {
            switch live?.category {
            case "http", "auth", "http4xx", "config": fix = ReadinessFix(text: "密钥被拒或额度不足：换一个有效密钥", command: setKey, action: ReadinessAction(.openSettings, target: "vision"))
            case "timeout", "network": fix = ReadinessFix(text: "连不上视觉服务：检查网络或代理后重测", command: "imctl doctor --refresh", action: ReadinessAction(.retest))
            default: fix = ReadinessFix(text: "视觉服务应答异常（\(categoryLabel(live?.category))）：稍后重测", command: "imctl doctor --refresh", action: ReadinessAction(.retest))
            }
        } else {
            fix = nil
        }
        return ReadinessCapability(id: "vision", title: "视觉兜底", required: false, status: fix == nil ? .ok : .fail, checks: checks, fix: fix,
                                   warnings: warnings)
    }

    static func mqttCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?, nowMs: Int64) -> ReadinessCapability {
        let m = f.mqtt
        let enroll = "imctl enroll --broker <主机[:端口]>"
        guard m.config.present else {
            return disabled("mqtt", "MQTT 对接", detail: "未配置",
                            fix: ReadinessFix(text: "要让 Java 或远端经 MQTT 调用：先登记 broker（controller id 默认取本机名），再以 MQTT 模式重装守护进程", command: enroll, action: ReadinessAction(.openSettings, target: "mqtt")))
        }
        guard m.config.valid else {
            return failure("mqtt", "MQTT 对接", check: ReadinessCheck(id: "config", status: .fail, detail: "mqtt.json 读不了"),
                           fix: ReadinessFix(text: "mqtt.json 读不了：重新登记 broker，并填回原来的 controller id（Java 端按它发命令）",
                                             command: "imctl enroll --broker <主机[:端口]> --controller-id <原来的 id>", action: ReadinessAction(.openSettings, target: "mqtt")))
        }
        let publish = m.daemonMode && m.connected ? liveCheck("publish", live, ok: "broker 已确认探测消息")
                                                  : ReadinessCheck(id: "publish", status: .unknown, detail: "未连接，未实测", tested: false)
        var checks = [
            ReadinessCheck(id: "config", status: .ok, detail: "mqtt.json 已配置"),
            ReadinessCheck(id: "daemonMode", status: m.daemonMode ? .ok : .fail, detail: m.daemonMode ? "守护进程以 MQTT 模式运行" : "守护进程没有以 MQTT 模式运行"),
            ReadinessCheck(id: "connected", status: m.connected ? .ok : .fail, detail: m.connected ? "已连上 broker" : "没有连上 broker"),
            publish,
        ]
        if m.daemonMode {
            checks.insert(ReadinessCheck(id: "lastCommand", status: .ok,
                                         detail: m.lastCommandMs.map { "最近一次收到命令：\(ago(nowMs - $0))" } ?? "守护进程启动后还没收到过命令"),
                          at: checks.count - 1)
        }
        let fix: ReadinessFix?
        if !m.daemonMode {
            fix = ReadinessFix(text: "以 MQTT 模式重装守护进程", command: "imctl agent install --mqtt", action: ReadinessAction(.reinstallDaemon))
        } else if !m.connected {
            fix = ReadinessFix(text: "连不上 broker：核对 mqtt.json 的地址、端口与账号；网络恢复后守护进程会自动重连", command: "imctl status", action: ReadinessAction(.openSettings, target: "mqtt"))
        } else if publish.status == .fail {
            fix = live?.category == "rejected"
                ? ReadinessFix(text: "broker 拒绝发布：检查本机账号对 im/<controllerId>/# 的授权", command: "imctl doctor --refresh", action: ReadinessAction(.retest))
                : ReadinessFix(text: "broker 没有确认探测消息（\(categoryLabel(live?.category))）：检查网络后重测", command: "imctl doctor --refresh", action: ReadinessAction(.retest))
        } else {
            fix = nil
        }
        return ReadinessCapability(id: "mqtt", title: "MQTT 对接", required: false, status: fix == nil ? .ok : .fail, checks: checks, fix: fix)
    }

    static func ossCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        guard f.oss.present else {
            return disabled("oss", "OSS 对象存储", detail: "未配置",
                            fix: ReadinessFix(text: "要用 OSS 收发文件：写入 oss.json（AccessKey Secret 用 --secret-stdin 传入）", command: "imctl oss set --help", action: ReadinessAction(.openSettings, target: "oss")))
        }
        guard f.oss.valid else {
            return failure("oss", "OSS 对象存储", check: ReadinessCheck(id: "config", status: .fail, detail: "oss.json 无效"),
                           fix: ReadinessFix(text: "重新写入 oss.json", command: "imctl oss set --help", action: ReadinessAction(.openSettings, target: "oss")))
        }
        guard f.oss.loaded != false else {
            return failure("oss", "OSS 对象存储", check: ReadinessCheck(id: "loaded", status: .fail, detail: "oss.json 有效，但不是守护进程启动时读到的那份"),
                           fix: restartDaemon)
        }
        let roundTrip = liveCheck("roundTrip", live, ok: "1 KB 往返正常")
        let fix: ReadinessFix?
        if roundTrip.status == .fail {
            switch live?.category {
            case "auth", "http4xx": fix = ReadinessFix(text: "OSS 拒绝请求：检查 AccessKey 与桶的读写权限", command: "imctl oss test", action: ReadinessAction(.openSettings, target: "oss"))
            case "cleanup": fix = ReadinessFix(text: "探测对象没删掉：在 OSS 控制台删除 imctl-readiness/ 下的对象")
            default: fix = ReadinessFix(text: "OSS 往返失败（\(categoryLabel(live?.category))）：用下面的命令看每一步", command: "imctl oss test", action: ReadinessAction(.openSettings, target: "oss"))
            }
        } else {
            fix = nil
        }
        return ReadinessCapability(id: "oss", title: "OSS 对象存储", required: false, status: fix == nil ? .ok : .fail,
                                   checks: [ReadinessCheck(id: "config", status: .ok, detail: "oss.json 已配置"), roundTrip], fix: fix)
    }

    static func agentsCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        let a = f.agents
        guard a.claude.registered || a.codex.registered else {
            return disabled("agents", "Claude Code / Codex 接入", detail: "两边都没有登记 imctl",
                            fix: ReadinessFix(text: "接入 Claude Code / Codex（MCP 与技能文件）", command: "imctl mcp install --claude-code --codex --skills", action: ReadinessAction(.registerAgents)))
        }
        struct Side { let key: String; let name: String; let agent: ReadinessFacts.Agent; let removal: String; let reinstall: String }
        let sides = [
            Side(key: "claude", name: "Claude Code", agent: a.claude, removal: "执行 claude mcp remove imctl -s user",
                 reinstall: "imctl mcp install --claude-code --skills"),
            Side(key: "codex", name: "Codex", agent: a.codex, removal: "删掉 ~/.codex/config.toml 里的 [mcp_servers.imctl] 一段",
                 reinstall: "imctl mcp install --codex --skills"),
        ]
        var checks: [ReadinessCheck] = []
        var warnings: [String] = []
        var fix: ReadinessFix?
        for side in sides {
            guard side.agent.registered else { warnings.append("\(side.name) 没有登记 imctl（可选）"); continue }
            checks.append(ReadinessCheck(id: "\(side.key).command", status: side.agent.commandMatches ? .ok : .fail,
                                         detail: side.agent.commandMatches ? "\(side.name) 登记的是当前应用" : "\(side.name) 登记的不是当前应用里的 imctl"))
            if !side.agent.commandMatches, fix == nil {
                fix = ReadinessFix(text: "\(side.name) 里登记的路径不是当前应用：先\(side.removal)，再执行", command: side.reinstall)
            }
            switch side.agent.skill {
            case .current:
                checks.append(ReadinessCheck(id: "\(side.key).skill", status: .ok, detail: "\(side.name) 技能文件是当前版本"))
            case .missing, .stale:
                checks.append(ReadinessCheck(id: "\(side.key).skill", status: .fail,
                                             detail: side.agent.skill == .missing ? "\(side.name) 缺技能文件" : "\(side.name) 技能文件不是当前版本"))
                if fix == nil { fix = ReadinessFix(text: "更新技能文件", command: "imctl mcp install --skills", action: ReadinessAction(.installSkills)) }
            case .unknown:
                checks.append(ReadinessCheck(id: "\(side.key).skill", status: .unknown, detail: "\(side.name) 技能文件无法比对（应用包里没有 SKILL.md）"))
            }
        }
        let handshake = a.cliPresent ? liveCheck("handshake", live, ok: "imctl mcp serve 握手正常")
                                     : ReadinessCheck(id: "handshake", status: .unknown, detail: "应用包里找不到 imctl，未实测", tested: false)
        checks.append(handshake)
        if fix == nil, handshake.status == .fail {
            fix = ReadinessFix(text: "应用里的 imctl 起不来或版本不对（\(categoryLabel(live?.category))）：重新安装应用后重测", command: "imctl doctor --refresh", action: ReadinessAction(.retest))
        }
        return ReadinessCapability(id: "agents", title: "Claude Code / Codex 接入", required: false, status: fix == nil ? .ok : .fail,
                                   checks: checks, fix: fix, warnings: warnings)
    }

    static func wecomApiCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        guard f.wecomApi.present else {
            return disabled("wecomApi", "企微官方 API 代理", detail: "未配置",
                            fix: ReadinessFix(text: "企微官方 API 要先部署令牌代理（见 docs/protocol/wecom-token-proxy.md），再登记代理地址", command: "imctl wecom enroll --help", action: ReadinessAction(.openSettings, target: "proxy")))
        }
        guard f.wecomApi.valid else {
            return failure("wecomApi", "企微官方 API 代理", check: ReadinessCheck(id: "config", status: .fail, detail: "wecom-proxy.json 读不了"),
                           fix: ReadinessFix(text: "重新登记代理", command: "imctl wecom enroll --help", action: ReadinessAction(.openSettings, target: "proxy")))
        }
        guard f.wecomApi.loaded != false else {
            return failure("wecomApi", "企微官方 API 代理", check: ReadinessCheck(id: "loaded", status: .fail, detail: "wecom-proxy.json 有效，但不是守护进程启动时读到的那份"),
                           fix: restartDaemon)
        }
        let health = liveCheck("health", live, ok: "代理健康检查正常")
        let fix: ReadinessFix? = health.status == .fail
            ? ReadinessFix(text: "代理健康检查失败（\(categoryLabel(live?.category))）：确认代理在运行、地址可达", command: "imctl doctor --refresh", action: ReadinessAction(.retest))
            : nil
        return ReadinessCapability(id: "wecomApi", title: "企微官方 API 代理", required: false, status: fix == nil ? .ok : .fail,
                                   checks: [ReadinessCheck(id: "config", status: .ok, detail: "wecom-proxy.json 已配置"), health], fix: fix)
    }

    /// "刚刚 / N 分钟前 / N 小时前 / N 天前".
    static func ago(_ ms: Int64) -> String {
        if ms < 60_000 { return "刚刚" }
        if ms < 3_600_000 { return "\(ms / 60_000) 分钟前" }
        if ms < 86_400_000 { return "\(ms / 3_600_000) 小时前" }
        return "\(ms / 86_400_000) 天前"
    }

    /// B53: warnings only — never `fail`, so it never blocks `ready`.
    static func healthCapability(_ f: ReadinessFacts) -> ReadinessCapability {
        let h = f.health
        let checks = [
            ReadinessCheck(id: "failed", status: .ok, detail: "最近一小时失败的命令 \(h.failedLastHour) 条"),
            ReadinessCheck(id: "unknown", status: .ok, detail: "最近一小时结果未知的命令 \(h.unknownLastHour) 条"),
            ReadinessCheck(id: "watchErrors", status: .ok, detail: "最近一小时读取企业微信出错 \(f.watch.errorsLastHour) 次"),
        ]
        var warnings: [String] = []
        if h.failedLastHour > 0 { warnings.append("最近一小时有 \(h.failedLastHour) 条命令失败") }
        if h.unknownLastHour > 0 { warnings.append("最近一小时有 \(h.unknownLastHour) 条命令结果未知：按原幂等键对账，不要换键重试") }
        if f.watch.errorsLastHour > 0 { warnings.append("最近一小时读取企业微信出错 \(f.watch.errorsLastHour) 次") }
        let fix = warnings.isEmpty ? nil : ReadinessFix(text: "看守护进程日志找原因", command: "tail -n 50 ~/Library/Logs/imctl/imctld.log",
                                                        action: ReadinessAction(.openLogs))
        return ReadinessCapability(id: "health", title: "运行健康", required: false, status: .ok, checks: checks, fix: fix, warnings: warnings)
    }

    // MARK: Helpers

    static func disabled(_ id: String, _ title: String, detail: String, fix: ReadinessFix) -> ReadinessCapability {
        ReadinessCapability(id: id, title: title, required: false, status: .disabled,
                            checks: [ReadinessCheck(id: "config", status: .disabled, detail: detail)], fix: fix)
    }

    static func failure(_ id: String, _ title: String, check: ReadinessCheck, fix: ReadinessFix) -> ReadinessCapability {
        ReadinessCapability(id: id, title: title, required: false, status: .fail, checks: [check], fix: fix)
    }
}
