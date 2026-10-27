import ApplicationServices
import Testing
@testable import AXKit

/// The live batch read's error handling, tested as pure functions (no AX access).
@Suite("LiveAXBackend batch dispositions")
struct LiveAXBatchDispositionTests {
    @Test func callLevelTimeoutDoesNotFallBack() {
        #expect(LiveAXBackend.batchCallDisposition(.success) == .proceed)
        #expect(LiveAXBackend.batchCallDisposition(.cannotComplete) == .fail(.cannotComplete("get multiple attributes")))
        #expect(LiveAXBackend.batchCallDisposition(.invalidUIElement) == .fail(.invalidElement))
        #expect(LiveAXBackend.batchCallDisposition(.apiDisabled) == .fail(.notTrusted))
        for err in [AXError.notImplemented, .illegalArgument, .failure, .attributeUnsupported, .noValue] {
            #expect(LiveAXBackend.batchCallDisposition(err) == .fallBack)
        }
    }

    @Test func itemErrorsMapLikeSingleReads() {
        #expect(LiveAXBackend.itemResult(code: .noValue, name: AXAttribute.title) == .success(nil))
        #expect(LiveAXBackend.itemResult(code: .attributeUnsupported, name: AXAttribute.title)
                == .failure(.attributeUnsupported(AXAttribute.title)))
        #expect(LiveAXBackend.itemResult(code: .illegalArgument, name: AXAttribute.value)
                == .failure(.apiFailure(code: -25201, operation: "get AXValue")))
        #expect(LiveAXBackend.itemResult(code: .cannotComplete, name: AXAttribute.value)
                == .failure(.cannotComplete("get AXValue")))
        #expect(LiveAXBackend.itemResult(code: .invalidUIElement, name: AXAttribute.role) == .failure(.invalidElement))
        #expect(LiveAXBackend.itemResult(code: .apiDisabled, name: AXAttribute.role) == .failure(.notTrusted))
    }
}
