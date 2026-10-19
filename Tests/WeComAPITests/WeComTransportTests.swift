import Foundation
import Testing
@testable import ControlCore
@testable import WeComAPI

@Suite("URLSessionWeComTransport through a URLProtocol proxy", .serialized)
struct WeComTransportTests {
    func transport() -> URLSessionWeComTransport {
        URLSessionWeComTransport(settings: WeComProxySettings(baseURL: "https://proxy.example.test", token: "t0k3n", corpId: "wwtest"),
                                 session: FakeProxyProtocol.session())
    }

    @Test func postsJsonWithBearerUnderTheWecomPrefix() throws {
        FakeProxyProtocol.reset()
        let r = try transport().post(path: "externalcontact/groupchat/list", body: Data(#"{"limit":10}"#.utf8))
        #expect(r.status == 200 && String(decoding: r.body, as: UTF8.self).contains("\"errcode\":0"))
        let seen = try #require(FakeProxyProtocol.seen.first)
        #expect(seen.path == "/wecom/externalcontact/groupchat/list" && seen.authorization == "Bearer t0k3n" && seen.body["limit"] as? Int == 10)
    }

    @Test func statusCodesArePassedThroughForTheClientToMap() throws {
        FakeProxyProtocol.reset()
        FakeProxyProtocol.respond = { _ in (401, #"{"error":"bad token"}"#) }
        #expect(try transport().post(path: "x", body: Data()).status == 401)
    }

    @Test func invalidBaseUrlIsAProxyError() {
        let t = URLSessionWeComTransport(settings: WeComProxySettings(baseURL: "not a url", token: "t"), session: FakeProxyProtocol.session())
        #expect(throws: ControlError.self) { try t.post(path: "x", body: Data()) }
    }
}
