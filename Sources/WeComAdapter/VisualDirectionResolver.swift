import AXKit
import ControlCore
import CoreGraphics
import Foundation

/// Resolves only visible media rows whose AX tree has no usable side anchor.
/// One window frame is shared by all candidates in an explicit history read
/// or one newly observed message batch. Pixels stay in this call and are never
/// written, logged, sent over the protocol, or used to identify a person.
public enum VisualDirectionResolver {
    public static func resolve(reader: WeComReader, rows: inout [MessageRow], candidatePositions: [Int]) {
        guard !candidatePositions.isEmpty,
              let table = reader.layout.messageTableFrame,
              let pid = try? reader.layout.window.pid(),
              let activeBefore = try? reader.activeConversationTitle(),
              !activeBefore.isEmpty else { return }
        let viewport = (try? reader.layout.messageScrollArea?.frame()) ?? table
        let positions = candidatePositions.filter { position in
            guard rows.indices.contains(position) else { return false }
            let row = rows[position]
            return row.kind == .media && row.direction == .unknown && row.readError == nil
                && row.frame.width > 0 && row.frame.height > 0
                && row.frame.intersection(viewport).height >= min(48, row.frame.height * 0.5)
        }
        guard !positions.isEmpty,
              let shot = WeComScreenCapture.capture(windowPID: pid, expectedFrame: reader.layout.windowFrame) else { return }
        // The user can switch conversations or move the window while the
        // single-frame API is completing. Never assign pixels to stale AX rows.
        guard (try? reader.activeConversationTitle()) == activeBefore,
              let currentWindow = try? reader.layout.window.frame(),
              nearlyEqual(currentWindow, reader.layout.windowFrame),
              let currentHandles = try? reader.layout.messageTable?.children().map(\.handle) else { return }
        for position in positions {
            let row = rows[position]
            guard currentHandles.contains(row.handle),
                  let currentFrame = try? AXElement(handle: row.handle, backend: reader.layout.window.backend).frame(),
                  nearlyEqual(currentFrame, row.frame) else { continue }
            let side = ScreenshotDirectionInference.infer(
                image: shot.image, windowFrame: shot.windowFrame, tableFrame: viewport, rowFrame: row.frame
            )
            if side != .unknown { rows[position].direction = side }
        }
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
