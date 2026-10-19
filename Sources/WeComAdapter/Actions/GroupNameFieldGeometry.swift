import CoreGraphics

/// A fixed group-name value can resize its original editor horizontally.
/// Callers must separately prove the same field, known value and header bounds;
/// this comparison never permits a new position or height to become an anchor.
enum GroupNameFieldGeometry {
    static func samePlacement(_ current: CGRect, _ anchor: CGRect, tolerance: CGFloat = 0) -> Bool {
        func finitePositive(_ frame: CGRect) -> Bool {
            frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
        return tolerance.isFinite && tolerance >= 0
            && finitePositive(current) && finitePositive(anchor)
            && abs(current.minX - anchor.minX) <= tolerance
            && abs(current.minY - anchor.minY) <= tolerance
            && abs(current.height - anchor.height) <= tolerance
    }
}
