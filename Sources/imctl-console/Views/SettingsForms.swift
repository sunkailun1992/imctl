import MQTTTransport
import SwiftUI
import WeComAdapter

/// B53: the MQTT form, shared by the settings page and the setup wizard.
struct MQTTSettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var host = ""
    @State private var port = "1883"
    @State private var tls = false
    @State private var controllerID = ""
    @State private var username = ""
    @State private var password = ""
    @State private var topicPrefix = "im"
    @State private var keepAlive = "30"
    @State private var stored = ConsoleModel.StoredSettings()
    @State private var hostDefaultID: String?

    func load() {
        stored = model.loadStoredSettings()
        host = stored.host; port = String(stored.port); tls = stored.tls
        hostDefaultID = MQTTSettings.defaultControllerID(localHostName: MQTTSettings.currentLocalHostName())
        controllerID = ConsoleModel.formControllerID(stored: stored, hostDefault: hostDefaultID, fileExists: model.mqttEnrolled)
        username = stored.username; topicPrefix = stored.topicPrefix; keepAlive = String(stored.keepAliveSeconds)
        password = ""
    }

    var body: some View {
        Section("MQTT \(model.mqttEnrolled ? "· 已配置" : "· 未配置")") {
            TextField("broker 主机", text: $host)
            TextField("端口", text: $port)
            Toggle("TLS", isOn: $tls)
            TextField("controller id（一机一号一 id）", text: $controllerID)
            if model.mqttEnrolled && stored.controllerID.isEmpty {
                Text("mqtt.json 读不了：填回原来的 controller id（Java 端按它发命令），或删掉这个文件后重新配置")
                    .font(.caption).foregroundStyle(.orange)
            } else if stored.controllerID.isEmpty && hostDefaultID != nil && controllerID == hostDefaultID {
                Text("默认取本机名，可改；同一 broker 上每台 Mac 要不同。Java 端按这个 id 发命令，EMQX 开了认证时用户名也用它")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !MQTTSettings.isValidControllerID(controllerID) {
                Text(controllerID.isEmpty ? "要填 controller id：1–64 个字母、数字或 . _ -" : "只能用 1–64 个字母、数字或 . _ -（它是 topic 的一段）")
                    .font(.caption).foregroundStyle(.red)
            }
            TextField("用户名（可选）", text: $username)
            SecureField(stored.hasPassword ? "密码：已保存（留空则保留原值）" : "密码（可选）", text: $password)
            TextField("topic 前缀", text: $topicPrefix)
            TextField("keepAlive（秒）", text: $keepAlive)
            if !controllerID.isEmpty {
                Text("topics：" + ["cmd", "rsp", "evt", "state"].map { "\((topicPrefix.isEmpty ? "im" : topicPrefix))/\(controllerID)/\($0)" }.joined(separator: "  "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("保存 MQTT 设置") {
                    model.saveMQTT(host: host, port: Int(port) ?? (tls ? 8883 : 1883), tls: tls, controllerID: controllerID,
                                   username: username, password: password, topicPrefix: topicPrefix,
                                   keepAliveSeconds: Int(keepAlive) ?? 30)
                    load()
                    onSaved()
                }
                .disabled(host.isEmpty || !MQTTSettings.isValidControllerID(controllerID))
                Button("重新读取") { load() }
            }
        }
        .onAppear { load() }
    }
}

/// B53: the WeCom token proxy form.
struct ProxySettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var proxyURL = ""
    @State private var proxyToken = ""
    @State private var corpId = ""
    @State private var agentId = ""
    @State private var proxyTimeout = "15"
    @State private var stored = ConsoleModel.StoredSettings()

    func load() {
        stored = model.loadStoredSettings()
        proxyURL = stored.proxyURL; corpId = stored.corpId; agentId = stored.agentId.map(String.init) ?? ""
        proxyTimeout = String(Int(stored.proxyTimeoutSeconds)); proxyToken = ""
    }

    var body: some View {
        Section("企微令牌代理 \(model.proxyEnrolled ? "· 已配置" : "· 未配置")") {
            TextField("代理地址 https://…", text: $proxyURL)
            SecureField(stored.hasProxyToken ? "Bearer token：已保存（留空则保留原值）" : "Bearer token", text: $proxyToken)
            TextField("corpId（可选，代理侧也可配置）", text: $corpId)
            TextField("agentId（可选）", text: $agentId)
            TextField("超时（秒）", text: $proxyTimeout)
            Button("保存代理设置") {
                model.saveProxy(baseURL: proxyURL, token: proxyToken, corpId: corpId, agentId: Int(agentId), timeoutSeconds: Double(proxyTimeout) ?? 15)
                load()
                onSaved()
            }
            .disabled(proxyURL.isEmpty || (proxyToken.isEmpty && !stored.hasProxyToken))
        }
        .onAppear { load() }
    }
}

/// B53: the OSS form.
struct OSSSettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var ossEndpoint = ""
    @State private var ossBucket = ""
    @State private var ossBaseDir = "imctl"
    @State private var ossAccessKeyId = ""
    @State private var ossSecret = ""
    @State private var ossViewExpire = "1800"
    @State private var ossMaxUpload = "52428800"
    @State private var stored = ConsoleModel.StoredSettings()

    func load() {
        stored = model.loadStoredSettings()
        ossEndpoint = stored.ossEndpoint; ossBucket = stored.ossBucket; ossBaseDir = stored.ossBaseDir
        ossViewExpire = String(stored.ossViewExpireSeconds); ossMaxUpload = String(stored.ossMaxUploadBytes)
        ossSecret = ""; ossAccessKeyId = ""
    }

    var body: some View {
        Section("对象存储 OSS \(model.ossEnrolled ? "· 已配置" : "· 未配置")") {
            TextField("endpoint https://oss-<region>.aliyuncs.com", text: $ossEndpoint)
            TextField("bucket（私有）", text: $ossBucket)
            TextField("base-dir（对象键前缀）", text: $ossBaseDir)
            if !stored.ossAccessKeyIdMasked.isEmpty {
                Text("当前 AccessKeyId：\(stored.ossAccessKeyIdMasked)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("新的 AccessKeyId（留空保持）", text: $ossAccessKeyId)
            SecureField(stored.hasOSSSecret ? "AccessKeySecret：已保存（留空则保留原值）" : "AccessKeySecret", text: $ossSecret)
            TextField("签名地址有效期（秒）", text: $ossViewExpire)
            TextField("单文件上传上限（字节）", text: $ossMaxUpload)
            HStack {
                Button("保存 OSS 设置") {
                    model.saveOSS(endpoint: ossEndpoint, bucket: ossBucket, baseDir: ossBaseDir, accessKeyId: ossAccessKeyId, accessKeySecret: ossSecret,
                                  viewExpireSeconds: Int(ossViewExpire) ?? 1800, maxUploadBytes: Int64(ossMaxUpload) ?? 52_428_800)
                    load()
                    onSaved()
                }
                // `saveOSS` trims the base-dir of slashes before storing it, so "/" is as empty as "".
                .disabled(ossEndpoint.isEmpty || ossBucket.isEmpty || ossBaseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
                          || (ossAccessKeyId.isEmpty && stored.ossAccessKeyIdMasked.isEmpty) || (ossSecret.isEmpty && !stored.hasOSSSecret))
                Button("测试往返（1 KB 探针）") { Task { await model.ossTest() } }.disabled(!model.ossEnrolled || model.busy)
                Button("重新读取") { load() }
            }
            if !model.ossTestResult.isEmpty { ResultPane(title: "imctl oss test", text: model.ossTestResult, minHeight: 80) }
            Text("controller.describe.oss：\(model.describe["oss"] ?? "-")（守护进程是否已加载 OSS；改完设置要重启守护进程才会更新）")
                .font(.caption).foregroundStyle(.secondary)
            Text("密钥只进本机 oss.json；改完要在「状态」页重启守护进程。").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { load() }
    }
}

/// B53: the cloud vision form.
struct VisionSettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var visionProvider = CloudVisionProvider.qwen.rawValue
    @State private var visionModel = CloudVisionSettings.defaultModel(for: .qwen)
    @State private var visionSecret = ""
    @State private var stored = ConsoleModel.StoredSettings()

    private var selectedVisionProvider: CloudVisionProvider { CloudVisionProvider(rawValue: visionProvider) ?? .qwen }

    func load() {
        stored = model.loadStoredSettings()
        visionProvider = stored.visionProvider; visionModel = stored.visionModel; visionSecret = ""
    }

    var body: some View {
        Section("云端视觉定位 \(stored.visionEnabled ? "· 已启用" : "· 已关闭")") {
            Picker("提供商", selection: $visionProvider) {
                ForEach(CloudVisionProvider.allCases, id: \.rawValue) { provider in
                    Text(provider.rawValue).tag(provider.rawValue)
                }
            }
            .onChange(of: visionProvider) { _, newValue in
                if let provider = CloudVisionProvider(rawValue: newValue) {
                    visionModel = CloudVisionSettings.defaultModel(for: provider)
                }
                visionSecret = ""
            }
            Picker("视觉模型", selection: $visionModel) {
                ForEach(CloudVisionSettings.allowedModels(for: selectedVisionProvider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            SecureField(stored.visionKeysPresent[visionProvider] == true ? "API 密钥已保存（留空则保留）" : "API 密钥", text: $visionSecret)
            Text("局部按钮裁图沿用原开关。显式桌面命令若需上传完整企微窗口，须再单独启用整窗辅助；窗口可能包含其它会话预览。后台观察和自动申请不上传。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存并启用") {
                    model.saveVision(provider: visionProvider, model: visionModel, secret: visionSecret)
                    load()
                    onSaved()
                }
                .disabled(visionSecret.isEmpty && stored.visionKeysPresent[visionProvider] != true)
                Button("关闭云端视觉") { model.disableVision(); load(); onSaved() }
                    .disabled(!stored.visionEnabled)
                Button("重新读取") { load() }
            }
            HStack {
                Button(stored.visionFullWindowEnabled ? "关闭整窗辅助" : "允许整窗辅助") {
                    model.setFullWindowVision(!stored.visionFullWindowEnabled)
                    load()
                    onSaved()
                }
                .disabled(!stored.visionEnabled)
                Text(stored.visionFullWindowEnabled ? "整窗辅助已授权" : "整窗辅助未授权")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("密钥只存在本机受限配置文件中，不会显示在界面或进入 MQTT。切换后请在「状态」页重启守护进程。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { load() }
    }
}
