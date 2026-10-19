import CoreGraphics
import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("ScreenshotDirectionInference")
struct ScreenshotDirectionInferenceTests {
    private let window = CGRect(x: 100, y: 80, width: 800, height: 260)

    private func image(width: Int = 800, height: Int = 260, regions: [CGRect]) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.setFillColor(CGColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.82, green: 0.54, blue: 0.21, alpha: 1))
        for region in regions { context.fill(region) }
        return context.makeImage()!
    }

    private func infer(_ regions: [CGRect], width: Int = 800, height: Int = 260,
                       row: CGRect? = nil) -> MessageDirection {
        ScreenshotDirectionInference.infer(
            image: image(width: width, height: height, regions: regions),
            windowFrame: window, tableFrame: window, rowFrame: row ?? window
        )
    }

    @Test func substantialLeftMediaIsInbound() {
        #expect(infer([CGRect(x: 50, y: 42, width: 215, height: 166)]) == .inbound)
    }

    @Test func substantialRightMediaIsOutbound() {
        #expect(infer([CGRect(x: 535, y: 42, width: 215, height: 166)]) == .outbound)
    }

    @Test func highDPIWindowUsesPointToPixelScale() {
        #expect(infer([CGRect(x: 1070, y: 84, width: 430, height: 332)],
                      width: 1600, height: 520) == .outbound)
    }

    @Test func tableOffsetInsideWindowKeepsSideRelativeToTable() {
        let fullWindow = CGRect(x: 100, y: 80, width: 1000, height: 260)
        let table = CGRect(x: 300, y: 80, width: 800, height: 260)
        let result = ScreenshotDirectionInference.infer(
            image: image(width: 1000, regions: [CGRect(x: 735, y: 42, width: 215, height: 166)]),
            windowFrame: fullWindow, tableFrame: table, rowFrame: table
        )
        #expect(result == .outbound)
    }

    @Test func centeredMediaAndTwoSidedContentStayUnknown() {
        #expect(infer([CGRect(x: 300, y: 42, width: 200, height: 166)]) == .unknown)
        #expect(infer([
            CGRect(x: 50, y: 42, width: 215, height: 166),
            CGRect(x: 535, y: 42, width: 215, height: 166),
        ]) == .unknown)
    }

    @Test func timestampAvatarAndEmptyRowStayUnknown() {
        #expect(infer([]) == .unknown)
        #expect(infer([
            CGRect(x: 344, y: 228, width: 112, height: 12),
            CGRect(x: 20, y: 114, width: 36, height: 36),
        ]) == .unknown)
    }

    @Test func offscreenOrMostlyClippedRowStaysUnknown() {
        #expect(infer([CGRect(x: 50, y: 42, width: 215, height: 166)],
                      row: CGRect(x: 100, y: 300, width: 800, height: 260)) == .unknown)
        #expect(infer([CGRect(x: 50, y: 42, width: 215, height: 166)],
                      row: CGRect(x: 100, y: 245, width: 800, height: 260)) == .unknown)
    }
}
