import Foundation
import Testing
@testable import MQTTTransport

/// B52 addendum (user 2026-10-12): the controller id defaults to this Mac's local host name, and is always one topic level.
@Suite("Controller id")
struct ControllerIDTests {
    @Test func theDefaultIsTheLocalHostNameInLowerCase() {
        #expect(MQTTSettings.defaultControllerID(localHostName: "Example-Mac-Studio") == "example-mac-studio")
        #expect(MQTTSettings.defaultControllerID(localHostName: "My Mac (2)") == "my-mac-2")
        #expect(MQTTSettings.defaultControllerID(localHostName: "--Mac--") == "mac")
        // Cut at 64 characters, and a "-" left at the cut is trimmed too.
        #expect(MQTTSettings.defaultControllerID(localHostName: String(repeating: "a-", count: 40))
                == String(String(repeating: "a-", count: 32).dropLast()))
    }

    @Test func noUsableHostNameMeansNoDefault() {
        for name in [nil, "", "---", "电脑"] as [String?] {
            #expect(MQTTSettings.defaultControllerID(localHostName: name) == nil, "\(String(describing: name))")
        }
    }

    @Test func aControllerIDIsOneTopicLevel() {
        for ok in ["mac-01", "Mac_01.a", String(repeating: "a", count: 64)] {
            #expect(MQTTSettings.isValidControllerID(ok), "\(ok)")
        }
        for bad in ["", "a/b", "a+b", "a#", "a b", String(repeating: "a", count: 65), "电脑"] {
            #expect(!MQTTSettings.isValidControllerID(bad), "\(bad)")
        }
    }

    /// Re-enrolling must not move the Mac to another topic tree: an enrolled id wins over the host-name default.
    @Test func anExplicitIDThenTheEnrolledOneThenTheHostName() {
        #expect(MQTTSettings.resolveControllerID(explicit: "x", existing: "y", hostDefault: "z") == "x")
        #expect(MQTTSettings.resolveControllerID(explicit: nil, existing: "y", hostDefault: "z") == "y")
        #expect(MQTTSettings.resolveControllerID(explicit: "", existing: "y", hostDefault: "z") == "y")
        #expect(MQTTSettings.resolveControllerID(explicit: nil, existing: nil, hostDefault: "z") == "z")
        #expect(MQTTSettings.resolveControllerID(explicit: nil, existing: "", hostDefault: nil) == nil)
    }
}
