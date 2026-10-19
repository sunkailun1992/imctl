import Foundation
import Testing
@testable import ControlCore
@testable import OSSClient

@Suite("OSS V4 signer and settings")
struct OSSSignerTests {
    let signer = OSSSigner(accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", region: "cn-hangzhou")
    // Deviation from the brief (see task-9-report.md): 1_790_000_000 is 2026-09-21T14:13:20Z, not
    // T09:33:20Z as the brief's comment and stamp/x-oss-date literals stated (verified independently via
    // `date -u -r 1790000000` and Foundation's own Calendar); the two derived-from-`date` literals below are
    // corrected to the actual UTC time. The `day` ("20260921") was already correct and is unchanged, as is
    // the unrelated stringToSign literal below (it takes "...T093320Z" as a direct, date-independent argument).
    let date = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21T14:13:20Z

    @Test func stampsEncodingAndCanonicalPieces() {
        let (stamp, day) = OSSSigner.stamps(date)
        #expect(stamp == "20260921T141320Z" && day == "20260921")
        #expect(OSSSigner.encode("imctl/2026/09/22/k-电子发票 (1).pdf", keepSlash: true) == "imctl/2026/09/22/k-%E7%94%B5%E5%AD%90%E5%8F%91%E7%A5%A8%20%281%29.pdf")
        #expect(OSSSigner.encode("a/b", keepSlash: false) == "a%2Fb")
        #expect(OSSSigner.canonicalURI(bucket: "b", key: "x y/z.png") == "/b/x%20y/z.png")
        #expect(OSSSigner.canonicalQuery([("x-oss-expires", "60"), ("x-oss-date", "D"), ("empty", "")]) == "empty&x-oss-date=D&x-oss-expires=60")
        #expect(OSSSigner.canonicalHeaders(["Content-Type": "image/png ", "Host": "h", "x-oss-date": "D", "X-OSS-Content-SHA256": "UNSIGNED-PAYLOAD"]) == "content-type:image/png\nx-oss-content-sha256:UNSIGNED-PAYLOAD\nx-oss-date:D\n")
        let canonical = OSSSigner.canonicalRequest(method: "PUT", bucket: "b", key: "k.png", query: [], headers: ["x-oss-date": "D"], payloadHash: "UNSIGNED-PAYLOAD")
        #expect(canonical == "PUT\n/b/k.png\n\nx-oss-date:D\n\n\nUNSIGNED-PAYLOAD")
        #expect(signer.scope(day: "20260921") == "20260921/cn-hangzhou/oss/aliyun_v4_request")
        let sts = signer.stringToSign(canonicalRequest: canonical, stamp: "20260921T093320Z", day: "20260921")
        #expect(sts.hasPrefix("OSS4-HMAC-SHA256\n20260921T093320Z\n20260921/cn-hangzhou/oss/aliyun_v4_request\n") && sts.split(separator: "\n").last?.count == 64)
    }

    /// Known-answer vector: the official Aliyun「签名版本4（推荐）」PutObject header-signing example
    /// (AccessKeyId `accesskeyid`, region `cn-hangzhou`, `20231203T121212Z`, `AdditionalHeaders=host`).
    /// Read 2026-09-22 from the Wayback snapshot `20240718200620` of
    /// help.aliyun.com/zh/oss/developer-reference/recommend-to-use-signature-version-4 — the live page has
    /// since replaced this worked example with a 2025 one whose AccessKeySecret is the literal placeholder
    /// `yourAccessKeySecret`, so that newer example's signature cannot be reproduced by anyone.
    ///
    /// Two independent doc-published values are asserted, so a wrong canonical layout and a wrong HMAC chain
    /// fail separately: the canonical request's own SHA-256 (which the doc prints as the last line of its
    /// StringToSign) pins the layout, and the final signature pins the chain. Both were reproduced with a
    /// standalone Python `hmac` / `hashlib` script before this test existed (see task-9-report.md).
    @Test func officialAliyunV4HeaderSigningVector() {
        let doc = OSSSigner(accessKeyId: "accesskeyid", accessKeySecret: "accesskeysecret", region: "cn-hangzhou")
        let docDate = Date(timeIntervalSince1970: 1_701_605_532)   // 20231203T121212Z
        // The headers the doc's PutObject request carries; `x-oss-date` / `x-oss-content-sha256` are the signer's.
        let headers = [
            "Content-MD5": "eB5eJF1ptWaXm4bijSPyxw",
            "Content-Type": "text/html",
            "x-oss-meta-author": "alice",
            "x-oss-meta-magic": "abracadabra",
            "Host": "examplebucket.oss-cn-hangzhou.aliyuncs.com",
        ]
        var signable = headers
        signable["x-oss-date"] = "20231203T121212Z"
        signable["x-oss-content-sha256"] = OSSSigner.unsignedPayload
        let canonical = OSSSigner.canonicalRequest(
            method: "PUT", bucket: "examplebucket", key: "exampleobject", query: [],
            headers: signable, payloadHash: OSSSigner.unsignedPayload, additionalHeaders: ["host"]
        )
        let expectedCanonical = """
        PUT
        /examplebucket/exampleobject

        content-md5:eB5eJF1ptWaXm4bijSPyxw
        content-type:text/html
        host:examplebucket.oss-cn-hangzhou.aliyuncs.com
        x-oss-content-sha256:UNSIGNED-PAYLOAD
        x-oss-date:20231203T121212Z
        x-oss-meta-author:alice
        x-oss-meta-magic:abracadabra

        host
        UNSIGNED-PAYLOAD
        """
        #expect(canonical == expectedCanonical)
        let expectedStringToSign = """
        OSS4-HMAC-SHA256
        20231203T121212Z
        20231203/cn-hangzhou/oss/aliyun_v4_request
        129b14df88496f434606e999e35dee010ea1cecfd3ddc378e5ed4989609c1db3
        """
        #expect(doc.stringToSign(canonicalRequest: canonical, stamp: "20231203T121212Z", day: "20231203") == expectedStringToSign)
        let signed = doc.signedHeaders(method: "PUT", bucket: "examplebucket", key: "exampleobject",
                                       headers: headers, date: docDate, additionalHeaders: ["host"])
        #expect(signed["Authorization"] == "OSS4-HMAC-SHA256 Credential=accesskeyid/20231203/cn-hangzhou/oss/aliyun_v4_request,AdditionalHeaders=host,Signature=4b663e424d2db9967401ff6ce1c86f8c83cabd77d9908475239d9110642c63fa")
    }

    /// What B13's own PUT / HEAD / GET / DELETE send: no additional headers, so `Host` stays out of the
    /// canonical headers (OSS derives it) and no `AdditionalHeaders=` segment is emitted.
    @Test func withoutAdditionalHeadersHostIsNotSignedAndNoSegmentIsEmitted() {
        let headers = ["Content-Type": "text/html", "Host": "examplebucket.oss-cn-hangzhou.aliyuncs.com",
                       "x-oss-date": "20231203T121212Z", "x-oss-content-sha256": OSSSigner.unsignedPayload]
        let canonical = OSSSigner.canonicalRequest(method: "PUT", bucket: "examplebucket", key: "exampleobject",
                                                   query: [], headers: headers, payloadHash: OSSSigner.unsignedPayload)
        #expect(canonical == "PUT\n/examplebucket/exampleobject\n\ncontent-type:text/html\nx-oss-content-sha256:UNSIGNED-PAYLOAD\nx-oss-date:20231203T121212Z\n\n\nUNSIGNED-PAYLOAD")
        let auth = signer.signedHeaders(method: "PUT", bucket: "b", key: "k.png", headers: ["Content-Type": "image/png"], date: date)["Authorization"]
        #expect(auth?.contains("AdditionalHeaders=") == false && auth?.contains("aliyun_v4_request,Signature=") == true)
    }

    @Test func headerSignatureIsDeterministicAndDependsOnTheSecret() {
        let a = signer.signedHeaders(method: "PUT", bucket: "b", key: "k.png", headers: ["Content-Type": "image/png"], date: date)
        let b = signer.signedHeaders(method: "PUT", bucket: "b", key: "k.png", headers: ["Content-Type": "image/png"], date: date)
        #expect(a == b && a["x-oss-date"] == "20260921T141320Z" && a["x-oss-content-sha256"] == "UNSIGNED-PAYLOAD")
        let auth = try! #require(a["Authorization"])
        #expect(auth.hasPrefix("OSS4-HMAC-SHA256 Credential=TESTAKID0000000001/20260921/cn-hangzhou/oss/aliyun_v4_request,Signature=") && auth.split(separator: "=").last?.count == 64)
        let other = OSSSigner(accessKeyId: "TESTAKID0000000001", accessKeySecret: "another", region: "cn-hangzhou").signedHeaders(method: "PUT", bucket: "b", key: "k.png", headers: ["Content-Type": "image/png"], date: date)
        #expect(other["Authorization"] != a["Authorization"])
        #expect(!auth.contains("test-secret"))
    }

    @Test func presignedQueryCarriesTheFiveParametersAndNoSecret() {
        let q = signer.presignedQuery(bucket: "b", key: "dir/k.pdf", expiresIn: 1800, date: date)
        let names = q.map(\.0)
        #expect(names == ["x-oss-signature-version", "x-oss-credential", "x-oss-date", "x-oss-expires", "x-oss-signature"])
        #expect(q[0].1 == "OSS4-HMAC-SHA256" && q[1].1 == "TESTAKID0000000001/20260921/cn-hangzhou/oss/aliyun_v4_request" && q[3].1 == "1800" && q[4].1.count == 64)
        #expect(!q.map(\.1).joined().contains("test-secret"))
    }

    @Test func settingsDeriveRegionAndHostSaveOwnerOnlyAndMaskTheKey() throws {
        var s = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret")
        #expect(s.region == "cn-hangzhou" && s.bucketHost == "photos.oss-cn-hangzhou.aliyuncs.com" && s.viewExpireSeconds == 1800 && s.maxUploadBytes == 52_428_800)
        s.endpoint = "https://oss-cn-shanghai-internal.aliyuncs.com"
        #expect(s.region == "cn-shanghai")
        #expect(OSSSettings.mask("TESTAKID0000000001") == "TEST…01" && OSSSettings.mask("ab") == "…")
        #expect(!s.summary.contains("test-secret") && s.summary.contains("bucket=photos"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-\(UUID().uuidString)/oss.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try s.save(to: url)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try OSSSettings.load(from: url) == s)
        #expect(OSSSettings.fileName == "oss.json" && OSSSettings.defaultURL.lastPathComponent == "oss.json")
    }

    /// `oss.json` is untrusted input as far as `imctld` is concerned: a bucket with a space used to trap the
    /// daemon on `URL(string:)!`, and `evil.example/x` would have aimed a signed request at a foreign host.
    /// Both `load` and `save` must refuse each shape, and the message names the field but never a value.
    @Test func loadAndSaveRejectEveryMalformedField() throws {
        func variant(_ mutate: (inout OSSSettings) -> Void) -> OSSSettings {
            var s = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl",
                                accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret")
            mutate(&s)
            return s
        }
        let bad: [(String, OSSSettings)] = [
            ("bucket with a space", variant { $0.bucket = "my bucket" }),
            ("bucket as host+path", variant { $0.bucket = "evil.example/x" }),
            ("bucket too short", variant { $0.bucket = "ab" }),
            ("http endpoint", variant { $0.endpoint = "http://oss-cn-hangzhou.aliyuncs.com" }),
            ("endpoint with a path", variant { $0.endpoint = "https://oss-cn-hangzhou.aliyuncs.com/x" }),
            ("endpoint with a query", variant { $0.endpoint = "https://oss-cn-hangzhou.aliyuncs.com?a=b" }),
            ("foreign endpoint host", variant { $0.endpoint = "https://evil.example" }),
            ("look-alike endpoint host", variant { $0.endpoint = "https://oss-cn-hangzhou.aliyuncs.com.evil.example" }),
            ("empty secret", variant { $0.accessKeySecret = "" }),
            ("whitespace in the secret", variant { $0.accessKeySecret = "two words" }),
            ("empty key id", variant { $0.accessKeyId = "" }),
            ("baseDir escaping upward", variant { $0.baseDir = "../x" }),
            ("absolute baseDir", variant { $0.baseDir = "/etc" }),
            // Finding F9: both normalise to nothing, and every object key would then start with "/".
            ("empty baseDir", variant { $0.baseDir = "" }),
            ("baseDir that is only a slash", variant { $0.baseDir = "/" }),
            ("expiry 0", variant { $0.viewExpireSeconds = 0 }),
            ("expiry past a week", variant { $0.viewExpireSeconds = 604_801 }),
            ("no upload cap", variant { $0.maxUploadBytes = 0 }),
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (what, s) in bad {
            do {
                try s.save(to: dir.appendingPathComponent("oss.json"))
                Issue.record("save accepted \(what)")
            } catch let e as ControlError {
                #expect(e.code == "OSS_NOT_CONFIGURED" && !e.message.contains("test-secret"), "save: \(what)")
            }
            // Hand-written / tampered files take the same path through `load`.
            let file = dir.appendingPathComponent("hand-written.json")
            try JSONEncoder().encode(s).write(to: file)
            do {
                _ = try OSSSettings.load(from: file)
                Issue.record("load accepted \(what)")
            } catch let e as ControlError {
                #expect(e.code == "OSS_NOT_CONFIGURED" && !e.message.contains("test-secret"), "load: \(what)")
            }
        }
    }

    /// A valid file survives the new gate unchanged, and `baseDir`'s trailing slash is normalised away so it
    /// cannot produce `imctl//2026/...` keys.
    @Test func validSettingsRoundTripAndBaseDirIsNormalised() throws {
        let s = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl/pics/",
                            accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", viewExpireSeconds: 604_800, maxUploadBytes: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-\(UUID().uuidString)/oss.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try s.save(to: url)
        let back = try OSSSettings.load(from: url)
        #expect(back.baseDir == "imctl/pics" && back.bucket == "photos" && back.viewExpireSeconds == 604_800 && back.maxUploadBytes == 1)
        #expect(throws: Never.self) { try back.validate() }
    }

    /// Default reflection prints every stored property, so `"\(settings)"` in a log line would have leaked
    /// the AccessKey pair. Both types must render masked through all three string conversions.
    @Test func reflectionOfSettingsAndSignerNeverShowsTheSecret() {
        let s = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl",
                            accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret")
        for text in ["\(s)", String(describing: s), String(reflecting: s), "\(signer)", String(describing: signer), String(reflecting: signer)] {
            #expect(!text.contains("test-secret") && !text.contains("TESTAKID0000000001"), "leaked in: \(text)")
        }
        #expect("\(s)" == s.summary)
        #expect("\(signer)" == "OSSSigner(TEST…01, cn-hangzhou)")
    }
}
