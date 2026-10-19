import AppKit
import AXKit
import CoreGraphics
import Foundation

/// The only B16 cloud-vision entry point. It receives AX handles already narrowed to the
/// group's unlabeled header buttons, captures one verified window frame, and sends a black-backed
/// collage made only from the interiors of those AX button rectangles. No title, gap, or message
/// pixels are passed to the model. The caller rechecks the returned AX handle before pressing it.
public enum CloudHeaderButtonTargeting {
    public typealias Capture = (pid_t, CGRect) -> WeComWindowScreenshot?

    public static func select(
        reader: WeComReader,
        candidates: [AXElement],
        expectedTitle: String,
        settings: CloudVisionSettings,
        client: CloudVisionClient = CloudVisionClient(),
        capture: Capture = { pid, frame in WeComScreenCapture.capture(windowPID: pid, expectedFrame: frame) }
    ) throws -> AXElement? {
        guard settings.cloudEnabled, let key = settings.apiKey(for: settings.provider) else {
            throw CloudVisionError.missingAPIKey
        }
        guard (2...8).contains(candidates.count),
              try reader.activeConversationTitle() == expectedTitle,
              let headerBottom = (try? reader.layout.messageScrollArea?.frame())?.minY,
              let pid = try? reader.layout.window.pid(), pid > 0 else {
            throw CloudVisionError.invalidCandidates
        }
        let frames = try candidates.map { candidate -> CGRect in
            guard try candidate.role() == AXRole.button,
                  try candidate.actions().contains(AXAction.press),
                  let frame = try candidate.frame() else { throw CloudVisionError.invalidCandidates }
            return frame
        }
        guard let shot = capture(pid, reader.layout.windowFrame) else {
            throw CloudVisionError.captureUnavailable
        }
        guard let prepared = HeaderButtonCrop.prepare(
                shot: shot, expectedWindow: reader.layout.windowFrame,
                headerBottom: headerBottom, buttonFrames: frames
              ) else {
            throw CloudVisionError.unsafeCrop
        }
        guard try reader.activeConversationTitle() == expectedTitle,
              let currentWindow = try reader.layout.window.frame(),
              nearlyEqual(currentWindow, reader.layout.windowFrame) else {
            throw CloudVisionError.staleView
        }
        let ids = frames.indices.map { "C\($0)" }
        let boxes = zip(ids, prepared.normalizedRects).map { CloudVisionCandidate(id: $0.0, normalizedRect: $0.1) }
        guard let chosen = try client.selectCandidate(
            imageJPEG: prepared.jpeg, candidates: boxes, target: .addMembersButton,
            provider: settings.provider, model: settings.model, apiKey: key
        ) else { return nil }
        guard let index = ids.firstIndex(of: chosen) else { throw CloudVisionError.invalidChoice }
        return candidates[index]
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}

/// Pure, testable privacy boundary: rejects candidates outside the narrow header control band,
/// then composes only their individual pixels into an in-memory JPEG. Even text drawn between
/// two controls is absent from the upload.
enum HeaderButtonCrop {
    struct Prepared {
        let jpeg: Data
        let normalizedRects: [CGRect]
    }

    static func prepare(shot: WeComWindowScreenshot, expectedWindow: CGRect,
                        headerBottom: CGFloat, buttonFrames: [CGRect]) -> Prepared? {
        guard (2...8).contains(buttonFrames.count),
              shot.image.width > 0, shot.image.height > 0,
              shot.windowFrame.width > 0, shot.windowFrame.height > 0,
              expectedWindow.width > 0, expectedWindow.height > 0,
              headerBottom.isFinite else { return nil }
        var union = CGRect.null
        for frame in buttonFrames {
            guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                  (20...48).contains(frame.width), (20...48).contains(frame.height),
                  expectedWindow.contains(frame) else { return nil }
            union = union.union(frame)
        }
        guard !union.isNull, union.width <= 240, union.height <= 64,
              union.minX >= max(expectedWindow.midX, expectedWindow.maxX - 320),
              union.maxX >= expectedWindow.maxX - 48,
              union.minY >= expectedWindow.minY, union.maxY < headerBottom else { return nil }
        guard shot.windowFrame.contains(union) else { return nil }
        let scaleX = CGFloat(shot.image.width) / shot.windowFrame.width
        let scaleY = CGFloat(shot.image.height) / shot.windowFrame.height
        guard scaleX >= 0.5, scaleY >= 0.5, scaleX <= 4, scaleY <= 4 else { return nil }
        let slot = 96, margin = 8
        let width = slot * buttonFrames.count, height = slot
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Captured pixels and candidate boxes use top-left coordinates; Quartz bitmap
        // contexts use bottom-left coordinates. Flip once so the model sees upright icons.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        let imageBounds = CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
        var rects: [CGRect] = []
        for (index, frame) in buttonFrames.enumerated() {
            // Round *inward* so no encoded source pixel comes from outside the AX button frame.
            let x0 = ceil((frame.minX - shot.windowFrame.minX) * scaleX)
            let y0 = ceil((frame.minY - shot.windowFrame.minY) * scaleY)
            let x1 = floor((frame.maxX - shot.windowFrame.minX) * scaleX)
            let y1 = floor((frame.maxY - shot.windowFrame.minY) * scaleY)
            let source = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            guard source.width >= 16, source.height >= 16,
                  imageBounds.contains(source),
                  let icon = shot.image.cropping(to: source) else { return nil }
            let destination = CGRect(x: index * slot + margin, y: margin,
                                     width: slot - margin * 2, height: slot - margin * 2)
            context.draw(icon, in: destination)
            rects.append(CGRect(x: destination.minX / CGFloat(width), y: destination.minY / CGFloat(height),
                                width: destination.width / CGFloat(width), height: destination.height / CGFloat(height)))
        }
        guard let collage = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: collage).representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
              jpeg.count <= 1_000_000 else { return nil }
        return Prepared(jpeg: jpeg, normalizedRects: rects)
    }
}
