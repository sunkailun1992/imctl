import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WeComAdapter

@Suite("Cloud header-button crop boundary")
struct CloudHeaderButtonTargetingTests {
    private func syntheticShot() throws -> WeComWindowScreenshot {
        let width = 200, height = 100
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 70, height: 100)) // simulated private title/content
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 70, y: 0, width: 130, height: 100))
        return WeComWindowScreenshot(image: try #require(context.makeImage()),
                                     windowFrame: CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func encodesOnlyTheTwoControlFramesAndNotThePrivateLeftRegion() throws {
        let shot = try syntheticShot()
        let frames = [CGRect(x: 100, y: 10, width: 30, height: 30),
                      CGRect(x: 135, y: 10, width: 30, height: 30)]
        let crop = try #require(HeaderButtonCrop.prepare(
            shot: shot, expectedWindow: shot.windowFrame, headerBottom: 60, buttonFrames: frames
        ))
        let source = try #require(CGImageSourceCreateWithData(crop.jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 192 && image.height == 96)
        #expect(crop.normalizedRects.count == 2)
        #expect(crop.normalizedRects[0].minX < crop.normalizedRects[1].minX)
        #expect(crop.normalizedRects.allSatisfy { $0.minX >= 0 && $0.maxX <= 1 && $0.maxY <= 1 })
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let redPixels = rgba.withUnsafeMutableBytes { bytes -> Int in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return -1 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: pixels.count, by: 4).filter { offset in
                pixels[offset] > 150 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80
            }.count
        }
        #expect(redPixels == 0) // x<70 in the source was deliberately private red content.
    }

    @Test func refusesControlsThatWouldExposeContentOutsideTheHeaderBand() throws {
        let shot = try syntheticShot()
        let frames = [CGRect(x: 100, y: 10, width: 30, height: 30),
                      CGRect(x: 135, y: 10, width: 30, height: 30)]
        #expect(HeaderButtonCrop.prepare(shot: shot, expectedWindow: shot.windowFrame,
                                         headerBottom: 40, buttonFrames: frames) == nil)
        let stretched = [frames[0], CGRect(x: 10, y: 10, width: 30, height: 30)]
        #expect(HeaderButtonCrop.prepare(shot: shot, expectedWindow: shot.windowFrame,
                                         headerBottom: 60, buttonFrames: stretched) == nil)
    }
}
