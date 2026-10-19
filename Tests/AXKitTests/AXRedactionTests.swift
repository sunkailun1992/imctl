import Testing
@testable import AXKit

@Suite("AXRedaction")
struct AXRedactionTests {
    let policy = AXRedactionPolicy.default(keepTexts: ["文件传输助手"], salt: "fixed-salt")

    @Test func keepsAllowlistedRolesAndTexts() {
        #expect(policy.redact("文件传输助手") == "文件传输助手")
        #expect(policy.redact("14:32") == "14:32")
        #expect(policy.redact("昨天 上午9:05") == "昨天 上午9:05")
        #expect(policy.redact("3") == "3")
        #expect(policy.redact("2分钟前") == "2分钟前")
        #expect(policy.redact("刚刚") == "刚刚")
        #expect(policy.redact("1小时前") == "1小时前")
        #expect(policy.redact("<2 elements>") == "<2 elements>")
        #expect(policy.redact("<element>") == "<element>")
        #expect(policy.redact("false") == "false")
        #expect(policy.redact("<unknown: AXValue cgPoint>") == "<unknown: AXValue cgPoint>")
    }

    /// B12: time labels stay readable, phone numbers never do — even though both are digits.
    @Test func longDigitRunsAreNeverKept() {
        let p = AXRedactionPolicy.default(keepTexts: [])
        #expect(p.redact("9:32") == "9:32" && p.redact("2026/9/16") == "2026/9/16" && p.redact("昨天 21:37") == "昨天 21:37")
        #expect(p.redact("13800000000").hasPrefix("«") && p.redact("１３８００００００００").hasPrefix("«") && p.redact("2026-09-16 1380000").hasPrefix("«"))
    }

    @Test func replacesOtherTextDeterministicallyAndIrreversibly() {
        let a = policy.redact("张三")
        let b = policy.redact("张三")
        let c = policy.redact("李四")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hasPrefix("«") && a.hasSuffix("»") && a.count == 10)
        #expect(!a.contains("张"))
        #expect(AXRedactionPolicy.default(keepTexts: [], salt: "other").redact("张三") != a)
    }

    @Test func redactsTreeButKeepsStructureAndChrome() {
        let tree = AXNode(role: AXRole.application, title: "企业微信", children: [
            AXNode(role: AXRole.window, title: "张三", children: [
                AXNode(role: AXRole.row, title: "张三", description: "未读 2", extra: ["AXSelectedRows": "张三"]),
                AXNode(role: AXRole.row, title: "文件传输助手"),
                AXNode(role: AXRole.button, title: "发送", help: "张三的按钮"),
                AXNode(role: AXRole.textArea, value: .string("hello 张三"), placeholder: "输入消息"),
            ]),
        ])
        let out = tree.redacted(policy)
        #expect(out.title == "企业微信")
        #expect(out.children[0].title != "张三")
        let rows = out.children[0].children
        #expect(rows[0].title == out.children[0].title)
        #expect(rows[0].description != "未读 2")
        #expect(rows[0].extra["AXSelectedRows"] == rows[0].title)
        #expect(rows[1].title == "文件传输助手")
        #expect(rows[2].title == "发送")
        #expect(rows[2].help != "张三的按钮")
        #expect(rows[3].value?.stringValue != "hello 张三")
        #expect(rows[3].placeholder == "输入消息")
        #expect(out.count == tree.count)
    }
}
