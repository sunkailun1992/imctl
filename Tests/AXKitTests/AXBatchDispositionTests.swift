import ApplicationServices
import Testing
@testable import AXKit

/// The live batch read's error handling, tested as pure functions (no AX access,
/// so no `IMCTL_LIVE` gate and no `Live` prefix).
@Suite("Batch read dispositions")
struct AXBatchDispositionTests {
    private static let names = [AXAttribute.role, AXAttribute.value]

    @Test func callLevelTimeoutDoesNotFallBack() {
        #expect(LiveAXBackend.batchCallDisposition(.success, names: Self.names) == .proceed)
        #expect(LiveAXBackend.batchCallDisposition(.invalidUIElement, names: Self.names) == .fail(.invalidElement))
        #expect(LiveAXBackend.batchCallDisposition(.apiDisabled, names: Self.names) == .fail(.notTrusted))
        for err in [AXError.notImplemented, .illegalArgument, .failure, .attributeUnsupported, .noValue] {
            #expect(LiveAXBackend.batchCallDisposition(err, names: Self.names) == .fallBack)
        }
    }

    /// B62: a whole-batch timeout names what it asked for, like a single read names its attribute.
    @Test func wholeBatchTimeoutNamesItsAttributes() {
        #expect(LiveAXBackend.batchCallDisposition(.cannotComplete, names: Self.names)
                == .fail(.cannotComplete("get AXRole,AXValue")))
    }

    /// B62: the array a live batch returns, mapped without a live client.
    @Test func batchItemsMapLikeSingleReads() throws {
        var unsupported = AXError.attributeUnsupported
        var noValue = AXError.noValue
        var illegal = AXError.illegalArgument
        let items: [AnyObject] = [
            kCFNull,
            try #require(AXValueCreate(.axError, &unsupported)),
            try #require(AXValueCreate(.axError, &noValue)),
            try #require(AXValueCreate(.axError, &illegal)),
            "Main" as CFString,
            kCFBooleanTrue,
        ]
        let names = [AXAttribute.description, AXAttribute.title, AXAttribute.help, AXAttribute.value, AXAttribute.role, AXAttribute.enabled]
        let results = try #require(LiveAXBackend.mapBatchItems(items, names: names))
        #expect(results.count == 6)
        #expect(results[AXAttribute.description] == .success(nil))
        #expect(results[AXAttribute.title] == .failure(.attributeUnsupported(AXAttribute.title)))
        #expect(results[AXAttribute.help] == .success(nil))
        #expect(results[AXAttribute.value] == .failure(.apiFailure(code: -25201, operation: "get AXValue")))
        #expect(results[AXAttribute.role] == .success(.string("Main")))
        #expect(results[AXAttribute.enabled] == .success(.bool(true)))
    }

    @Test func aBatchArrayOfTheWrongLengthIsRejected() {
        #expect(LiveAXBackend.mapBatchItems([kCFNull], names: [AXAttribute.role, AXAttribute.title]) == nil)
        #expect(LiveAXBackend.mapBatchItems([], names: [AXAttribute.role]) == nil)
    }

    /// B62: a client that never answers a batch stops being asked.
    @Test func batchingStopsAfterRepeatedFallbacksWithoutASuccess() {
        var latch = LiveAXBackend.BatchLatch()
        let limit = LiveAXBackend.BatchLatch.fallbacksBeforeDisabling
        #expect(limit == 50)
        for _ in 1..<limit { #expect(latch.noteFallback() == false) }
        #expect(!latch.disabled)
        #expect(latch.noteFallback() == true)
        #expect(latch.disabled && latch.fallbacks == limit)
        #expect(latch.noteFallback() == false)
        #expect(latch.disabled && latch.fallbacks == limit + 1)
    }

    @Test func oneSuccessKeepsBatchingOn() {
        var latch = LiveAXBackend.BatchLatch()
        latch.noteSuccess()
        for _ in 0..<200 { #expect(latch.noteFallback() == false) }
        #expect(!latch.disabled && latch.successes == 1 && latch.fallbacks == 200)
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
