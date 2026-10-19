import CoreGraphics
import Testing
@testable import AXKit

@Suite("AXAttributeValue")
struct AXAttributeValueTests {
    @Test func accessorsReturnMatchingPayloadOnly() {
        let h = AXElementHandle(id: 7)
        #expect(AXAttributeValue.string("a").stringValue == "a")
        #expect(AXAttributeValue.bool(true).stringValue == nil)
        #expect(AXAttributeValue.bool(true).boolValue == true)
        #expect(AXAttributeValue.integer(3).intValue == 3)
        #expect(AXAttributeValue.double(1.5).doubleValue == 1.5)
        #expect(AXAttributeValue.integer(3).doubleValue == 3.0)
        #expect(AXAttributeValue.rect(CGRect(x: 1, y: 2, width: 3, height: 4)).rectValue?.width == 3)
        #expect(AXAttributeValue.element(h).elementValue == h)
        #expect(AXAttributeValue.elements([h]).elementsValue == [h])
        #expect(AXAttributeValue.strings(["x"]).stringsValue == ["x"])
    }

    @Test func handleEqualityIsByIdentity() {
        #expect(AXElementHandle(id: 1) == AXElementHandle(id: 1))
        #expect(AXElementHandle(id: 1) != AXElementHandle(id: "1"))
    }

    @Test func errorsAreEquatable() {
        #expect(AXKitError.attributeUnsupported("AXFoo") == .attributeUnsupported("AXFoo"))
        #expect(AXKitError.apiFailure(code: -25204, operation: "get AXRole").description.contains("-25204"))
    }
}
