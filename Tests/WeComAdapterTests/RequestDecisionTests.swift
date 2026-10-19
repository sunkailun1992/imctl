import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("RequestDecision")
struct RequestDecisionTests {
    @Test func observesNewPendingCardsOnceAndAcceptsPerPolicy() {
        var policy = ContactRequestPolicy(autoAccept: .rules, allowNames: ["测试联系人A"])
        let cards = [(name: "测试联系人A", greeting: Optional("我是 测试联系人A"), status: "pending"),
                     (name: "路人", greeting: Optional("hi"), status: "pending"),
                     (name: "老客户", greeting: nil, status: "added")]
        let first = RequestDecision.plan(cards: cards, policy: policy, seen: [])
        #expect(first.observe == ["测试联系人A", "路人"] && first.accept == ["测试联系人A"] && first.seen.count == 2)
        let second = RequestDecision.plan(cards: cards, policy: policy, seen: first.seen)
        #expect(second.observe.isEmpty && second.accept == ["测试联系人A"])
        policy.autoAccept = .remote
        #expect(RequestDecision.plan(cards: cards, policy: policy, seen: []).accept.isEmpty)
        policy.autoAccept = .all
        #expect(RequestDecision.plan(cards: cards, policy: policy, seen: []).accept == ["测试联系人A", "路人"])
        policy.autoAccept = .off
        #expect(RequestDecision.plan(cards: cards, policy: policy, seen: []).accept.isEmpty)
    }

    /// The executor replays any record with the same idempotency key, failed
    /// ones included (live 2026-09-15 16:39: an accept that failed on a stale
    /// element would have been replayed as failed in every later round). A
    /// failed / expired / cancelled attempt gets a fresh key; success, unknown
    /// and in-flight records keep replaying.
    @Test func attemptKeyIsFreshOnlyAfterAFailedAttempt() {
        let base = "auto-accept-0123456789abcdef"
        #expect(RequestDecision.attemptKey(base: base, previous: nil, nowMs: 5) == base)
        #expect(RequestDecision.attemptKey(base: base, previous: .succeeded, nowMs: 5) == base)
        #expect(RequestDecision.attemptKey(base: base, previous: .unknown, nowMs: 5) == base)
        #expect(RequestDecision.attemptKey(base: base, previous: .running, nowMs: 5) == base)
        #expect(RequestDecision.attemptKey(base: base, previous: .accepted, nowMs: 5) == base)
        #expect(RequestDecision.attemptKey(base: base, previous: .failed, nowMs: 5) == base + "-r5")
        #expect(RequestDecision.attemptKey(base: base, previous: .expired, nowMs: 7) == base + "-r7")
        #expect(RequestDecision.attemptKey(base: base, previous: .cancelled, nowMs: 9) == base + "-r9")
    }
}
