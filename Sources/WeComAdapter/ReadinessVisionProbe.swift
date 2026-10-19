import ControlCore
import CoreGraphics
import Foundation
import ImageIO

/// B52 readiness (user decision 2026-10-10): one B16 request with a picture drawn here — two grey squares
/// on white, no text, nothing from the screen or the client — to prove the configured provider, model and
/// key answer. Uses `CloudVisionClient` unchanged (fixed prompt, fixed endpoint, no redirects, 8 s), which
/// does not touch the explicit-command vision counters. The model's answer is discarded; only a category returns.
public enum ReadinessVisionProbe {
    static let width = 320
    static let height = 120
    static let candidates = [
        CloudVisionCandidate(id: "A", normalizedRect: CGRect(x: 0.1, y: 0.25, width: 0.3, height: 0.5)),
        CloudVisionCandidate(id: "B", normalizedRect: CGRect(x: 0.6, y: 0.25, width: 0.3, height: 0.5)),
    ]

    public static func syntheticJPEG() -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
        for candidate in candidates {
            let r = candidate.normalizedRect
            // normalizedRect has a top-left origin; the bitmap context a bottom-left one.
            context.fill(CGRect(x: r.minX * CGFloat(width), y: (1 - r.maxY) * CGFloat(height),
                                width: r.width * CGFloat(width), height: r.height * CGFloat(height)))
        }
        guard let image = context.makeImage(), let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    public static func probe(settings: CloudVisionSettings, client: CloudVisionClient = CloudVisionClient()) -> ReadinessProbeResult {
        let started = Date()
        guard let key = settings.apiKey(for: settings.provider) else { return .failure("config", latencyMs: 0) }
        guard let image = syntheticJPEG() else { return .failure("internal", latencyMs: 0) }
        do {
            _ = try client.selectCandidate(imageJPEG: image, candidates: candidates, target: .addMembersButton,
                                           provider: settings.provider, model: settings.model, apiKey: key)
            return .success(latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        } catch let error as CloudVisionError {
            let latency = ReadinessProbeResult.elapsedMs(since: started)
            switch error {
            case .invalidChoice: return .success(latencyMs: latency)   // the model answered; it only named no listed square
            case .timeout: return .failure("timeout", latencyMs: latency)
            case .requestFailed: return .failure("network", latencyMs: latency)
            case .invalidHTTPStatus: return .failure("http", latencyMs: latency)
            case .responseTooLarge, .invalidResponse: return .failure("response", latencyMs: latency)
            case .missingAPIKey, .unsupportedModel: return .failure("config", latencyMs: latency)
            default: return .failure("internal", latencyMs: latency)
            }
        } catch {
            return .failure("network", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
    }
}
