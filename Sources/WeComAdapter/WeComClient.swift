/// Facts about the WeCom (企业微信) macOS client that the adapter is built
/// against. The send-target allowlist is compiled in on purpose: widening it
/// is a human decision recorded in the wiki, never a config change.
public enum WeComClient {
    public static let bundleID = "com.tencent.WeWorkMac"
    public static let displayName = "企业微信"
    /// The only send target allowed in phases 0/1.
    public static let fileTransferAssistantTitle = "文件传输助手"
}
