import ControlCore
import Testing
@testable import imctld

@Suite("Watcher health snapshot")
struct WatchHealthTests {
    @Test func neverPolledHasNoAge() {
        let facts = WatchHealth().facts(nowMs: 5_000)
        #expect(facts.lastPollAgeMs == nil && !facts.lastPollOK && facts.clientAvailable == nil && !facts.railRead)
    }

    @Test func updatesAreReadBackAsFacts() {
        let health = WatchHealth()
        health.update {
            $0.lastPollMs = 4_000; $0.lastPollOK = true; $0.clientAvailable = true
            $0.conversationCount = 7; $0.railRead = true; $0.railProblem = "通讯录 pair at rail slot 1, expected 9"
        }
        #expect(health.facts(nowMs: 5_500) == ReadinessFacts.Watch(lastPollAgeMs: 1_500, lastPollOK: true, clientAvailable: true,
                                                                   conversationCount: 7, railRead: true,
                                                                   railProblem: "通讯录 pair at rail slot 1, expected 9"))
        #expect(health.facts(nowMs: 3_000).lastPollAgeMs == 0)
    }

    @Test func errorsOlderThanAnHourDropOut() {
        let health = WatchHealth()
        health.noteError(nowMs: 1_000)
        health.noteError(nowMs: 3_000_000)
        #expect(health.facts(nowMs: 3_000_000).errorsLastHour == 2)
        #expect(health.facts(nowMs: 3_700_000).errorsLastHour == 1)
    }
}
