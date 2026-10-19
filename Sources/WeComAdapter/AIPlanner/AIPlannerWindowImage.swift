import AppKit
import CoreGraphics
import Foundation

/// Pure image boundary for an explicit fixed desktop command. The capture
/// service supplies a display-backed image containing one verified WeCom
/// window; this step removes every pixel outside that AX window before encoding.
enum AIPlannerWindowImage {
    static let maxEdge = 1_920
    static let maxJPEGBytes = 2_000_000

    static func prepare(shot: WeComWindowScreenshot, expectedWindow: CGRect) -> Data? {
        guard shot.image.width > 0, shot.image.height > 0,
              shot.windowFrame.width > 0, shot.windowFrame.height > 0,
              expectedWindow.width >= 100, expectedWindow.height >= 100,
              shot.windowFrame.contains(expectedWindow) else { return nil }
        let scaleX = CGFloat(shot.image.width) / shot.windowFrame.width
        let scaleY = CGFloat(shot.image.height) / shot.windowFrame.height
        guard (0.5...4).contains(scaleX), (0.5...4).contains(scaleY) else { return nil }

        // Round inward: even an antialiased display edge outside the verified
        // window is excluded from the image sent to the selected provider.
        let x0 = ceil((expectedWindow.minX - shot.windowFrame.minX) * scaleX)
        let y0 = ceil((expectedWindow.minY - shot.windowFrame.minY) * scaleY)
        let x1 = floor((expectedWindow.maxX - shot.windowFrame.minX) * scaleX)
        let y1 = floor((expectedWindow.maxY - shot.windowFrame.minY) * scaleY)
        let source = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let bounds = CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
        guard source.width >= 100, source.height >= 100,
              bounds.contains(source), let clipped = shot.image.cropping(to: source) else { return nil }

        let ratio = min(1, CGFloat(maxEdge) / max(source.width, source.height))
        let outputWidth = max(1, Int((source.width * ratio).rounded(.down)))
        let outputHeight = max(1, Int((source.height * ratio).rounded(.down)))
        guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        // Preserve the cropped CGImage's row order when drawing into another
        // bitmap. A negative Y scale would invert the JPEG while AX boxes
        // continue to use top-left coordinates.
        context.interpolationQuality = .high
        context.draw(clipped, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        guard let image = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        for quality in [0.82, 0.67, 0.5] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= maxJPEGBytes { return jpeg }
        }
        return nil
    }
}
