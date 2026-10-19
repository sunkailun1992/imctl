import CoreGraphics
import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("DirectionInference")
struct DirectionInferenceTests {
    let table = CGRect(x: 310, y: 63, width: 1611, height: 933)
    let infer = DirectionInference()

    @Test func leftAlignedIsInbound() {
        #expect(infer.infer(body: CGRect(x: 380, y: 100, width: 400, height: 20), container: table) == .inbound)
    }

    @Test func rightAlignedIsOutbound() {
        #expect(infer.infer(body: CGRect(x: 1450, y: 100, width: 400, height: 20), container: table) == .outbound)
    }

    @Test func centeredIsUnknown() {
        // The single message in the S3 fixture: gaps 599 / 600.
        #expect(infer.infer(body: CGRect(x: 909, y: 106, width: 412, height: 15), container: table) == .unknown)
    }

    @Test func degenerateFramesAreUnknown() {
        #expect(infer.infer(body: .zero, container: table) == .unknown)
        #expect(infer.infer(body: CGRect(x: 0, y: 0, width: 10, height: 10), container: .zero) == .unknown)
    }
}
