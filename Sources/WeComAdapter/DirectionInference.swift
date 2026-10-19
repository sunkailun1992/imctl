import ControlCore
import CoreGraphics

/// Infers message direction from where the body sits inside the message
/// table. Deliberately conservative: anything not clearly hugging one edge
/// is `unknown`. Thresholds are revisited once inbound and outbound samples
/// exist (gate G0-2).
public struct DirectionInference {
    public var ratio: CGFloat

    public init(ratio: CGFloat = 0.6) {
        self.ratio = ratio
    }

    public func infer(body: CGRect, container: CGRect) -> MessageDirection {
        guard body.width > 0, container.width > 0 else { return .unknown }
        let leftGap = body.minX - container.minX
        let rightGap = container.maxX - body.maxX
        guard leftGap >= 0, rightGap >= 0 else { return .unknown }
        if leftGap < rightGap * ratio { return .inbound }
        if rightGap < leftGap * ratio { return .outbound }
        return .unknown
    }
}
