import AppKit
import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B59 window JPEG and AX share a top-left origin")
struct B59WindowImageOrientationTests {
    private enum Landmark { case red, green, blue, yellow }

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int

        func matches(_ landmark: Landmark) -> Bool {
            switch landmark {
            case .red: red > 180 && green < 100 && blue < 100
            case .green: green > 150 && red < 100 && blue < 100
            case .blue: blue > 180 && red < 100 && green < 100
            case .yellow: red > 170 && green > 150 && blue < 100
            }
        }

        var isPrivacySurround: Bool { red > 220 && green > 220 && blue > 220 }
    }

    /// Row zero is explicitly the top row. Neither fixture construction nor
    /// decoding uses CGContext, so a second drawing transform cannot hide a flip.
    private static func shot(width: Int, height: Int, display: CGRect,
                             inside: CGRect) throws -> WeComWindowScreenshot {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let x0 = Int(inside.minX), x1 = Int(inside.maxX)
        let y0 = Int(inside.minY), y1 = Int(inside.maxY)
        let middleX = x0 + (x1 - x0) / 2, middleY = y0 + (y1 - y0) / 2
        for y in y0..<y1 {
            for x in x0..<x1 {
                let color: (UInt8, UInt8, UInt8)
                switch (x < middleX, y < middleY) {
                case (true, true): color = (255, 0, 0)
                case (false, true): color = (0, 255, 0)
                case (true, false): color = (0, 0, 255)
                case (false, false): color = (255, 255, 0)
                }
                let offset = (y * width + x) * 4
                rgba[offset] = color.0
                rgba[offset + 1] = color.1
                rgba[offset + 2] = color.2
            }
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return WeComWindowScreenshot(image: image, windowFrame: display)
    }

    private static func bitmap(_ data: Data) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(data: data))
    }

    private static func prepared(_ shot: WeComWindowScreenshot,
                                 window: CGRect) throws -> NSBitmapImageRep {
        try bitmap(#require(AIPlannerWindowImage.prepare(shot: shot, expectedWindow: window)))
    }

    private static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> RGB {
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return RGB(red: Int((color.redComponent * 255).rounded()),
                   green: Int((color.greenComponent * 255).rounded()),
                   blue: Int((color.blueComponent * 255).rounded()))
    }

    private static func expectLandmarks(_ bitmap: NSBitmapImageRep) throws {
        let left = bitmap.pixelsWide / 8, right = bitmap.pixelsWide * 7 / 8
        let top = bitmap.pixelsHigh / 8, bottom = bitmap.pixelsHigh * 7 / 8
        #expect(try pixel(bitmap, x: left, y: top).matches(.red))
        #expect(try pixel(bitmap, x: right, y: top).matches(.green))
        #expect(try pixel(bitmap, x: left, y: bottom).matches(.blue))
        #expect(try pixel(bitmap, x: right, y: bottom).matches(.yellow))
    }

    /// The white privacy surround is outside the permitted crop. Inspect every
    /// boundary pixel, plus an interior grid, without redrawing decoded pixels.
    private static func expectNoPrivacySurround(_ bitmap: NSBitmapImageRep) throws {
        for x in 0..<bitmap.pixelsWide {
            #expect(try !pixel(bitmap, x: x, y: 0).isPrivacySurround)
            #expect(try !pixel(bitmap, x: x, y: bitmap.pixelsHigh - 1).isPrivacySurround)
        }
        for y in 0..<bitmap.pixelsHigh {
            #expect(try !pixel(bitmap, x: 0, y: y).isPrivacySurround)
            #expect(try !pixel(bitmap, x: bitmap.pixelsWide - 1, y: y).isPrivacySurround)
        }
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 12)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 12)) {
                #expect(try !pixel(bitmap, x: x, y: y).isPrivacySurround)
            }
        }
    }

    @Test func fullWindowKeepsRawTopRowAndAllFourCornersUpright() throws {
        let display = CGRect(x: 0, y: 0, width: 400, height: 300)
        let shot = try Self.shot(width: 400, height: 300, display: display, inside: display)
        // A direct PNG control establishes the input row order independently of
        // the formatter. JPEG color checks allow compression and color conversion.
        let png = try #require(NSBitmapImageRep(cgImage: shot.image)
            .representation(using: .png, properties: [:]))
        try Self.expectLandmarks(Self.bitmap(png))
        let output = try Self.prepared(shot, window: display)
        #expect(output.pixelsWide == 400 && output.pixelsHigh == 300)
        try Self.expectLandmarks(output)
    }

    @Test func asymmetricDisplayCropPreservesCornersAndExcludesTheSurround() throws {
        let display = CGRect(x: 0, y: 0, width: 500, height: 400)
        // The top and bottom margins differ, so a flipped display-space crop
        // cannot accidentally select the same rectangle.
        let window = CGRect(x: 40, y: 25, width: 320, height: 230)
        let shot = try Self.shot(width: 500, height: 400, display: display, inside: window)
        let output = try Self.prepared(shot, window: window)
        #expect(output.pixelsWide == 320 && output.pixelsHigh == 230)
        try Self.expectLandmarks(output)
        try Self.expectNoPrivacySurround(output)
    }

    @Test func translatedDisplayOriginsAndRetinaPixelsKeepTheSameTopLeftMeaning() throws {
        for origin in [CGPoint(x: 700, y: 300), CGPoint(x: -900, y: -200)] {
            for scale in [1, 2] {
                let display = CGRect(origin: origin, size: CGSize(width: 500, height: 400))
                let window = CGRect(x: origin.x + 40, y: origin.y + 25, width: 320, height: 230)
                let inside = CGRect(x: 40 * scale, y: 25 * scale,
                                    width: 320 * scale, height: 230 * scale)
                let shot = try Self.shot(width: 500 * scale, height: 400 * scale,
                                         display: display, inside: inside)
                let output = try Self.prepared(shot, window: window)
                #expect(output.pixelsWide == 320 * scale && output.pixelsHigh == 230 * scale)
                try Self.expectLandmarks(output)
                try Self.expectNoPrivacySurround(output)
            }
        }
    }

    @Test func downscaledAsymmetricCropKeepsTheTopLandmarksAtTheTop() throws {
        let display = CGRect(x: -250, y: 90, width: 2_400, height: 1_600)
        let window = CGRect(x: -170, y: 140, width: 2_200, height: 1_400)
        let shot = try Self.shot(width: 2_400, height: 1_600, display: display,
                                 inside: CGRect(x: 80, y: 50, width: 2_200, height: 1_400))
        let output = try Self.prepared(shot, window: window)
        #expect(output.pixelsWide == 1_920 && output.pixelsHigh == 1_221)
        try Self.expectLandmarks(output)
        try Self.expectNoPrivacySurround(output)
    }

    @Test func fractionalWindowBoundsRoundInwardWithoutUploadingOutsidePixels() throws {
        let display = CGRect(x: -120.5, y: 70.25, width: 360, height: 260)
        let window = CGRect(x: display.minX + 20.25, y: display.minY + 30.75,
                            width: 200.5, height: 130.5)
        // Explicit pixel fixtures, rather than using the formatter's rounding
        // code, leave a white strip at every excluded fractional boundary.
        for (scale, inside, width, height) in [
            (1, CGRect(x: 21, y: 31, width: 199, height: 130), 199, 130),
            (2, CGRect(x: 41, y: 62, width: 400, height: 260), 400, 260),
        ] {
            let shot = try Self.shot(width: 360 * scale, height: 260 * scale,
                                     display: display, inside: inside)
            let output = try Self.prepared(shot, window: window)
            #expect(output.pixelsWide == width && output.pixelsHigh == height)
            try Self.expectLandmarks(output)
            try Self.expectNoPrivacySurround(output)
        }
    }

    @Test func actualObservationAndBothProviderPayloadsAlignAXBoxesWithTheUploadedImage() throws {
        for provider in [CloudVisionProvider.qwen, .gemini] {
            for scale in [1, 2] {
                let display = CGRect(x: -300, y: 120, width: 600, height: 500)
                let windowFrame = CGRect(x: -220, y: 165, width: 400, height: 300)
                let fieldFrame = CGRect(x: -180, y: 189, width: 80, height: 24)
                let field = AXNode(role: AXRole.textField, frame: fieldFrame,
                                   settable: [AXAttribute.value])
                let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: windowFrame,
                                                       children: [field]))
                let element = try #require(fake.element(atPath: [0]))
                let shot = try Self.shot(width: 600 * scale, height: 500 * scale, display: display,
                    inside: CGRect(x: 80 * scale, y: 45 * scale,
                                   width: 400 * scale, height: 300 * scale))
                var captures = 0, requests = 0
                let observation = try AIPlannerObservation.capture(
                    window: fake.rootElement, expectedPID: fake.pid, allowedKinds: [.writeText],
                    eligibleHandles: [element.handle], capture: { _, _ in captures += 1; return shot })
                #expect(observation.candidates.count == 1)
                #expect(observation.candidates.first?.frame == fieldFrame)
                let context = try AIPlannerStepContext(
                    method: .groupRename, allowedSteps: [.verify, .reobserve, .stop],
                    phase: .prepare, lastEvidence: .inputReady, goal: .control(.groupNameField))
                let client = AIPlannerStepClient { request in
                    requests += 1
                    let payload = try Self.uploadedImage(request, provider: provider)
                    #expect(payload.jpeg == observation.imageJPEG)
                    let uploaded = try Self.bitmap(payload.jpeg)
                    #expect(uploaded.pixelsWide == 400 * scale && uploaded.pixelsHigh == 300 * scale)
                    try Self.expectLandmarks(uploaded)
                    try Self.expectNoPrivacySurround(uploaded)
                    let box = try Self.anchorBox(payload.prompt)
                    #expect(box == [100, 80, 300, 160])
                    #expect(payload.prompt.contains("top-left coordinates 0..1000"))
                    let x = (box[0] + box[2]) * uploaded.pixelsWide / 2_000
                    let y = (box[1] + box[3]) * uploaded.pixelsHigh / 2_000
                    #expect(try Self.pixel(uploaded, x: x, y: y).matches(.red))
                    #expect(try Self.pixel(uploaded, x: x, y: uploaded.pixelsHigh - 1 - y).matches(.blue))
                    return (AIPlannerStepDecisionTests.body("{\"step\":\"stop\"}", provider: provider),
                            AIPlannerStepDecisionTests.http(request))
                }
                let decision = try client.decide(observation: observation, context: context,
                    settings: AIPlannerVisionClientTests.settings(provider))
                // Fixing image orientation supplies evidence; it never overrides
                // the model's stop or grants any desktop mutation authority.
                #expect(decision == AIPlannerStepDecision(step: .stop, candidateID: nil))
                #expect(try decision.revalidatedCandidate(observation: observation,
                                                          window: fake.rootElement) == nil)
                #expect(captures == 1 && requests == 1)
                #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
            }
        }
    }

    private static func uploadedImage(_ request: URLRequest,
                                      provider: CloudVisionProvider) throws -> (prompt: String, jpeg: Data) {
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let prompt: String, encoded: String
        if provider == .qwen {
            let messages = try #require(json["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            prompt = try #require(parts.first?["text"] as? String)
            let imageURL = try #require(parts.last?["image_url"] as? [String: Any])
            let url = try #require(imageURL["url"] as? String)
            let prefix = "data:image/jpeg;base64,"
            #expect(url.hasPrefix(prefix))
            encoded = String(url.dropFirst(prefix.count))
        } else {
            let contents = try #require(json["contents"] as? [[String: Any]])
            let parts = try #require(contents.first?["parts"] as? [[String: Any]])
            prompt = try #require(parts.first?["text"] as? String)
            let inline = try #require(parts.last?["inline_data"] as? [String: Any])
            #expect(inline["mime_type"] as? String == "image/jpeg")
            encoded = try #require(inline["data"] as? String)
        }
        return (prompt, try #require(Data(base64Encoded: encoded)))
    }

    private static func anchorBox(_ prompt: String) throws -> [Int] {
        let pattern = try NSRegularExpression(pattern: #"C0 writeText \[(\d+),(\d+),(\d+),(\d+)\]"#)
        let match = try #require(pattern.firstMatch(in: prompt,
            range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)))
        return try (1...4).map { index in
            let range = try #require(Range(match.range(at: index), in: prompt))
            return try #require(Int(prompt[range]))
        }
    }
}
